import AppKit

/// Rich text pin. Content stays an `NSAttributedString` end to end so RTF
/// attributes survive import, editing and copy-out untouched.
final class TextPinView: NSView, PinContentDisplaying, NSTextViewDelegate {
    weak var pinController: PinWindowController?

    private let scrollView = NSScrollView()
    private let textView: PinTextView
    private(set) var isEditing = false
    private(set) var formatToolbar: TextFormatToolbar?

    var minimumPinSize: CGSize { CGSize(width: 140, height: 56) }

    /// Exposed for `TextFormatter`, which applies attributes to this view.
    var editableTextView: NSTextView { textView }

    init(attributedString: NSAttributedString) {
        // Explicit TextKit 1 stack: TextKit 2 lays out through the display
        // cycle, which is skipped while the run loop sits in event-tracking
        // mode — exactly when a live window resize needs to re-wrap.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        textView = PinTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), textContainer: container)
        super.init(frame: .zero)

        textView.pinView = self
        textView.delegate = self
        textView.textStorage?.setAttributedString(attributedString)
        textView.typingAttributes = attributedString.length > 0
            ? attributedString.attributes(at: attributedString.length - 1, effectiveRange: nil)
            : ClipboardReader.defaultTextAttributes()
        textView.setReadOnlyMode()

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        // Every layer of the stack must be clear or a grey plate shows through.
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        applyPadding()
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: Preferences.didChange, object: nil
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowGeometryChanged),
            name: NSWindow.didResizeNotification, object: window
        )
        syncWrapWidth()
    }

    /// Posted synchronously from `setFrame(_:display:)`, including inside the
    /// modal loop that drives edge resizing.
    @objc private func windowGeometryChanged() {
        formatToolbar?.reposition()
        syncWrapWidth()
    }

    override func layout() {
        super.layout()
        syncWrapWidth()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncWrapWidth()
    }

    /// Re-wraps the text for the current window width, synchronously.
    private func syncWrapWidth() {
        let contentSize = scrollView.contentSize
        guard contentSize.width > 1, let container = textView.textContainer else { return }

        let wrapWidth = max(contentSize.width - textView.textContainerInset.width * 2, 1)
        if abs(container.size.width - wrapWidth) > 0.5 {
            container.size = NSSize(width: wrapWidth, height: .greatestFiniteMagnitude)
        }
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        if abs(textView.frame.width - contentSize.width) > 0.5 {
            textView.setFrameSize(NSSize(width: contentSize.width, height: textView.frame.height))
        }
        textView.layoutManager?.ensureLayout(for: container)
        textView.sizeToFit()
        textView.needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Frame of the text view inside the scroll view; its width is the wrap
    /// width and its height grows as lines wrap.
    var laidOutTextFrame: NSRect { textView.frame }

    /// Width the text container wraps at.
    var textWrapWidth: CGFloat { textView.textContainer?.size.width ?? 0 }

    /// True when nothing in the text stack paints a backdrop.
    var isFullyTransparent: Bool {
        !textView.drawsBackground && !scrollView.drawsBackground && !scrollView.contentView.drawsBackground
    }

    var attributedString: NSAttributedString {
        textView.textStorage.map { NSAttributedString(attributedString: $0) } ?? NSAttributedString()
    }

    // MARK: - Editing

    func beginEditing(at pointInTextView: NSPoint?) {
        pinController?.requestKeyboardFocus()
        if !isEditing {
            isEditing = true
            textView.setEditableMode()
            pinController?.rootView.isEditingContent = true
            showFormatToolbar()
        }
        window?.makeFirstResponder(textView)
        if let pointInTextView {
            let index = textView.characterIndexForInsertion(at: pointInTextView)
            textView.setSelectedRange(NSRange(location: index, length: 0))
        }
        formatToolbar?.syncFromSelection()
        textView.needsDisplay = true
    }

    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.setReadOnlyMode()
        pinController?.rootView.isEditingContent = false
        formatToolbar?.hide()
        if window?.firstResponder === textView { window?.makeFirstResponder(nil) }
        textView.needsDisplay = true
        pinController?.refreshChrome()
    }

    /// Keyboard focus goes back to the text after a toolbar interaction, which
    /// may have made the toolbar panel (e.g. the size field) the key window.
    func resumeEditingFocus() {
        guard isEditing else { return }
        pinController?.requestKeyboardFocus()
        window?.makeFirstResponder(textView)
    }

    /// Editing continues while focus sits in our own toolbar, the colour panel
    /// or the font panel — including when nothing is key, which happens while a
    /// colour popover is open. It ends when another pin or another app takes over.
    func handleResignKey() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEditing else { return }
            guard NSApp.isActive else { return self.endEditing() }
            if let key = NSApp.keyWindow, key is PinPanel, key !== self.window { self.endEditing() }
        }
    }

    private func showFormatToolbar() {
        guard let window else { return }
        if formatToolbar == nil { formatToolbar = TextFormatToolbar(pin: self) }
        formatToolbar?.show(attachedTo: window)
    }

    // MARK: - NSTextViewDelegate

    func textViewDidChangeSelection(_ notification: Notification) {
        formatToolbar?.syncFromSelection()
    }

    func textDidChange(_ notification: Notification) {
        formatToolbar?.syncFromSelection()
        pinController?.contentDidChange()
    }

    func toggleEditing() {
        if isEditing {
            endEditing()
        } else {
            beginEditing(at: nil)
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        }
    }

    // MARK: - PinContentDisplaying

    func idealSize(fitting maxSize: CGSize) -> CGSize {
        let padding = CGFloat(Preferences.shared.textPadding)
        let maxTextWidth = max(120, min(maxSize.width, 520) - padding * 2)
        let measured = TextPinView.measure(attributedString, maxWidth: maxTextWidth)
        let width = min(max(measured.width + padding * 2 + 2, minimumPinSize.width), maxSize.width)
        let height = min(max(measured.height + padding * 2 + 2, minimumPinSize.height), maxSize.height)
        return CGSize(width: ceil(width), height: ceil(height))
    }

    func currentContent() -> PinContent { .text(attributedString) }

    func cursor(at point: NSPoint) -> NSCursor { isEditing ? .iBeam : .openHand }

    /// Writes RTFD/RTF plus a plain text fallback; `NSAttributedString` as a
    /// pasteboard writer emits all of them, so formatting survives the round trip.
    func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([attributedString])
    }

    func chromeItems() -> [ChromeItem] {
        [ChromeItem(symbol: isEditing ? "checkmark" : "pencil",
                    tooltip: isEditing ? "Done Editing" : "Edit Text",
                    action: { [weak self] in
                        self?.toggleEditing()
                        self?.pinController?.refreshChrome()
                    },
                    isToggled: isEditing)]
    }

    func contextMenuItems() -> [NSMenuItem] { [] }

    // MARK: - Helpers

    private func applyPadding() {
        let padding = CGFloat(Preferences.shared.textPadding)
        textView.textContainerInset = NSSize(width: padding, height: padding)
    }

    @objc private func preferencesChanged() {
        applyPadding()
    }

    static func measure(_ text: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        guard text.length > 0 else { return CGSize(width: 160, height: 24) }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return CGSize(width: min(ceil(used.width), maxWidth), height: ceil(used.height))
    }
}

