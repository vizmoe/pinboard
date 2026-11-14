import AppKit
import Carbon

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

    /// Routes trackpad pinch-to-zoom (`NSEvent.EventType.magnify`) across the
    /// gesture lifecycle. Two macOS layers require explicit routing:
    /// 1. WindowServer sends trackpad `kCGEventGesture` (`Zoom`) exclusively to
    ///    the foreground application, so an inactive `.accessory` app never
    ///    receives `.magnify` in `NSApp` for hovered `.nonactivatingPanel` pins;
    ///    a listen-only `CGEvent` HID tap observes pinch gestures while any
    ///    zoomable pin is visible without stealing focus.
    /// 2. When Pinboard is active, AppKit's `_applicationGestureHandler` handles
    ///    Carbon `kEventClassGesture` directly (bypassing `NSApp.sendEvent` and
    ///    local `NSEvent` monitors) and `routeGestureEvent` drops `.magnify` on
    ///    non-key borderless `.nonactivatingPanel` windows; a Carbon application
    ///    gesture handler plus local `NSEvent` monitor route those events cleanly.
    private enum MagnifyGestureState {
        case idle
        /// Gesture began outside all visible pins; let normal handling run.
        case passthrough
        /// Gesture began on a pin; every step until `.ended`/`.cancelled` stays bound to it.
        case latched(WeakPin)
    }

    private struct WeakPin {
        weak var controller: PinWindowController?
    }

    struct GestureTapBackend {
        var hasListenAccess: () -> Bool
        var requestListenAccess: () -> Bool
        var createTap: (@escaping (CGEventType, CGEvent) -> Void) -> AnyObject?
        var setEnabled: (AnyObject, Bool) -> Void
        var isEnabled: (AnyObject) -> Bool
        var invalidate: (AnyObject) -> Void

        static let live = GestureTapBackend(
            hasListenAccess: { CGPreflightListenEventAccess() },
            requestListenAccess: { CGRequestListenEventAccess() },
            createTap: { handler in
                let box = TapCallbackBox(handler)
                let retainedBox = Unmanaged.passRetained(box)
                let callback: CGEventTapCallBack = { _, type, cgEvent, userInfo in
                    if let userInfo {
                        let box = Unmanaged<TapCallbackBox>.fromOpaque(userInfo).takeUnretainedValue()
                        box.handler(type, cgEvent)
                    }
                    return Unmanaged.passUnretained(cgEvent)
                }
                let userInfo = retainedBox.toOpaque()
                let mask = PinWindowManager.gestureEventTapMask
                // Trackpad gesture records (`kCGEventGesture`) are dispatched
                // at `.cghidEventTap` / `.cgAnnotatedSessionEventTap` in SkyLight,
                // not `.cgSessionEventTap`; attach to `.cghidEventTap` first.
                let tap = CGEvent.tapCreate(
                    tap: .cghidEventTap,
                    place: .tailAppendEventTap,
                    options: .listenOnly,
                    eventsOfInterest: mask,
                    callback: callback,
                    userInfo: userInfo
                ) ?? CGEvent.tapCreate(
                    tap: .cgAnnotatedSessionEventTap,
                    place: .tailAppendEventTap,
                    options: .listenOnly,
                    eventsOfInterest: mask,
                    callback: callback,
                    userInfo: userInfo
                ) ?? CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .tailAppendEventTap,
                    options: .listenOnly,
                    eventsOfInterest: mask,
                    callback: callback,
                    userInfo: userInfo
                )
                guard let tap,
                      let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                    if let tap { CFMachPortInvalidate(tap) }
                    retainedBox.release()
                    return nil
                }
                let handle = LiveGestureTapHandle(port: tap, runLoopSource: source, callbackBox: retainedBox)
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                guard CGEvent.tapIsEnabled(tap: tap) else {
                    handle.invalidate()
                    return nil
                }
                return handle
            },
            setEnabled: { handle, enabled in
                guard let handle = handle as? LiveGestureTapHandle else { return }
                CGEvent.tapEnable(tap: handle.port, enable: enabled)
            },
            isEnabled: { handle in
                guard let handle = handle as? LiveGestureTapHandle else { return false }
                return CGEvent.tapIsEnabled(tap: handle.port)
            },
            invalidate: { handle in
                (handle as? LiveGestureTapHandle)?.invalidate()
            }
        )
    }

    private final class TapCallbackBox {
        let handler: (CGEventType, CGEvent) -> Void

        init(_ handler: @escaping (CGEventType, CGEvent) -> Void) {
            self.handler = handler
        }
    }

    private final class LiveGestureTapHandle {
        let port: CFMachPort
        let runLoopSource: CFRunLoopSource
        var callbackBox: Unmanaged<TapCallbackBox>?

        init(port: CFMachPort, runLoopSource: CFRunLoopSource, callbackBox: Unmanaged<TapCallbackBox>) {
            self.port = port
            self.runLoopSource = runLoopSource
            self.callbackBox = callbackBox
        }

        func invalidate() {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
            callbackBox?.release()
            callbackBox = nil
        }
    }

    private static let cgEventTypeGesture: UInt32 = 29 // kCGEventGesture
    private static let cgEventTypeMagnify: UInt32 = 30
    private static let gestureEventTapMask: CGEventMask = (1 << 29) | (1 << 30)
    private static let magnifyTimestampTolerance: TimeInterval = 1e-5
    private static let maxRecentMagnifyTimestamps = 8

    private var cascadeStep = 0
    private var magnifyMonitor: Any?
    private var carbonGestureHandler: EventHandlerRef?
    private var appActivityObservers: [NSObjectProtocol] = []
    private var magnifyState: MagnifyGestureState = .idle
    private var recentHandledMagnifyTimestamps: [TimeInterval] = []
    private var backgroundGestureMonitoringEnabled = false
    private var didAttemptUnprivilegedTap = false
    private var backgroundGestureTap: AnyObject?

    /// Checks whether a non-Pinboard window at a higher WindowServer z-order
    /// covers `window` at `screenPoint`. Injectable so unit tests stay deterministic.
    var externalOcclusionTester: (NSWindow, CGPoint) -> Bool = PinWindowManager.isWindowOccludedInWindowServer

    /// Abstracts `CGEvent` tap creation and TCC ListenEvent checks for deterministic testing.
    var gestureTapBackend: GestureTapBackend = .live {
        willSet {
            tearDownBackgroundGestureTap()
        }
        didSet {
            didAttemptUnprivilegedTap = false
            syncBackgroundGestureTap()
        }
    }

    var count: Int { pins.count }
    var visibleCount: Int { pins.filter(\.isPinVisible).count }
    var hasVisibleZoomablePin: Bool { pins.contains { $0.isPinVisible && $0.supportsZoom } }
    var hasBackgroundGestureAccess: Bool {
        gestureTapBackend.hasListenAccess() || isBackgroundGestureTapEnabled
    }
    var isBackgroundGestureTapEnabled: Bool {
        backgroundGestureTap.map { gestureTapBackend.isEnabled($0) } ?? false
    }

    private init() {
        // Ensure `NSApp` exists before installing local `NSEvent` monitors (in
        // unit tests `PinWindowManager.shared` can be touched before AppKit boot).
        _ = NSApplication.shared
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .endGesture]) { [weak self] event in
            guard let self else { return event }
            return self.handleLocalGestureEvent(event)
        }
        installCarbonGestureHandler()
        let center = NotificationCenter.default
        let becomeActiveToken = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.didAttemptUnprivilegedTap = false
            self.syncBackgroundGestureTap()
        }
        let resignActiveToken = center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncBackgroundGestureTap()
        }
        appActivityObservers = [becomeActiveToken, resignActiveToken]
    }

    deinit {
        if let magnifyMonitor {
            NSEvent.removeMonitor(magnifyMonitor)
        }
        if let carbonGestureHandler {
            RemoveEventHandler(carbonGestureHandler)
        }
        for token in appActivityObservers {
            NotificationCenter.default.removeObserver(token)
        }
        tearDownBackgroundGestureTap()
    }

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
        magnifyState = .idle
        recentHandledMagnifyTimestamps.removeAll()
        notifyChange()
    }

    func pin(with id: UUID) -> PinWindowController? {
        pins.first { $0.id == id }
    }

    func notifyChange() {
        if case .latched(let weakPin) = magnifyState,
           weakPin.controller?.isPinVisible != true {
            magnifyState = .idle
        }
        syncBackgroundGestureTap()
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

    // MARK: - Trackpad gesture routing

    func startBackgroundGestureMonitoring() {
        backgroundGestureMonitoringEnabled = true
        syncBackgroundGestureTap()
    }

    func stopBackgroundGestureMonitoring() {
        backgroundGestureMonitoringEnabled = false
        didAttemptUnprivilegedTap = false
        recentHandledMagnifyTimestamps.removeAll()
        tearDownBackgroundGestureTap()
    }

    /// Prompts for Input Monitoring access and retries installing the
    /// background gesture tap once granted.
    @discardableResult
    func requestBackgroundGestureAccess() -> Bool {
        let granted = gestureTapBackend.requestListenAccess()
        didAttemptUnprivilegedTap = false
        syncBackgroundGestureTap()
        return granted || gestureTapBackend.hasListenAccess()
    }

    private func syncBackgroundGestureTap() {
        let shouldListen = backgroundGestureMonitoringEnabled && hasVisibleZoomablePin
        if shouldListen {
            if let tap = backgroundGestureTap {
                if !gestureTapBackend.isEnabled(tap) {
                    gestureTapBackend.setEnabled(tap, true)
                    if !gestureTapBackend.isEnabled(tap) {
                        tearDownBackgroundGestureTap()
                    }
                }
            } else if gestureTapBackend.hasListenAccess() || !didAttemptUnprivilegedTap {
                if !gestureTapBackend.hasListenAccess() {
                    didAttemptUnprivilegedTap = true
                }
                installBackgroundGestureTap()
            }
        } else if let tap = backgroundGestureTap, gestureTapBackend.isEnabled(tap) {
            gestureTapBackend.setEnabled(tap, false)
        }
    }

    private func installBackgroundGestureTap() {
        guard backgroundGestureTap == nil else { return }
        backgroundGestureTap = gestureTapBackend.createTap { [weak self] type, cgEvent in
            self?.handleBackgroundTapCallback(type: type, cgEvent: cgEvent)
        }
    }

    private func tearDownBackgroundGestureTap() {
        if let tap = backgroundGestureTap {
            gestureTapBackend.invalidate(tap)
            backgroundGestureTap = nil
        }
    }

    private func installCarbonGestureHandler() {
        guard carbonGestureHandler == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassGesture), eventKind: UInt32(kEventGestureMagnify)),
            EventTypeSpec(eventClass: OSType(kEventClassGesture), eventKind: UInt32(kEventGestureEnded))
        ]
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { nextHandler, eventRef, userData -> OSStatus in
                guard let eventRef, let userData else {
                    return CallNextEventHandler(nextHandler, eventRef)
                }
                let manager = Unmanaged<PinWindowManager>.fromOpaque(userData).takeUnretainedValue()
                return manager.handleCarbonGestureEvent(nextHandler: nextHandler, eventRef: eventRef)
            },
            specs.count,
            &specs,
            userData,
            &carbonGestureHandler
        )
    }

    private func handleCarbonGestureEvent(nextHandler: EventHandlerCallRef?, eventRef: EventRef) -> OSStatus {
        guard NSApp.modalWindow == nil else {
            return CallNextEventHandler(nextHandler, eventRef)
        }
        switch Int(GetEventKind(eventRef)) {
        case kEventGestureMagnify:
            guard let event = NSEvent(eventRef: UnsafeRawPointer(eventRef)) else {
                return CallNextEventHandler(nextHandler, eventRef)
            }
            if handleForegroundMagnifyEvent(event) == nil {
                return noErr
            }
            return CallNextEventHandler(nextHandler, eventRef)
        case kEventGestureEnded:
            finishLatchedMagnifyIfNeeded()
            return CallNextEventHandler(nextHandler, eventRef)
        default:
            return CallNextEventHandler(nextHandler, eventRef)
        }
    }

    private func handleBackgroundTapCallback(type: CGEventType, cgEvent: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = backgroundGestureTap,
               backgroundGestureMonitoringEnabled && hasVisibleZoomablePin {
                gestureTapBackend.setEnabled(tap, true)
            }
            return
        }
        guard type.rawValue == Self.cgEventTypeGesture || type.rawValue == Self.cgEventTypeMagnify else {
            return
        }
        guard NSApp.modalWindow == nil else { return }
        guard let event = NSEvent(cgEvent: cgEvent),
              event.type == .magnify || event.type == .endGesture else {
            return
        }
        routeBackgroundGestureEvent(
            event,
            pointerLocation: NSEvent.mouseLocation,
            isAppActive: NSApp.isActive
        )
    }

    private func handleLocalGestureEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .magnify:
            return handleForegroundMagnifyEvent(event)
        case .endGesture:
            finishLatchedMagnifyIfNeeded()
            return event
        default:
            return event
        }
    }

    private func handleForegroundMagnifyEvent(_ event: NSEvent) -> NSEvent? {
        if hasAlreadyHandledMagnify(timestamp: event.timestamp) {
            return nil
        }
        return routeMagnifyEvent(
            event,
            pointerLocation: NSEvent.mouseLocation,
            ignoreEventWindow: false
        )
    }

    /// Routes `.magnify` arriving directly through a pin view or attached
    /// toolbar's responder chain so it shares latching and deduplication.
    func handleResponderMagnify(_ event: NSEvent, for controller: PinWindowController?) {
        guard event.type == .magnify,
              let controller,
              controller.isPinVisible,
              !hasAlreadyHandledMagnify(timestamp: event.timestamp) else {
            return
        }
        let isTerminal = !event.phase.intersection([.ended, .cancelled]).isEmpty
        magnifyState = isTerminal ? .idle : .latched(WeakPin(controller: controller))
        recordHandledMagnifyTimestamp(event.timestamp)
        controller.handleMagnify(with: event)
    }

    /// Routes trackpad gesture events observed via the listen-only HID/session tap.
    /// Deduplicates by event timestamp so active-app gestures handled via Carbon,
    /// local monitors, or the responder chain never zoom twice, while non-key
    /// pins remain zoomable whether Pinboard is inactive or active.
    func routeBackgroundGestureEvent(
        _ event: NSEvent,
        pointerLocation: CGPoint,
        isAppActive: Bool = NSApp.isActive
    ) {
        _ = isAppActive
        switch event.type {
        case .magnify:
            guard !hasAlreadyHandledMagnify(timestamp: event.timestamp) else { return }
            _ = routeMagnifyEvent(
                event,
                pointerLocation: pointerLocation,
                ignoreEventWindow: true
            )
        case .endGesture:
            finishLatchedMagnifyIfNeeded()
        default:
            break
        }
    }

    private func hasAlreadyHandledMagnify(timestamp: TimeInterval) -> Bool {
        guard timestamp > 0 else { return false }
        return recentHandledMagnifyTimestamps.contains {
            abs($0 - timestamp) < Self.magnifyTimestampTolerance
        }
    }

    private func recordHandledMagnifyTimestamp(_ timestamp: TimeInterval) {
        guard timestamp > 0, !hasAlreadyHandledMagnify(timestamp: timestamp) else { return }
        if recentHandledMagnifyTimestamps.count >= Self.maxRecentMagnifyTimestamps {
            recentHandledMagnifyTimestamps.removeFirst()
        }
        recentHandledMagnifyTimestamps.append(timestamp)
    }

    private func finishLatchedMagnifyIfNeeded() {
        if case .latched(let weakPin) = magnifyState,
           let target = weakPin.controller,
           target.isPinVisible {
            target.finishMagnifyGesture()
        }
        magnifyState = .idle
    }

    /// Routes `.magnify` to the hovered or latched `PinPanel`, consuming the
    /// event (`return nil`) when matched so key pins never zoom twice.
    @discardableResult
    func routeMagnifyEvent(
        _ event: NSEvent,
        pointerLocation: CGPoint = NSEvent.mouseLocation,
        ignoreEventWindow: Bool = false
    ) -> NSEvent? {
        guard event.type == .magnify else { return event }
        let phase = event.phase
        let isTerminal = !phase.intersection([.ended, .cancelled]).isEmpty

        if phase == .mayBegin || phase.contains(.began) {
            guard let target = candidateMagnifyPin(
                for: event,
                pointerLocation: pointerLocation,
                ignoreEventWindow: ignoreEventWindow
            ) else {
                magnifyState = phase.contains(.began) && !isTerminal ? .passthrough : .idle
                return event
            }
            magnifyState = isTerminal ? .idle : .latched(WeakPin(controller: target))
            recordHandledMagnifyTimestamp(event.timestamp)
            if phase.contains(.began) || event.magnification != 0 || isTerminal {
                target.handleMagnify(with: event)
            }
            return nil
        }

        if phase.isEmpty {
            magnifyState = .idle
            guard let target = candidateMagnifyPin(
                for: event,
                pointerLocation: pointerLocation,
                ignoreEventWindow: ignoreEventWindow
            ) else { return event }
            recordHandledMagnifyTimestamp(event.timestamp)
            target.handleMagnify(with: event)
            return nil
        }

        switch magnifyState {
        case .latched(let weakPin):
            if isTerminal { magnifyState = .idle }
            recordHandledMagnifyTimestamp(event.timestamp)
            if let target = weakPin.controller, target.isPinVisible {
                target.handleMagnify(with: event)
            }
            return nil
        case .passthrough:
            if isTerminal { magnifyState = .idle }
            return event
        case .idle:
            guard let target = candidateMagnifyPin(
                for: event,
                pointerLocation: pointerLocation,
                ignoreEventWindow: ignoreEventWindow
            ) else { return event }
            if !isTerminal {
                magnifyState = .latched(WeakPin(controller: target))
            }
            recordHandledMagnifyTimestamp(event.timestamp)
            target.handleMagnify(with: event)
            return nil
        }
    }

    private func candidateMagnifyPin(
        for event: NSEvent,
        pointerLocation: CGPoint,
        ignoreEventWindow: Bool
    ) -> PinWindowController? {
        if !ignoreEventWindow, let window = event.window, let pin = pinController(for: window) {
            return pin.isPinVisible ? pin : nil
        }
        return topmostVisiblePin(at: pointerLocation)
    }

    private func pinController(for window: NSWindow) -> PinWindowController? {
        ((window as? PinPanel) ?? (window.parent as? PinPanel))?.pinController
    }

    private func topmostVisiblePin(at screenPoint: CGPoint) -> PinWindowController? {
        guard let (candidatePin, candidateWindow) = frontmostLocalPinWindow(at: screenPoint) else {
            return nil
        }
        guard !externalOcclusionTester(candidateWindow, screenPoint) else {
            return nil
        }
        return candidatePin
    }

    private func frontmostLocalPinWindow(at screenPoint: CGPoint) -> (PinWindowController, NSWindow)? {
        if let numbers = NSWindow.windowNumbers(options: []), !numbers.isEmpty {
            for number in numbers {
                guard let window = NSApp.window(withWindowNumber: number.intValue),
                      window.isVisible,
                      !window.ignoresMouseEvents,
                      window.frame.contains(screenPoint) else { continue }
                guard let pin = pinController(for: window), pin.isPinVisible else {
                    return nil
                }
                return (pin, window)
            }
            return nil
        }
        if let pin = pins.last(where: { $0.isPinVisible && $0.panel.frame.contains(screenPoint) }) {
            return (pin, pin.panel)
        }
        return nil
    }

    static func isWindowOccludedInWindowServer(_ window: NSWindow, at screenPoint: CGPoint) -> Bool {
        let hitWindowNumber = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        guard hitWindowNumber > 0, hitWindowNumber != window.windowNumber else {
            return false
        }
        guard let allNumbers = NSWindow.windowNumbers(options: [.allApplications])?.map(\.intValue),
              let hitIndex = allNumbers.firstIndex(of: hitWindowNumber),
              let candidateIndex = allNumbers.firstIndex(of: window.windowNumber) else {
            return false
        }
        return hitIndex < candidateIndex
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
