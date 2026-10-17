import AppKit
import UniformTypeIdentifiers

/// Image pin: displays the original bitmap and hosts the annotation canvas.
///
/// Editing is non-destructive — the window only scales the presentation layer
/// and annotations live in a separate store, so the source pixels are never
/// resampled or re-encoded until the pin is copied or saved.
final class ImagePinView: NSView, PinContentDisplaying {
    weak var pinController: PinWindowController?

    private(set) var baseImage: NSImage
    private var baseCGImage: CGImage?
    let annotationStore = AnnotationStore()
    private let effects: ImageEffects?
    private let canvas: AnnotationCanvasView
    private(set) var annotationToolbar: AnnotationToolbar?
    private(set) var isAnnotating = false

    var minimumPinSize: CGSize { CGSize(width: 60, height: 40) }
    var contentAspectRatio: CGSize? { sourceRect.size }
    var pinUndoManager: UndoManager? { isAnnotating ? annotationStore.undoManager : nil }

    private var pixelSize: CGSize { baseImage.pixelSize }
    private var sourceRect: CGRect { annotationStore.cropRect ?? CGRect(origin: .zero, size: pixelSize) }

    init(image: NSImage, annotationData: Data? = nil) {
        baseImage = image
        baseCGImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        effects = baseCGImage.map(ImageEffects.init(base:))
        canvas = AnnotationCanvasView(store: annotationStore, imageSize: image.pixelSize, effects: effects)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true
        layer?.contents = baseCGImage
        // Fills whatever size the user drags out; the backing pixels are never
        // touched, only how the layer presents them.
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .trilinear
        layer?.minificationFilter = .trilinear

        canvas.imagePin = self
        canvas.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.topAnchor.constraint(equalTo: topAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        annotationStore.onChange = { [weak self] in
            self?.refreshAfterStoreChange()
            self?.pinController?.contentDidChange()
        }
        if let annotationData { restoreAnnotations(annotationData) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowGeometryChanged),
            name: NSWindow.didResizeNotification, object: window
        )
    }