/// Text view that doubles as the window's drag surface while not editing.
final class PinTextView: NSTextView {
    weak var pinView: TextPinView?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func configure() {
        isRichText = true
        allowsUndo = true
        importsGraphics = true
        usesFontPanel = true
        usesRuler = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isContinuousSpellCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        drawsBackground = false
        backgroundColor = .clear
        isVerticallyResizable = true
        isHorizontallyResizable = false
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0
    }

    func setReadOnlyMode() {
        isEditable = false
        isSelectable = false
    }

    func setEditableMode() {
        isEditable = true
        isSelectable = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { isEditable }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return super.mouseDown(with: event) }
        if event.modifierFlags.contains(.command) || !isEditable {
            let point = convert(event.locationInWindow, from: nil)
            WindowInteraction.move(window: window, dragCursor: .closedHand, endCursor: .openHand) { [weak self] in
                guard let self else { return }
                self.pinView?.beginEditing(at: point)
                self.pinView?.pinController?.refreshChrome()
                NSCursor.iBeam.set()
            }
            return
        }
        super.mouseDown(with: event)
    }

    override func magnify(with event: NSEvent) {
        pinView?.pinController?.zoom(by: 1 + event.magnification)
    }

    override func cancelOperation(_ sender: Any?) {
        pinView?.endEditing()
        pinView?.pinController?.refreshChrome()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let controller = pinView?.pinController else { return menu }
        menu.addItem(.separator())
        controller.appendPinItems(to: menu, includingContentItems: false)
        return menu
    }
}
