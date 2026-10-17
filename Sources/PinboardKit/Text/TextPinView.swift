import AppKit

/// Text pin. Rich text pins keep an `NSAttributedString` end to end so RTF
/// attributes survive import, editing and copy-out untouched. Markdown pins
/// keep the raw source as canonical content: while idle they show the rendered
/// document, clicking them edits the source.
final class TextPinView: NSView, PinContentDisplaying, NSTextViewDelegate {
    weak var pinController: PinWindowController?

    private let scrollView = NSScrollView()
    private let textView: PinTextView
    private(set) var isEditing = false
    private(set) var formatToolbar: TextFormatToolbar?

    /// How this pin currently interprets its text.
    private(set) var textMode: TextContentMode
    /// False while the pin follows `Preferences.textMode`. A per-window switch
    /// pins the mode so later global changes leave this pin alone.
    private(set) var hasExplicitTextMode: Bool

    /// Raw source for the non-rich modes. A Markdown pin renders it for
    /// display; a Plain Text pin shows it as-is. Rich pins never use it.
    private var sourceText: String
    /// The representation this pin had before the last mode switch. Kept until
    /// the next content edit, so a switch made by accident — or by the global
    /// default — can be flipped back without losing formatting.
    private var modeBackup: (mode: TextContentMode, attributed: NSAttributedString)?

    var minimumPinSize: CGSize { CGSize(width: 140, height: 56) }

    /// Exposed for `TextFormatter`, which applies attributes to this view.
    var editableTextView: NSTextView { textView }

    /// Monospaced while the raw Markdown source is being edited, so the source
    /// reads as code rather than as the rendered document.
    static let sourceFont = TextDefaults.monospacedFont

    private static var sourceAttributes: [NSAttributedString.Key: Any] {
        [.font: sourceFont, .foregroundColor: NSColor.labelColor]
    }

