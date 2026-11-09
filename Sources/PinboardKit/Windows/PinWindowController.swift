import AppKit

/// Owns one floating pin: its panel, root view and content view.
final class PinWindowController: NSObject, NSWindowDelegate {
    /// Explicit window lifecycle state; prevents closed pins from being
    /// accidentally re-shown or resized as ghost panels.
    enum LifecycleState: Equatable {
        case visible
        case hidden
        case closed
    }

    /// Explicit association between a live pin and its `HistoryStore` record.
    enum HistoryState: Equatable {
        /// Never registered in a store yet (eligible for adoption if a store is installed later).
        case unregistered
        /// Linked to `id` in `HistoryStore`; `isDirty` tracks unsaved edits awaiting a write.
        case tracked(id: UUID, isDirty: Bool)
        /// Record was explicitly deleted by the user while the pin stayed open; never re-adopted.
        case detached
    }

    /// Whether the pin's background follows the mode/theme default or an explicit user toggle.
    enum BackgroundPolicy: Equatable {
        case automatic
        case explicit(visible: Bool)
    }

    /// Floating-point state for continuous trackpad pinch/scroll zoom gestures.
    private struct ZoomGestureSession {
        var currentSize: CGSize = .zero
        var anchorCenter: CGPoint = .zero
        var lastTimestamp: TimeInterval = 0
        var shadowInvalidateWorkItem: DispatchWorkItem?

        mutating func sync(to frame: NSRect) {
            currentSize = frame.size
            anchorCenter = CGPoint(x: frame.midX, y: frame.midY)
        }

        mutating func scheduleShadowInvalidation(for panel: NSPanel) {
            shadowInvalidateWorkItem?.cancel()
            let work = DispatchWorkItem { [weak panel] in
                panel?.invalidateShadow()
            }
            shadowInvalidateWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        mutating func flushShadowInvalidation(for panel: NSPanel) {
            shadowInvalidateWorkItem?.cancel()
            shadowInvalidateWorkItem = nil
            panel.invalidateShadow()
        }

        mutating func cancelShadowInvalidation() {
            shadowInvalidateWorkItem?.cancel()
            shadowInvalidateWorkItem = nil
        }
    }

    let id: UUID
    let kind: PinKind
    let panel: PinPanel
    let rootView = PinRootView()
    let contentView: PinContentDisplaying

    private(set) var lifecycleState: LifecycleState = .visible
    var isPinHidden: Bool { lifecycleState == .hidden }
    weak var manager: PinWindowManager?

    private(set) var historyState: HistoryState = .unregistered

    /// Links this pin to its history record. Edits update that record in
    /// place — they never spawn new entries.
    var historyRecordID: UUID? {
        get {
            if case .tracked(let id, _) = historyState { return id }
            return nil
        }
        set {
            if let id = newValue {
                let dirty: Bool
                if case .tracked(_, let isDirty) = historyState { dirty = isDirty } else { dirty = false }
                historyState = .tracked(id: id, isDirty: dirty)
            } else if historyState != .detached {
                historyState = .unregistered
            }
        }
    }

    /// True once the user deleted this pin's history. It is never registered
    /// again, even if a store is installed later.
    var historyWasDeleted: Bool {
        get { historyState == .detached }
        set {
            if newValue {
                historyState = .detached
            } else if historyState == .detached {
                historyState = .unregistered
            }
        }
    }

    func markHistoryTracked(id: UUID, isDirty: Bool = true) {
        historyState = .tracked(id: id, isDirty: isDirty)
    }

    func markHistoryDirty(_ isDirty: Bool) {
        guard case .tracked(let id, _) = historyState else { return }
        historyState = .tracked(id: id, isDirty: isDirty)
    }

    func detachHistory() {
        historyState = .detached
    }

    /// Per-window opacity (1 = fully opaque). Lives on the pin, not in
    /// preferences — each window manages its own.
    var opacity: Double = 1.0 {
        didSet { panel.alphaValue = CGFloat(opacity) }
    }

    /// Off by default: the size the user drags out always wins over the
    /// content's natural ratio. Can be switched on per pin from the menu.
    var isAspectLocked = false

    /// Only image pins have a zoom percentage concept; text pins simply resize
    /// their frame and re-wrap text.
    var supportsZoom: Bool { kind == .image }

