import AppKit

/// Single source of truth for every pin window. The menu bar and the URL
/// scheme both drive the app exclusively through this type.
final class PinWindowManager {
    static let shared = PinWindowManager()

    private(set) var pins: [PinWindowController] = []
    var onChange: (() -> Void)?

    /// nil disables history (tests opt in with a temp-directory store).
    var historyStore: HistoryStore? {
        didSet {
            historyStore?.onReadError = { [weak self] error in self?.onHistoryError?(error) }
            // A pin can exist before the store does: `pinboard://paste` at
            // launch delivers its URL event before `applicationDidFinishLaunching`
            // installs the store. Those pins get their record here.
            adoptRecordlessPins()
        }
    }
    var onHistoryError: ((Error) -> Void)?
    /// Loads images referenced by pasted HTML. Tests inject a stub so they
    /// never touch the network.
    var remoteImageLoader: RemoteImageFetching = RemoteImageLoader.shared
    /// Debounce for edit → history writes. Tests can shrink it to ~0 and call
    /// `flushHistorySync()` for a synchronous write.
    var historyWriteDelay: TimeInterval = 2.0
    private var pendingHistoryWrites: [UUID: DispatchWorkItem] = [:]
    private var lastHistoryPrune: Date = .distantPast

    private var cascadeStep = 0

    var count: Int { pins.count }
    var visibleCount: Int { pins.filter(\.isPinVisible).count }

    private init() {}

    // MARK: - Creation

    @discardableResult
    func createPin(content: PinContent, annotations: AnnotationStore.Payload? = nil,
                   textMode: TextContentMode? = nil, at pointer: CGPoint = NSEvent.mouseLocation) -> PinWindowController {
        let controller = PinWindowController(content: content, annotations: annotations, textMode: textMode)
        controller.manager = self
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let frame = controller.idealFrame(anchoredAt: nextAnchor(on: screen, pointer: pointer), on: screen)
        controller.setFrame(frame)
        pins.append(controller)
        controller.present()
        // Images only referenced by the text (pasted HTML, Markdown source)
        // are resolved once the window exists, so they can be sized against
        // the real wrap width and grow it.
        if let textView = controller.contentView as? TextPinView {
            textView.imageLoader = remoteImageLoader
            textView.resolveDeferredImages()
        }
        registerInHistory(controller)
        notifyChange()
        return controller
    }

    /// Returns false when the pasteboard holds nothing Pinboard can show.
    @discardableResult
    func pasteFromClipboard() -> Bool {
        guard let content = ClipboardReader.read() else { return false }
        createPin(content: content)
        return true
    }

    func remove(_ controller: PinWindowController) {
        flushHistorySync(for: controller)
        if let id = controller.historyRecordID {
            pendingHistoryWrites.removeValue(forKey: id)?.cancel()
        }
        controller.markHistoryDirty(false)
        pins.removeAll { $0 === controller }
        controller.manager = nil
        notifyChange()
    }

    // MARK: - Bulk visibility

    func showAll() {
        pins.forEach { $0.showPin() }
        notifyChange()
    }

    func hideAll() {
        pins.forEach { $0.hidePin() }
        notifyChange()
    }

    /// Any visible pin -> hide everything, otherwise restore everything.
    /// With no pins at all this is a no-op by design.
    func toggleAll() {
        guard !pins.isEmpty else { return }
        if visibleCount > 0 { hideAll() } else { showAll() }
    }

    func closeAll() {
        pins.forEach { $0.closePin() }
        pins.removeAll()
        notifyChange()
    }

    func pin(with id: UUID) -> PinWindowController? {
        pins.first { $0.id == id }
    }

    func notifyChange() {
        onChange?()
    }

    func snapshots() -> [PinSnapshot] {
        pins.map { $0.snapshot() }
    }

    // MARK: - History

    var liveHistoryRecordIDs: Set<UUID> {
        Set(pins.compactMap(\.historyRecordID))
    }