    init(attributedString: NSAttributedString, mode: TextContentMode = .richText, hasExplicitMode: Bool = false) {
        textMode = mode
        hasExplicitTextMode = hasExplicitMode
        sourceText = attributedString.string
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
        apply(canonical: attributedString, mode: mode)
        textView.setReadOnlyMode()
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

    /// The pin's canonical content: the live rich text, or the raw source for
    /// Plain Text and Markdown pins. Never a rendered document.
    var attributedString: NSAttributedString {
        switch textMode {
        case .richText:
            return textView.textStorage.map { NSAttributedString(attributedString: $0) } ?? NSAttributedString()
        case .plainText, .markdown:
            let source = isEditing ? textView.string : sourceText
            return NSAttributedString(string: source,
                                      attributes: ClipboardReader.defaultTextAttributes())
        }
    }

    /// The rendered Markdown document, regardless of editing state. In the
    /// other modes this is simply the canonical text.
    var renderedAttributedString: NSAttributedString {
        textMode == .markdown ? MarkdownRenderer.render(sourceText) : attributedString
    }

    /// What the text stack currently draws (or edits).
    private var displayAttributedString: NSAttributedString {
        switch textMode {
        case .richText, .plainText:
            return attributedString
        case .markdown:
            return isEditing ? NSAttributedString(string: sourceText, attributes: Self.sourceAttributes)
                             : MarkdownRenderer.render(sourceText)
        }
    }

    // MARK: - Modes

    /// Switches between rich text, plain text and Markdown. `explicit` marks a
    /// user choice, which makes the pin stop following the global default.
    ///
    /// Conversions are symmetrical: the characters always survive, formatting
    /// is kept only when the target is rich text, and Markdown renders into
    /// rich text. The pre-switch representation is remembered until the next
    /// edit, so an immediate switch back restores it exactly.
    func setTextMode(_ mode: TextContentMode, explicit: Bool) {
        if explicit { hasExplicitTextMode = true }
        guard mode != textMode else { return }
        if isEditing { endEditing() }

        let previousMode = textMode
        let previous = attributedString
        let next: NSAttributedString
        if let backup = modeBackup, backup.mode == mode {
            next = backup.attributed
            modeBackup = nil
        } else {
            modeBackup = (previousMode, previous)
            next = Self.convert(previous, from: previousMode, to: mode)
        }
        textMode = mode
        apply(canonical: next, mode: mode)
        if !isEditing { textView.setReadOnlyMode() }
        pinController?.refreshChrome()
    }

    /// Canonical representation of `content` after switching from `oldMode` to
    /// `newMode`. Only a rich target converts: Markdown renders into real rich
    /// text; everything else carries the characters and lets the target mode
    /// decide how to display them.
    private static func convert(_ content: NSAttributedString,
                                from oldMode: TextContentMode,
                                to newMode: TextContentMode) -> NSAttributedString {
        switch newMode {
        case .richText:
            return oldMode == .markdown
                ? MarkdownRenderer.render(content.string)
                : NSAttributedString(string: content.string,
                                     attributes: ClipboardReader.defaultTextAttributes())
        case .plainText, .markdown:
            return NSAttributedString(string: content.string,
                                      attributes: ClipboardReader.defaultTextAttributes())
        }
    }

    /// Applies the global default; a pin the user switched individually keeps
    /// its own mode.
    func applyGlobalTextMode(_ mode: TextContentMode) {
        guard !hasExplicitTextMode else { return }
        setTextMode(mode, explicit: false)
    }

    /// Installs a canonical representation for `mode` and shows it.
    private func apply(canonical attributed: NSAttributedString, mode: TextContentMode) {
        textView.isRichText = mode == .richText
        switch mode {
        case .richText:
            textView.textStorage?.setAttributedString(attributed)
            textView.typingAttributes = attributed.length > 0
                ? attributed.attributes(at: attributed.length - 1, effectiveRange: nil)
                : ClipboardReader.defaultTextAttributes()
        case .plainText:
            sourceText = attributed.string
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: sourceText,
                                   attributes: ClipboardReader.defaultTextAttributes())
            )
            textView.typingAttributes = ClipboardReader.defaultTextAttributes()
        case .markdown:
            sourceText = attributed.string
            textView.textStorage?.setAttributedString(MarkdownRenderer.render(sourceText))
            textView.typingAttributes = Self.sourceAttributes
        }
        syncWrapWidth()
    }

    // MARK: - Editing

    func beginEditing(at pointInTextView: NSPoint?) {
        pinController?.requestKeyboardFocus()
        if !isEditing {
            isEditing = true
            if textMode == .markdown {
                // Swap the rendered document for the source the user edits.
                textView.isRichText = false
                textView.typingAttributes = Self.sourceAttributes
                textView.textStorage?.setAttributedString(
                    NSAttributedString(string: sourceText, attributes: Self.sourceAttributes)
                )
            }
            textView.setEditableMode()
            pinController?.rootView.isEditingContent = true
            showFormatToolbar()
        }
        window?.makeFirstResponder(textView)
        if let pointInTextView, textMode != .markdown {
            let index = textView.characterIndexForInsertion(at: pointInTextView)
            textView.setSelectedRange(NSRange(location: index, length: 0))
        }
        formatToolbar?.syncFromSelection()
        textView.needsDisplay = true
        syncWrapWidth()
    }

    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        if textMode == .markdown {
            sourceText = textView.string
            textView.isRichText = false
            textView.textStorage?.setAttributedString(MarkdownRenderer.render(sourceText))
            textView.typingAttributes = Self.sourceAttributes
        }
        textView.setReadOnlyMode()
        pinController?.rootView.isEditingContent = false
        formatToolbar?.hide()
        if window?.firstResponder === textView { window?.makeFirstResponder(nil) }
        textView.needsDisplay = true
        syncWrapWidth()
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
        // Markdown source editing has no rich formatting controls.
        guard textMode == .richText, let window else { return }
        if formatToolbar == nil { formatToolbar = TextFormatToolbar(pin: self) }
        formatToolbar?.show(attachedTo: window)
    }

    // MARK: - HTML images

    /// An attachment that still shows a placeholder because its image has not
    /// been resolved yet.
    private struct DeferredImage {
        let source: String
        let attachment: NSTextAttachment
    }

    /// Fills in the images of attachments imported from pasted HTML.
    ///
    /// `ClipboardReader` tags every `<img>` with `htmlImageSourceAttribute`;
    /// AppKit's importer never resolves the pixels itself. Local sources
    /// (`data:`, `file:`) are read here, remote ones are fetched, and the
    /// result is placed into the existing placeholder attachment.
    func resolveDeferredImages(using loader: RemoteImageFetching = RemoteImageLoader.shared) {
        for image in deferredImages() {
            if let data = HTMLImages.localData(from: image.source) {
                install(data, for: image)
            } else if let url = URL(string: image.source),
                      url.scheme == "http" || url.scheme == "https" {
                loader.fetch(url) { [weak self] data in
                    guard let self, let data else { return }
                    self.install(data, for: image)
                }
            }
        }
    }

    private func deferredImages() -> [DeferredImage] {
        guard let storage = textView.textStorage else { return [] }
        var images: [DeferredImage] = []
        storage.enumerateAttribute(ClipboardReader.htmlImageSourceAttribute,
                                   in: storage.fullRange, options: []) { value, range, _ in
            guard let source = value as? String,
                  let attachment = storage.attribute(.attachment, at: range.location,
                                                     effectiveRange: nil) as? NSTextAttachment else { return }
            images.append(DeferredImage(source: source, attachment: attachment))
        }
        return images
    }

    private func install(_ data: Data, for image: DeferredImage) {
        guard let nsImage = NSImage(data: data), nsImage.isValid,
              let range = currentRange(of: image) else { return }

        // The attachment may be painted any time after the read; setting the
        // image and fitting it to the current wrap width is all that is
        // needed — RTFD (copy-out and history) encodes the attachment from the
        // image, so the placeholder bytes never travel with the pin.
        image.attachment.image = nsImage
        image.attachment.bounds = Self.imageBounds(for: nsImage, fitting: textWrapWidth)
        textView.textStorage?.removeAttribute(ClipboardReader.htmlImageSourceAttribute, range: range)

        textView.layoutManager?.invalidateLayout(forCharacterRange: range,
                                                 actualCharacterRange: nil)
        textView.layoutManager?.invalidateDisplay(forCharacterRange: range)
        syncWrapWidth()
        pinController?.growToFitContent()
        pinController?.contentDidChange()
    }

    /// The attachment's current range — found by identity, because text typed
    /// while the image was loading may have shifted it.
    private func currentRange(of image: DeferredImage) -> NSRange? {
        guard let storage = textView.textStorage else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(ClipboardReader.htmlImageSourceAttribute,
                                   in: storage.fullRange, options: []) { value, range, stop in
            guard (value as? String) == image.source,
                  (storage.attribute(.attachment, at: range.location,
                                     effectiveRange: nil) as? NSTextAttachment) === image.attachment else { return }
            found = range
            stop.pointee = true
        }
        return found
    }

    /// Scales the image to the current wrap width; small images keep their
    /// natural size.
    private static func imageBounds(for image: NSImage, fitting width: CGFloat) -> NSRect {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return .zero }
        let scale = width > 1 ? min(1, width / size.width) : 1
        return NSRect(x: 0, y: 0,
                      width: (size.width * scale).rounded(.down),
                      height: (size.height * scale).rounded(.down))
    }

    // MARK: - NSTextViewDelegate

    func textViewDidChangeSelection(_ notification: Notification) {
        formatToolbar?.syncFromSelection()
    }

    func textDidChange(_ notification: Notification) {
        // Any real edit makes the pre-switch representation stale.
        modeBackup = nil
        if textMode == .richText {
            formatToolbar?.syncFromSelection()
        } else {
            sourceText = textView.string
        }
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
        let measured = TextPinView.measure(displayAttributedString, maxWidth: maxTextWidth)
        let width = min(max(measured.width + padding * 2 + 2, minimumPinSize.width), maxSize.width)
        let height = min(max(measured.height + padding * 2 + 2, minimumPinSize.height), maxSize.height)
        return CGSize(width: ceil(width), height: ceil(height))
    }

    func currentContent() -> PinContent { .text(attributedString) }

    func captureState() -> PinContentState {
        PinContentState(content: currentContent(), textMode: textMode)
    }

    func cursor(at point: NSPoint) -> NSCursor { isEditing ? .iBeam : .openHand }

    /// Rich text writes RTFD/RTF plus a plain text fallback, so formatting
    /// survives the round trip. Plain Text and Markdown pins carry no
    /// formatting, so they copy their source verbatim.
    func copyToPasteboard() {
        copy(to: .general)
    }

    /// Writes to a specific pasteboard; tests use a private one so they never
    /// disturb the user's clipboard.
    func copy(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        switch textMode {
        case .richText:
            pasteboard.writeObjects([attributedString])
        case .plainText, .markdown:
            pasteboard.setString(attributedString.string, forType: .string)
        }
    }

    func chromeItems() -> [ChromeItem] {
        let tooltip: String
        switch (textMode, isEditing) {
        case (.markdown, false): tooltip = "Edit Markdown Source"
        case (_, true): tooltip = "Done Editing"
        case (.richText, false), (.plainText, false): tooltip = "Edit Text"
        }
        return [ChromeItem(symbol: isEditing ? "checkmark" : "pencil",
                           tooltip: tooltip,
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