    /// Reference 100% size for the zoom badge and reset-zoom action.
    private(set) var baseSize: CGSize = .zero
    private var zoomSession = ZoomGestureSession()

    init(content: PinContent, id: UUID = UUID(), annotations: AnnotationStore.Payload? = nil, textMode: TextContentMode? = nil) {
        self.id = id
        self.kind = content.kind
        switch content {
        case .text(let attributed):
            // nil textMode means "follow the global default"; history re-pins
            // pass the record's stored mode so they are reproducible.
            contentView = TextPinView(attributedString: attributed,
                                      mode: textMode ?? Preferences.shared.textMode,
                                      hasExplicitMode: textMode != nil)
        case .image(let image):
            contentView = ImagePinView(image: image, annotations: annotations)
        }
        panel = PinPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200))
        super.init()

        contentView.pinController = self
        rootView.pinController = self
        rootView.supportsZoom = supportsZoom
        rootView.usesHoverBackground = false
        rootView.cornerRadius = 12
        rootView.closeChrome.onAction = { [weak self] in self?.closePin() }
        rootView.hideChrome.onAction = { [weak self] in self?.hidePin() }
        rootView.zoomBadge.onResetZoom = { [weak self] in self?.resetZoom() }
        rootView.install(contentView: contentView)
        panel.contentView = rootView
        panel.pinController = self
        panel.delegate = self
        panel.minSize = contentView.minimumPinSize

