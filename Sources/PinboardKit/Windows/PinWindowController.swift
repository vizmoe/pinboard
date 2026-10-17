import AppKit

/// Owns one floating pin: its panel, root view and content view.
final class PinWindowController: NSObject, NSWindowDelegate {
    let id: UUID
    let kind: PinKind
    let panel: PinPanel
    let rootView = PinRootView()
    let contentView: PinContentDisplaying

    private(set) var isPinHidden = false
    weak var manager: PinWindowManager?

    /// Links this pin to its history record. Edits update that record in
    /// place — they never spawn new entries.
    var historyRecordID: UUID?

    /// True once the user deleted this pin's history. It is never registered
    /// again, even if a store is installed later.
    var historyWasDeleted = false

    /// Per-window opacity (1 = fully opaque). Lives on the pin, not in
    /// preferences — each window manages its own.
    var opacity: Double = 1.0 {
        didSet { panel.alphaValue = CGFloat(opacity) }
    }

    /// Off by default: the size the user drags out always wins over the
    /// content's natural ratio. Can be switched on per pin from the menu.
    var isAspectLocked = false

    init(content: PinContent, id: UUID = UUID(), annotationData: Data? = nil, textMode: TextContentMode? = nil) {
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
            contentView = ImagePinView(image: image, annotationData: annotationData)
        }
        panel = PinPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200))
        super.init()

        contentView.pinController = self
        rootView.pinController = self
        // Text pins are fully transparent: only the glyphs are on screen.
        rootView.drawsBackground = false
        rootView.drawsBorder = kind == .image
        rootView.usesHoverBackground = kind == .text
        rootView.cornerRadius = 6
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
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    /// Grows the window so content that arrived after creation (an image
    /// fetched for a pasted HTML message) is visible. Only ever grows, keeps
    /// the top-left corner anchored and stays inside the screen, mirroring
    /// `idealFrame`.
    func growToFitContent() {
        guard !rootView.isEditingContent else { return }
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
    }

    /// Uniform zoom around the window centre, used by the trackpad pinch
    /// gesture. Scales the current frame, so a freely resized window keeps the
    /// proportions the user gave it.
    func zoom(by factor: CGFloat) {
        guard factor > 0 else { return }
        let frame = panel.frame
        let minSize = contentView.minimumPinSize
        let visible = (panel.screen ?? NSScreen.underMouse)?.visibleFrame.size ?? CGSize(width: 4000, height: 3000)
        let lower = max(minSize.width / frame.width, minSize.height / frame.height)
        let upper = max(lower, min(visible.width / frame.width, visible.height / frame.height))
        let clamped = min(max(factor, lower), upper)
        guard abs(clamped - 1) > 0.0001 else { return }

        let size = CGSize(width: (frame.width * clamped).rounded(), height: (frame.height * clamped).rounded())
        let origin = CGPoint(x: (frame.midX - size.width / 2).rounded(), y: (frame.midY - size.height / 2).rounded())
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
    }

    // MARK: - Visibility

    func present() {
        isPinHidden = false
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    func showPin() {
        guard isPinHidden else { return }
        isPinHidden = false
        panel.orderFrontRegardless()
    }

    func hidePin() {
        guard !isPinHidden else { return }
        endEditing()
        isPinHidden = true
        panel.orderOut(nil)
    }

    var isPinVisible: Bool { !isPinHidden && panel.isVisible }

    func closePin() {
        endEditing()
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
        var items = contentView.chromeItems()
        items.append(ChromeItem(symbol: "doc.on.doc", tooltip: "Copy") { [weak self] in
            self?.contentView.copyToPasteboard()
        })
        items.append(ChromeItem(symbol: "eye.slash", tooltip: "Hide Pin") { [weak self] in
            self?.hidePin()
            self?.manager?.notifyChange()
        })
        items.append(ChromeItem(symbol: "xmark", tooltip: "Close Pin") { [weak self] in
            self?.closePin()
        })
        rootView.setChromeItems(items)
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
            for item in contentView.contextMenuItems() { menu.addItem(item) }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(actionItem("Copy Content") { [weak self] in self?.contentView.copyToPasteboard() })
        }
        menu.addItem(actionItem(isAspectLocked ? "Unlock Aspect Ratio" : "Lock Aspect Ratio") { [weak self] in
            self?.isAspectLocked.toggle()
        })
        menu.addItem(opacityItem())
        if kind == .text {
            menu.addItem(actionItem(rootView.drawsBackground ? "Use Transparent Background" : "Use Opaque Background") { [weak self] in
                guard let self else { return }
                self.setBackgroundVisible(!self.rootView.drawsBackground)
            })
            menu.addItem(textModeItem())
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Hide Pin") { [weak self] in
            self?.hidePin()
            self?.manager?.notifyChange()
        })
        menu.addItem(actionItem("Close Pin") { [weak self] in self?.closePin() })
    }

    private func actionItem(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.run(_:)), keyEquivalent: "")
        let target = MenuActionTarget(handler: handler)
        item.target = target
        item.representedObject = target
        return item
    }

    /// Per-window text mode picker. Choosing a mode here makes this pin stop
    /// following the global default; other pins are unaffected.
    private func textModeItem() -> NSMenuItem {
        let current = (contentView as? TextPinView)?.textMode
        let item = NSMenuItem(title: "Text Mode", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for mode in TextContentMode.allCases {
            let entry = actionItem(mode.title) { [weak self] in
                guard let self, let textView = self.contentView as? TextPinView else { return }
                textView.setTextMode(mode, explicit: true)
                self.contentDidChange()
            }
            entry.state = current == mode ? .on : .off
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    /// Per-pin opacity control embedded in the context menu: a labelled
    /// 0–100% slider that adjusts this window's `alphaValue` live.
    private func opacityItem() -> NSMenuItem {
        let label = NSTextField(labelWithString: "Opacity")
        label.font = .menuFont(ofSize: 0)

        let percent = NSTextField(labelWithString: "\(Int((opacity * 100).rounded()))%")
        percent.font = .menuFont(ofSize: 0)
        percent.alignment = .right
        percent.translatesAutoresizingMaskIntoConstraints = false
        percent.widthAnchor.constraint(equalToConstant: 36).isActive = true

        let slider = NSSlider(value: opacity, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let target = MenuActionTarget { [weak self, weak slider, weak percent] in
            guard let self, let slider else { return }
            self.opacity = slider.doubleValue
            percent?.stringValue = "\(Int((slider.doubleValue * 100).rounded()))%"
        }
        slider.target = target
        slider.action = #selector(MenuActionTarget.run(_:))

        let row = NSStackView(views: [label, slider, percent])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 12)
        row.frame = NSRect(x: 0, y: 0, width: 250, height: 26)

        let item = NSMenuItem()
        item.view = row
        item.representedObject = target
        return item
    }

    // MARK: - Preferences

    /// Opt a text pin back into the opaque "paper" look, per pin.
    func setBackgroundVisible(_ visible: Bool) {
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
final class MenuActionTarget: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run(_ sender: Any?) { handler() }
}