    /// Explicitly deleted history must not be recreated by an open pin's
    /// pending write, later edits, or close. The pin itself stays usable.
    func detachHistoryRecord(_ id: UUID) {
        pendingHistoryWrites.removeValue(forKey: id)?.cancel()
        for controller in pins where controller.historyRecordID == id {
            controller.detachHistory()
        }
    }

    /// Records a new pin immediately; every later edit updates this same record.
    private func registerInHistory(_ controller: PinWindowController) {
        guard historyStore != nil else { return }
        // Reserve the identity even if the first save fails, so a later edit
        // or close can retry without abandoning this pin's history.
        let id = UUID()
        controller.markHistoryTracked(id: id, isDirty: true)
        writeHistory(for: controller)
        pruneHistoryIfDue()
    }

    /// Registers live pins that never had a record — the launch-time paste
    /// case. A pin whose record the user deleted stays out: it is excluded,
    /// not recordless by accident.
    private func adoptRecordlessPins() {
        guard historyStore != nil else { return }
        for controller in pins where controller.historyState == .unregistered {
            registerInHistory(controller)
        }
    }

    /// Debounced entry point called by pin views whenever content mutates.
    func pinContentDidChange(_ controller: PinWindowController) {
        notifyChange()
        guard case .tracked(let id, _) = controller.historyState, historyStore != nil else { return }
        controller.markHistoryDirty(true)
        pendingHistoryWrites[id]?.cancel()
        let item = DispatchWorkItem { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.pendingHistoryWrites.removeValue(forKey: id)
            self.writeHistory(for: controller)
        }
        pendingHistoryWrites[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + historyWriteDelay, execute: item)
    }

    /// Flushes one pending write — called on close and before terminate.
    func flushHistorySync(for controller: PinWindowController) {
        guard let id = controller.historyRecordID else { return }
        pendingHistoryWrites.removeValue(forKey: id)?.cancel()
        writeHistory(for: controller)
    }

    /// Flushes every pending write (app quit).
    func flushAllHistorySyncs() {
        for controller in pins {
            // Text annotation fields hold a draft until editing ends.
            controller.endEditing()
            flushHistorySync(for: controller)
        }
    }

    private func writeHistory(for controller: PinWindowController) {
        guard case .tracked(let id, isDirty: true) = controller.historyState,
              let store = historyStore else { return }
        controller.markHistoryDirty(false)
        let state = controller.contentView.captureState()
        do {
            try store.upsert(id: id, content: state.content, annotationData: state.annotationData,
                             textMode: state.textMode)
        } catch {
            controller.markHistoryDirty(true)
            onHistoryError?(error)
        }
    }

    /// Re-pins a history record as a new independent window + new record.
    @discardableResult
    func repin(recordID: UUID) -> PinWindowController? {
        guard let entry = historyStore?.entry(id: recordID) else { return nil }
        // The record's stored mode wins: re-pinning reproduces how it looked,
        // and records written before text modes stay rich text.
        do {
            let annotations = try entry.annotationData.map(AnnotationStore.decode)
            return createPin(content: entry.content, annotations: annotations, textMode: entry.textMode)
        } catch {
            onHistoryError?(error)
            return nil
        }
    }

    /// Retention cleanup, throttled so directory scans stay rare.
    func pruneHistoryIfDue(force: Bool = false) {
        guard let store = historyStore else { return }
        guard force || Date().timeIntervalSince(lastHistoryPrune) > 3600 else { return }
        lastHistoryPrune = Date()
        if let cutoff = Preferences.shared.historyRetentionCutoff {
            do {
                try store.prune(olderThan: cutoff, excluding: liveHistoryRecordIDs)
            } catch {
                onHistoryError?(error)
            }
        }
    }

    // MARK: - Placement

    private func nextAnchor(on screen: NSScreen?, pointer: CGPoint) -> CGPoint {
        if Preferences.shared.placeNewWindowAtMouse { return pointer }
        let offset = CGFloat(cascadeStep % 8) * 22
        cascadeStep += 1
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        return CGPoint(x: visible.midX - 160 + offset, y: visible.midY + 120 - offset)
    }
}