    @objc private func windowGeometryChanged() {
        annotationToolbar?.reposition()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            beginAnnotating()
            return
        }
        WindowInteraction.move(window: window, dragCursor: .closedHand, endCursor: .openHand)
    }

    override func magnify(with event: NSEvent) {
        pinController?.zoom(by: 1 + event.magnification)
    }

    // MARK: - Annotation mode

    func beginAnnotating() {
        guard !isAnnotating else { return }
        isAnnotating = true
        canvas.isActive = true
        canvas.style = .current()
        if annotationToolbar == nil {
            annotationToolbar = AnnotationToolbar(canvas: canvas, pin: self)
        }
        pinController?.requestKeyboardFocus()
        if let window {
            annotationToolbar?.show(attachedTo: window)
            window.makeFirstResponder(canvas)
        }
        pinController?.refreshChrome()
    }

    func endEditing() {
        guard isAnnotating else { return }
        canvas.commitTextEditor()
        isAnnotating = false
        canvas.isActive = false
        annotationToolbar?.hide()
        pinController?.refreshChrome()
    }

    /// Annotation mode survives losing key focus to the colour panel or a save
    /// sheet, but not another pin or another app taking over.
    func handleResignKey() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isAnnotating else { return }
            guard NSApp.isActive else { return self.endEditing() }
            if let key = NSApp.keyWindow, key is PinPanel, key !== self.window { self.endEditing() }
        }
    }

    func refreshAfterStoreChange() {
        updateContentsRect()
        canvas.needsDisplay = true
        annotationToolbar?.syncSelection()
    }

    /// Restores annotations from a history record so re-pinned images stay editable.
    func restoreAnnotations(_ data: Data) {
        annotationStore.restore(from: data)
    }

    private func updateContentsRect() {
        guard let layer, pixelSize.width > 0, pixelSize.height > 0 else { return }
        let source = sourceRect
        layer.contentsRect = CGRect(
            x: source.minX / pixelSize.width,
            y: (pixelSize.height - source.maxY) / pixelSize.height,
            width: source.width / pixelSize.width,
            height: source.height / pixelSize.height
        )
    }

    /// Called after a crop is confirmed: keeps the cropped region at the same
    /// on-screen scale it had before, anchored at the window's top-left.
    func applyCrop(displayScale: (x: CGFloat, y: CGFloat)) {
        updateContentsRect()
        guard let window else { return }
        let source = sourceRect
        let size = CGSize(
            width: max(source.width * displayScale.x, minimumPinSize.width),
            height: max(source.height * displayScale.y, minimumPinSize.height)
        )
        var frame = window.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true)
        window.invalidateShadow()
    }

    // MARK: - PinContentDisplaying

    func idealSize(fitting maxSize: CGSize) -> CGSize {
        var size = naturalPointSize
        let scale = min(maxSize.width / size.width, maxSize.height / size.height, 1)
        size = CGSize(width: size.width * scale, height: size.height * scale)
        if size.width < minimumPinSize.width || size.height < minimumPinSize.height {
            let up = max(minimumPinSize.width / size.width, minimumPinSize.height / size.height)
            size = CGSize(width: size.width * up, height: size.height * up)
        }
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
    }

    /// Point size the image should occupy on screen.
    ///
    /// Bitmaps coming from the pasteboard usually carry no DPI hint, so their
    /// point size equals their pixel size. On a Retina display that would show
    /// a screenshot at twice its captured size, hence the backing-scale divide.
    /// Images that do declare a resolution are trusted as-is.
    var naturalPointSize: CGSize {
        let pixels = sourceRect.size
        let declared = baseImage.size
        if annotationStore.cropRect == nil, declared.width > 1, abs(declared.width - pixels.width) > 1 { return declared }
        let scale = (window?.screen ?? NSScreen.underMouse)?.backingScaleFactor ?? 2
        return CGSize(width: pixels.width / scale, height: pixels.height / scale)
    }

    func currentContent() -> PinContent { .image(renderedImage()) }

    func captureState() -> PinContentState {
        PinContentState(content: .image(baseImage),
                        annotationData: annotationStore.isEmpty ? nil : annotationStore.encoded())
    }

    func cursor(at point: NSPoint) -> NSCursor {
        isAnnotating ? canvas.cursor(at: convert(point, from: superview)) : .openHand
    }

    func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([renderedImage()])
    }

    func chromeItems() -> [ChromeItem] {
        [ChromeItem(symbol: isAnnotating ? "checkmark" : "pencil.tip.crop.circle",
                    tooltip: isAnnotating ? "Done Editing" : "Annotate Image",
                    action: { [weak self] in
                        guard let self else { return }
                        self.isAnnotating ? self.endEditing() : self.beginAnnotating()
                    },
                    isToggled: isAnnotating),
         ChromeItem(symbol: "square.and.arrow.down", tooltip: "Save as PNG") { [weak self] in
             self?.saveToFile()
         }]
    }

    func contextMenuItems() -> [NSMenuItem] {
        [menuItem(isAnnotating ? "Done Editing" : "Annotate Image…") { [weak self] in
            guard let self else { return }
            self.isAnnotating ? self.endEditing() : self.beginAnnotating()
         },
         menuItem("Default Size") { [weak self] in self?.resize(to: self?.naturalPointSize) },
         menuItem("Actual Pixel Size") { [weak self] in self?.resize(to: self?.sourceRect.size) },
         menuItem("Restore Original Image") { [weak self] in
            self?.annotationStore.reset()
            self?.refreshAfterStoreChange()
         },
         menuItem("Save as PNG…") { [weak self] in self?.saveToFile() }]
    }

    private func menuItem(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.run(_:)), keyEquivalent: "")
        let target = MenuActionTarget(handler: handler)
        item.target = target
        item.representedObject = target
        return item
    }

    private func resize(to size: CGSize?) {
        guard let size, let window else { return }
        var frame = window.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true)
        window.invalidateShadow()
    }

    // MARK: - Export

    /// Flattens crop + annotations onto the original pixels.
    func renderedImage() -> NSImage {
        guard let baseCGImage else { return baseImage }
        let source = sourceRect
        guard source.width >= 1, source.height >= 1 else { return baseImage }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(source.width.rounded()),
            pixelsHigh: Int(source.height.rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return baseImage }
        rep.size = source.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: -source.minX, y: -source.minY)
        context.cgContext.draw(baseCGImage, in: CGRect(origin: .zero, size: pixelSize))
        AnnotationRenderer.draw(annotationStore.annotations, imageSize: pixelSize, effects: effects, in: context)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: source.size)
        image.addRepresentation(rep)
        return image
    }

    func saveToFile() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Pinboard-\(formatter.string(from: Date())).png"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let data = self?.renderedImage().pngData() else { return }
            try? data.write(to: url)
        }
    }
}
