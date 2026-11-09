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

    var previewTitle: String {
        "\(annotationStore.isEmpty ? "Image" : "Annotated Image") · \(Int(sourceRect.width)) × \(Int(sourceRect.height))"
    }

    func menuPreview(fitting maxSize: CGSize) -> NSImage? {
        let source = sourceRect
        guard let baseCGImage, source.width > 0, source.height > 0 else { return nil }
        let scale = min(maxSize.width / source.width, maxSize.height / source.height, 1)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return PinMenuPreview.image(size: size) { context, rect in
            NSColor.textBackgroundColor.setFill()
            rect.fill()
            context.cgContext.scaleBy(x: scale, y: scale)
            context.cgContext.translateBy(x: -source.minX, y: -source.minY)
            context.cgContext.draw(baseCGImage, in: CGRect(origin: .zero, size: pixelSize))
            AnnotationRenderer.draw(canvas.previewAnnotations, imageSize: pixelSize, effects: effects, in: context)
        }
    }
    var contentAspectRatio: CGSize? { sourceRect.size }
    var pinUndoManager: UndoManager? { isAnnotating ? annotationStore.undoManager : nil }

    /// Tracks how the pin window's geometry corresponds to the uncropped/cropped
    /// source region so undoing a crop restores the exact pre-crop window size.
    enum CropGeometryState: Equatable {
        case uncropped(sourceSize: CGSize)
        case cropped(sourceSize: CGSize, uncroppedWindowSize: CGSize, croppedWindowSize: CGSize)

        var sourceSize: CGSize {
            switch self {
            case .uncropped(let size), .cropped(let size, _, _): return size
            }
        }

        var uncroppedWindowSize: CGSize? {
            if case .cropped(_, let uncropped, _) = self { return uncropped }
            return nil
        }
    }

    private var pixelSize: CGSize { baseImage.pixelSize }
    private var sourceRect: CGRect { annotationStore.cropRect ?? CGRect(origin: .zero, size: pixelSize) }
    private(set) var cropGeometryState: CropGeometryState

    init(image: NSImage, annotations: AnnotationStore.Payload? = nil) {
        baseImage = image
        cropGeometryState = .uncropped(sourceSize: image.pixelSize)
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
        if let annotations { annotationStore.restore(annotations) }
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
            pinController?.copyAndClose()
            return
        }
        WindowInteraction.move(window: window, dragCursor: .closedHand, endCursor: .openHand)
    }

    override func magnify(with event: NSEvent) {
        pinController?.handleMagnify(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        pinController?.handleScrollWheel(with: event)
    }

    // MARK: - Annotation mode

    func beginAnnotating() {
        guard !isAnnotating else { return }
        isAnnotating = true
        pinController?.rootView.isEditingContent = true
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
        pinController?.rootView.isEditingContent = false
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
        let previousSize = cropGeometryState.sourceSize
        let currentSourceSize = sourceRect.size
        canvas.reconcileSelection()
        updateContentsRect()
        if previousSize != currentSourceSize,
           previousSize.width > 0, previousSize.height > 0,
           let window {
            if annotationStore.cropRect == nil,
               case .cropped(_, let uncropped, let cropped) = cropGeometryState,
               window.frame.size == cropped {
                cropGeometryState = .uncropped(sourceSize: currentSourceSize)
                resize(to: uncropped)
            } else {
                let beforeCrop = previousSize == pixelSize ? window.frame.size : cropGeometryState.uncroppedWindowSize
                let scaleX = window.frame.width / previousSize.width
                let scaleY = window.frame.height / previousSize.height
                applyCrop(displayScale: (x: scaleX, y: scaleY))
                if let beforeCrop, annotationStore.cropRect != nil {
                    cropGeometryState = .cropped(
                        sourceSize: currentSourceSize,
                        uncroppedWindowSize: beforeCrop,
                        croppedWindowSize: window.frame.size
                    )
                } else {
                    cropGeometryState = .uncropped(sourceSize: currentSourceSize)
                }
            }
        } else {
            switch cropGeometryState {
            case .uncropped:
                cropGeometryState = .uncropped(sourceSize: currentSourceSize)
            case .cropped(_, let uncropped, let cropped):
                cropGeometryState = annotationStore.cropRect == nil
                    ? .uncropped(sourceSize: currentSourceSize)
                    : .cropped(sourceSize: currentSourceSize, uncroppedWindowSize: uncropped, croppedWindowSize: cropped)
            }
        }
        canvas.needsDisplay = true
        annotationToolbar?.syncSelection()
    }

    func restoreOriginalImage() {
        canvas.commitTextEditor()
        canvas.cancelCrop()
        annotationStore.reset()
        refreshAfterStoreChange()
    }

    /// Restores annotations from a history record so re-pinned images stay editable.
    func restoreAnnotations(_ data: Data) throws {
        annotationStore.restore(try AnnotationStore.decode(data))
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
        let source = sourceRect
        let size = CGSize(
            width: max((source.width * displayScale.x).rounded(), minimumPinSize.width),
            height: max((source.height * displayScale.y).rounded(), minimumPinSize.height)
        )
        resize(to: size)
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

    @discardableResult
    func copy(to pasteboard: NSPasteboard) -> Bool {
        let image = renderedImage()
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }

    func editChromeItem() -> ChromeItem? {
        ChromeItem(symbol: isAnnotating ? "checkmark" : "pencil",
                   tooltip: isAnnotating ? "Done Editing" : "Annotate Image",
                   action: { [weak self] in
                       guard let self else { return }
                       self.isAnnotating ? self.endEditing() : self.beginAnnotating()
                   },
                   isToggled: isAnnotating)
    }

    func saveChromeItem() -> ChromeItem? {
        ChromeItem(symbol: "square.and.arrow.down", tooltip: "Save as PNG") { [weak self] in
            self?.saveToFile()
        }
    }

    func chromeItems() -> [ChromeItem] { [] }

    func contextMenuItems() -> [NSMenuItem] {
        let canRestore = !annotationStore.isEmpty || canvas.hasUncommittedDraft
        return [
            .pinAction(
                isAnnotating ? "Done Editing" : "Annotate Image",
                symbol: isAnnotating ? "checkmark.circle" : "pencil"
            ) { [weak self] in
                guard let self else { return }
                self.isAnnotating ? self.endEditing() : self.beginAnnotating()
            },
            .pinAction(
                "Restore Original Image",
                symbol: "arrow.counterclockwise",
                isEnabled: canRestore
            ) { [weak self] in
                self?.restoreOriginalImage()
            }
        ]
    }

    func saveContextMenuItem() -> NSMenuItem? {
        .pinAction("Save as PNG…", symbol: "square.and.arrow.down") { [weak self] in
            self?.saveToFile()
        }
    }

    func viewContextMenuItems() -> [NSMenuItem] {
        [
            .pinAction("Default Size", symbol: "1.magnifyingglass") { [weak self] in
                self?.resize(to: self?.naturalPointSize)
            },
            .pinAction("Actual Pixel Size", symbol: "arrow.up.left.and.down.right.magnifyingglass") { [weak self] in
                self?.resize(to: self?.sourceRect.size)
            }
        ]
    }

    private func resize(to size: CGSize?) {
        guard let size, let window else { return }
        var frame = window.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true)
        window.invalidateShadow()
        pinController?.syncBaseSizeToCurrentFrame()
    }

    // MARK: - Export

    /// Flattens crop + annotations onto the original pixels.
    func renderedImage() -> NSImage {
        canvas.commitTextEditor()
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
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                guard let data = self.renderedImage().pngData() else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}