        refreshChrome()
        applyPreferences()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyPreferences),
            name: Preferences.didChange, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Geometry

    func idealFrame(anchoredAt topLeft: CGPoint, on screen: NSScreen?) -> NSRect {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxSize = CGSize(width: visible.width * 0.8, height: visible.height * 0.8)
        let size = contentView.idealSize(fitting: maxSize)
        var frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        frame.origin.y = min(max(frame.origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        return frame
    }

    func setFrame(_ frame: NSRect) {
        baseSize = frame.size
        zoomSession.sync(to: frame)
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
        rootView.updateZoomPercentage(zoomPercentage)
    }

    func syncBaseSizeToCurrentFrame() {
        let frame = panel.frame
        baseSize = frame.size
        zoomSession.sync(to: frame)
        rootView.updateZoomPercentage(100)
    }

    /// Grows the window so content that arrived after creation (an image
    /// fetched for a pasted HTML message) is visible. Only ever grows, keeps
    /// the top-left corner anchored and stays inside the screen, mirroring
    /// `idealFrame`.
    func growToFitContent() {
        guard lifecycleState != .closed, !rootView.isEditingContent else { return }
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxSize = CGSize(width: visible.width * 0.8, height: visible.height * 0.8)
        let ideal = contentView.idealSize(fitting: maxSize)
        let frame = panel.frame
        let size = CGSize(width: max(frame.width, ideal.width), height: max(frame.height, ideal.height))
        guard size.width > frame.width + 1 || size.height > frame.height + 1 else { return }

        var grown = NSRect(x: frame.origin.x, y: frame.maxY - size.height,
                           width: size.width, height: size.height)
        grown.origin.x = min(max(grown.origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        grown.origin.y = min(max(grown.origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrame(grown)
    }

    func beginResize(edge: ResizeEdge) {
        WindowInteraction.resize(
            window: panel,
            edge: edge,
            minSize: contentView.minimumPinSize,
            aspectRatio: isAspectLocked ? contentView.contentAspectRatio : nil
        )
        zoomSession.sync(to: panel.frame)
        rootView.updateZoomPercentage(zoomPercentage, animated: true)
        rootView.refreshCursorAtCurrentMouseLocation()
    }

    var zoomPercentage: Int {
        let referenceWidth = baseSize.width > 1 ? baseSize.width : panel.frame.width
        let currentWidth = zoomSession.currentSize.width > 1 ? zoomSession.currentSize.width : panel.frame.width
        guard referenceWidth > 1 else { return 100 }
        return max(1, Int(((currentWidth / referenceWidth) * 100).rounded()))
    }

    func resetZoom() {
        guard supportsZoom, baseSize.width > 1, baseSize.height > 1 else { return }
        let frame = panel.frame
        zoomSession.currentSize = baseSize
        zoomSession.anchorCenter = CGPoint(x: frame.midX, y: frame.midY)
        let origin = CGPoint(
            x: (frame.midX - baseSize.width / 2).rounded(),
            y: (frame.midY - baseSize.height / 2).rounded()
        )
        panel.setFrame(NSRect(origin: origin, size: baseSize), display: true)
        panel.invalidateShadow()
        rootView.showZoomFeedback(percent: 100)
    }

    func handleMagnify(with event: NSEvent) {
        guard supportsZoom else { return }
        if event.phase == .began {
            zoomSession.sync(to: panel.frame)
        }
        if event.magnification != 0 {
            zoom(by: 1 + event.magnification, isContinuousGesture: true)
        }
        if event.phase == .ended || event.phase == .cancelled {
            zoomSession.flushShadowInvalidation(for: panel)
        }
    }

    func handleScrollWheel(with event: NSEvent) {
        guard supportsZoom else { return }
        guard !rootView.isEditingContent || event.modifierFlags.contains(.command) else { return }
        if event.phase == .began {
            zoomSession.sync(to: panel.frame)
        }
        let rawDelta: CGFloat
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            rawDelta = event.scrollingDeltaX
        } else {
            rawDelta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        }
        guard abs(rawDelta) > 0.01 else { return }
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.0045 : 0.03
        let factor = max(0.7, min(1.3, 1 + rawDelta * sensitivity))
        let isContinuous = event.phase != [] || event.momentumPhase != []
        zoom(by: factor, isContinuousGesture: isContinuous)
        if event.phase == .ended || event.momentumPhase == .ended {
            zoomSession.flushShadowInvalidation(for: panel)
        }
    }

    /// Uniform zoom around the window centre, used by the trackpad pinch and
    /// two-finger swipe gestures. Keeps unrounded floating-point state across
    /// continuous steps so the centre and aspect ratio never drift.
    func zoom(by factor: CGFloat, isContinuousGesture: Bool = false) {
        guard supportsZoom, factor > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let frame = panel.frame
        if baseSize.width <= 0 || baseSize.height <= 0 {
            baseSize = frame.size
        }
        if now - zoomSession.lastTimestamp > 0.25 || zoomSession.currentSize.width <= 0 || zoomSession.currentSize.height <= 0 {
            zoomSession.sync(to: frame)
        }
        zoomSession.lastTimestamp = now

        let minSize = contentView.minimumPinSize
        let visible = (panel.screen ?? NSScreen.underMouse)?.visibleFrame.size ?? CGSize(width: 4000, height: 3000)
        let lower = max(minSize.width / zoomSession.currentSize.width, minSize.height / zoomSession.currentSize.height)
        let upper = max(lower, min(visible.width / zoomSession.currentSize.width, visible.height / zoomSession.currentSize.height))
        let clamped = min(max(factor, lower), upper)
        guard abs(clamped - 1) > 0.0001 else { return }

        zoomSession.currentSize = CGSize(
            width: zoomSession.currentSize.width * clamped,
            height: zoomSession.currentSize.height * clamped
        )
        let size = isContinuousGesture
            ? zoomSession.currentSize
            : CGSize(width: zoomSession.currentSize.width.rounded(), height: zoomSession.currentSize.height.rounded())
        let origin = isContinuousGesture
            ? CGPoint(x: zoomSession.anchorCenter.x - size.width / 2, y: zoomSession.anchorCenter.y - size.height / 2)
            : CGPoint(x: (zoomSession.anchorCenter.x - size.width / 2).rounded(), y: (zoomSession.anchorCenter.y - size.height / 2).rounded())
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        rootView.showZoomFeedback(percent: zoomPercentage)

        if isContinuousGesture {
            zoomSession.scheduleShadowInvalidation(for: panel)
        } else {
            zoomSession.flushShadowInvalidation(for: panel)
        }
    }

    // MARK: - Visibility

    func present() {
        guard lifecycleState != .closed else { return }
        let wasHidden = lifecycleState == .hidden
        lifecycleState = .visible
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        if wasHidden { manager?.notifyChange() }
    }

    func showPin() {
        guard lifecycleState == .hidden else { return }
        lifecycleState = .visible
        panel.orderFrontRegardless()
        manager?.notifyChange()
    }

    func hidePin() {
        guard lifecycleState == .visible else { return }
        endEditing()
        rootView.resetPointerState()
        lifecycleState = .hidden
        panel.orderOut(nil)
        manager?.notifyChange()
    }

    var isPinVisible: Bool { lifecycleState == .visible && panel.isVisible }

    /// Copy must succeed before the pin disappears, including pending edits.
    @discardableResult
    func copyAndClose(to pasteboard: NSPasteboard = .general) -> Bool {
        endEditing()
        guard contentView.copy(to: pasteboard) else {
            Toast.show("Couldn't copy pin; it remains open", duration: 3)
            return false
        }
        closePin()
        return true
    }

    func closePin() {
        guard lifecycleState != .closed else { return }
        endEditing()
        rootView.resetPointerState()
        zoomSession.cancelShadowInvalidation()
        lifecycleState = .closed
        panel.delegate = nil
        panel.orderOut(nil)
        panel.contentView = nil
        manager?.remove(self)
    }

    // MARK: - Focus

    /// Takes keyboard focus. Only called from explicit editing gestures so the
    /// user's frontmost app is never interrupted by passive pin activity.
    func requestKeyboardFocus() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func endEditing() {
        contentView.endEditing()
    }

    /// Content mutated (typed text, attribute change, annotation edit). The
    /// manager debounces this into a history write.
    func contentDidChange() {
        manager?.pinContentDidChange(self)
    }

    func windowDidResignKey(_ notification: Notification) {
        contentView.handleResignKey()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        contentView.pinUndoManager
    }

    // MARK: - Chrome & menus

    func refreshChrome() {
        rootView.setEditChromeItem(contentView.editChromeItem())
        rootView.setSaveChromeItem(contentView.saveChromeItem())
        var items = [
            ChromeItem(symbol: "doc.on.doc", tooltip: "Copy") { [weak self] in
                self?.contentView.copyToPasteboard()
            }
        ]
        items.append(contentsOf: contentView.chromeItems())
        rootView.setChromeItems(items)
        rootView.updateZoomPercentage(zoomPercentage)
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        appendPinItems(to: menu, includingContentItems: true)
        return menu
    }

    /// Appends the shared pin commands to `menu`; used for the window context
    /// menu and to extend the text view's built-in editing menu.
    func appendPinItems(to menu: NSMenu, includingContentItems: Bool) {
        if includingContentItems {
            let contentItems = contentView.contextMenuItems()
            for item in contentItems { menu.addItem(item) }
            if !contentItems.isEmpty { menu.addItem(.separator()) }
            menu.addItem(.pinAction("Copy", symbol: "doc.on.doc") { [weak self] in
                self?.contentView.copyToPasteboard()
            })
            menu.addItem(.pinAction("Copy and Close", symbol: "doc.on.doc.fill") { [weak self] in
                self?.copyAndClose()
            })
            if let saveItem = contentView.saveContextMenuItem() {
                menu.addItem(saveItem)
            }
            menu.addItem(.separator())
        }
        for item in contentView.viewContextMenuItems() {
            menu.addItem(item)
        }
        if contentView.contentAspectRatio != nil {
            menu.addItem(.pinAction(
                isAspectLocked ? "Unlock Aspect Ratio" : "Lock Aspect Ratio",
                symbol: isAspectLocked ? "lock.open" : "lock"
            ) { [weak self] in
                self?.isAspectLocked.toggle()
            })
        }
        menu.addItem(opacityItem())
        menu.addItem(.separator())
        menu.addItem(.pinAction("Hide Pin", symbol: "eye.slash") { [weak self] in
            self?.hidePin()
        })
        menu.addItem(.pinAction("Close Pin", symbol: "xmark") { [weak self] in
            self?.closePin()
        })
    }

    /// Per-pin opacity control embedded in the context menu: a labelled
    /// 0–100% slider that adjusts this window's `alphaValue` live.
    private func opacityItem() -> NSMenuItem {
        let iconView = NSImageView()
        iconView.image = NSMenuItem.pinMenuSymbol("circle.lefthalf.filled")
        iconView.contentTintColor = .labelColor
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16)
        ])

        let label = NSTextField(labelWithString: "Opacity")
        label.font = .menuFont(ofSize: 0)
        label.textColor = .labelColor

        let percent = NSTextField(labelWithString: "\(Int((opacity * 100).rounded()))%")
        percent.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        percent.textColor = .secondaryLabelColor
        percent.alignment = .right
        percent.translatesAutoresizingMaskIntoConstraints = false
        percent.widthAnchor.constraint(equalToConstant: 36).isActive = true

        let slider = NSSlider(value: opacity, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let target = MenuActionTarget { [weak self, weak slider, weak percent] in
            guard let self, let slider else { return }
            self.opacity = slider.doubleValue
            percent?.stringValue = "\(Int((slider.doubleValue * 100).rounded()))%"
        }
        slider.target = target
        slider.action = #selector(MenuActionTarget.run(_:))

        let row = NSStackView(views: [iconView, label, slider, percent])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        row.frame = NSRect(x: 0, y: 0, width: 256, height: 26)

        let item = NSMenuItem()
        item.view = row
        item.representedObject = target
        return item
    }

    // MARK: - Preferences

    /// Opt a text pin back into the opaque "paper" look, per pin.
    func setBackgroundVisible(_ visible: Bool) {
        backgroundPolicy = .explicit(visible: visible)
        applyBackground(visible: visible)
    }

    /// Set once the user toggles this pin's background: a theme change then
    /// leaves their choice alone.
    private(set) var backgroundPolicy: BackgroundPolicy = .automatic

    /// The Markdown theme's paper for this pin, or nil when it keeps the
    /// standard background (not a Markdown pin, or a theme without paper).
    private var themedBackground: NSColor? {
        guard let textView = contentView as? TextPinView, textView.textMode == .markdown else { return nil }
        return Preferences.shared.markdownTheme.background
    }

    /// Applies the Markdown theme's paper or the standard opaque text background.
    func applyThemeBackground() {
        switch backgroundPolicy {
        case .automatic:
            applyBackground(visible: true)
        case .explicit(let visible):
            applyBackground(visible: visible)
        }
    }

    private func applyBackground(visible: Bool) {
        rootView.themedBackground = themedBackground
        rootView.drawsBackground = visible
        rootView.drawsBorder = visible || kind == .image
        panel.hasShadow = Preferences.shared.showShadow && rendersOpaqueContent
        panel.invalidateShadow()
    }

    /// A shadow around a transparent window would trace the glyph outlines.
    private var rendersOpaqueContent: Bool { rootView.drawsBackground || kind == .image }

    @objc func applyPreferences() {
        let prefs = Preferences.shared
        panel.alphaValue = CGFloat(opacity)
        panel.hasShadow = prefs.showShadow && rendersOpaqueContent
        panel.level = prefs.topLevel.windowLevel
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary]
        if prefs.showOnAllSpaces { behavior.insert(.canJoinAllSpaces) }
        panel.collectionBehavior = behavior
        panel.invalidateShadow()

        // A pin the user never switched follows the global text mode, so a
        // settings change re-renders it in place.
        if let textView = contentView as? TextPinView,
           !textView.hasExplicitTextMode, textView.textMode != prefs.textMode {
            textView.setTextMode(prefs.textMode, explicit: false)
            contentDidChange()
        }
        applyThemeBackground()
    }

    // MARK: - Persistence

    func snapshot() -> PinSnapshot {
        let state = contentView.captureState()
        return PinSnapshot(id: id, content: state.content, frame: panel.frame,
                           isHidden: isPinHidden, annotationData: state.annotationData, opacity: opacity,
                           textMode: state.textMode)
    }
}

/// Retains a closure for dynamically built menu items.
final class MenuActionTarget: NSObject, NSMenuItemValidation {
    private let handler: () -> Void
    private let isEnabled: Bool

    init(isEnabled: Bool = true, handler: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.handler = handler
    }

    @objc func run(_ sender: Any?) { handler() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { isEnabled }
}

extension NSMenuItem {
    static func pinAction(
        _ title: String,
        symbol: String? = nil,
        isEnabled: Bool = true,
        handler: @escaping () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.run(_:)), keyEquivalent: "")
        let target = MenuActionTarget(isEnabled: isEnabled, handler: handler)
        item.target = target
        item.representedObject = target
        item.isEnabled = isEnabled
        if let symbol {
            item.image = pinMenuSymbol(symbol)
        }
        return item
    }

    static func pinMenuSymbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }
}
