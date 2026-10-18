import AppKit

/// Interactive annotation layer stacked on top of an image pin.
///
/// All geometry is kept in image pixel coordinates; the view only applies a
/// scale transform, so annotations follow the window at any size (including
/// non-proportional resizing) and export at full resolution.
final class AnnotationCanvasView: NSView {
    weak var imagePin: ImagePinView?
    let store: AnnotationStore
    let imageSize: CGSize
    var effects: ImageEffects?

    var tool: AnnotationTool = .rectangle {
        didSet {
            if tool != .select { selectedID = nil }
            if tool != .crop { cropDraft = nil }
            needsDisplay = true
        }
    }

    var style: AnnotationStyle = .current() {
        didSet { applyStyleToSelection() }
    }

    var isActive = false {
        didSet {
            if !isActive {
                selectedID = nil
                cropDraft = nil
                commitTextEditor()
            }
            needsDisplay = true
        }
    }

    private(set) var selectedID: UUID? {
        didSet { onSelectionChange?() }
    }
    /// Lets the toolbar react to selection changes (e.g. to show text style
    /// controls when a text annotation is picked).
    var onSelectionChange: (() -> Void)?
    private var draft: Annotation?
    private var suppressedID: UUID?
    private var cropDraft: CGRect?
    private var textEditor: NSTextField?
    private var editingAnnotation: Annotation?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { isActive }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(store: AnnotationStore, imageSize: CGSize, effects: ImageEffects?) {
        self.store = store
        self.imageSize = imageSize
        self.effects = effects
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Inactive canvases are transparent to the mouse so the pin keeps its
    /// normal drag/resize behaviour.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isActive ? super.hitTest(point) : nil
    }

    // MARK: - Coordinate mapping

    var sourceRect: CGRect { store.cropRect ?? CGRect(origin: .zero, size: imageSize) }
    private var scaleX: CGFloat { bounds.width > 0 ? bounds.width / sourceRect.width : 1 }
    private var scaleY: CGFloat { bounds.height > 0 ? bounds.height / sourceRect.height : 1 }

    func imagePoint(from viewPoint: NSPoint) -> CGPoint {
        CGPoint(x: sourceRect.minX + viewPoint.x / scaleX, y: sourceRect.minY + viewPoint.y / scaleY)
    }

    func viewPoint(from imagePoint: CGPoint) -> NSPoint {
        NSPoint(x: (imagePoint.x - sourceRect.minX) * scaleX, y: (imagePoint.y - sourceRect.minY) * scaleY)
    }

    func viewRect(from imageRect: CGRect) -> NSRect {
        NSRect(
            x: (imageRect.minX - sourceRect.minX) * scaleX,
            y: (imageRect.minY - sourceRect.minY) * scaleY,
            width: imageRect.width * scaleX,
            height: imageRect.height * scaleY
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.cgContext.scaleBy(x: scaleX, y: scaleY)
        context.cgContext.translateBy(x: -sourceRect.minX, y: -sourceRect.minY)
        let visible = store.annotations.filter { $0.id != suppressedID }
        AnnotationRenderer.draw(visible, imageSize: imageSize, effects: effects, in: context)
        if let draft {
            context.saveGraphicsState()
            AnnotationRenderer.draw(draft, imageSize: imageSize, effects: effects, in: context)
            context.restoreGraphicsState()
        }
        context.restoreGraphicsState()

        guard isActive else { return }
        drawSelection()
        drawCropOverlay()
    }

    private func drawSelection() {
        guard let selectedID, let annotation = store.annotation(with: selectedID) else { return }
        let box = viewRect(from: annotation.boundingBox(textSizer: AnnotationRenderer.textSize)).insetBy(dx: -3, dy: -3)
        let path = NSBezierPath(rect: box)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
        NSColor.controlAccentColor.setFill()
        for corner in [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)] {
            NSBezierPath(ovalIn: CGRect(x: corner.x - 3, y: corner.y - 3, width: 6, height: 6)).fill()
        }
    }

    private func drawCropOverlay() {
        guard tool == .crop else { return }
        let selection = cropDraft.map { viewRect(from: $0) } ?? bounds
        NSColor.black.withAlphaComponent(0.45).setFill()
        let overlay = NSBezierPath(rect: bounds)
        overlay.append(NSBezierPath(rect: selection))
        overlay.windingRule = .evenOdd
        overlay.fill()

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection)
        border.lineWidth = 1
        border.stroke()

        if cropDraft != nil {
            let hint = NSAttributedString(string: "Return to crop · Esc to cancel", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white
            ])
            hint.draw(at: NSPoint(x: selection.minX + 6, y: max(selection.minY - 18, 4)))
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard isActive, let window else { return }
        commitTextEditor()
        window.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        switch tool {
        case .select:
            if let hit = topmostAnnotation(at: imagePoint(from: point)) {
                selectedID = hit.id
                needsDisplay = true
                if event.clickCount >= 2, hit.tool == .text {
                    beginTextEditing(for: hit)
                } else {
                    runMoveLoop(for: hit, from: point)
                }
            } else {
                selectedID = nil
                needsDisplay = true
                WindowInteraction.move(window: window, dragCursor: .closedHand, endCursor: .openHand)
            }
        case .crop:
            runCropLoop(from: point)
        case .text:
            beginTextEditing(at: imagePoint(from: point))
        default:
            runDrawingLoop(from: point)
        }
    }

    private func topmostAnnotation(at point: CGPoint) -> Annotation? {
        store.annotations.reversed().first { $0.hitTest(point, textSizer: AnnotationRenderer.textSize) }
    }

    private func runDrawingLoop(from startView: NSPoint) {
        guard let window else { return }
        let start = imagePoint(from: startView)
        var annotation = Annotation(tool: tool, points: [start], style: style)
        NSCursor.crosshair.set()

        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let current = imagePoint(from: convert(event.locationInWindow, from: nil))
            if tool == .freehand {
                annotation.points.append(current)
            } else {
                annotation.points = [start, current]
            }
            draft = annotation
            needsDisplay = true
            if event.type == .leftMouseUp { break }
        }

        draft = nil
        if isMeaningful(annotation) {
            store.add(annotation)
            selectedID = annotation.id
        }
        needsDisplay = true
    }

    private func isMeaningful(_ annotation: Annotation) -> Bool {
        switch annotation.tool {
        case .freehand:
            return annotation.points.count >= 2
        case .line, .arrow:
            guard annotation.points.count >= 2 else { return false }
            return hypot(annotation.points[1].x - annotation.points[0].x,
                         annotation.points[1].y - annotation.points[0].y) > 4
        default:
            let rect = annotation.rect
            return rect.width > 3 && rect.height > 3
        }
    }

    private func runMoveLoop(for annotation: Annotation, from startView: NSPoint) {
        guard let window else { return }
        let start = imagePoint(from: startView)
        var moved = annotation
        suppressedID = annotation.id
        NSCursor.closedHand.set()

        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let current = imagePoint(from: convert(event.locationInWindow, from: nil))
            var candidate = annotation
            candidate.translate(by: CGVector(dx: current.x - start.x, dy: current.y - start.y))
            moved = candidate
            draft = candidate
            needsDisplay = true
            if event.type == .leftMouseUp { break }
        }

        suppressedID = nil
        draft = nil
        if moved != annotation { store.update(moved) }
        NSCursor.openHand.set()
        needsDisplay = true
    }

    private func runCropLoop(from startView: NSPoint) {
        guard let window else { return }
        let start = imagePoint(from: startView)
        NSCursor.crosshair.set()

        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let current = imagePoint(from: convert(event.locationInWindow, from: nil))
            let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                              width: abs(current.x - start.x), height: abs(current.y - start.y))
            cropDraft = rect.intersection(sourceRect)
            needsDisplay = true
            if event.type == .leftMouseUp { break }
        }

        if let cropDraft, cropDraft.width < 8 || cropDraft.height < 8 {
            self.cropDraft = nil
        }
        needsDisplay = true
    }

    func confirmCrop() {
        guard let rect = cropDraft, rect.width > 8, rect.height > 8 else { return }
        let previousScale = (x: scaleX, y: scaleY)
        cropDraft = nil
        store.setCrop(rect)
        imagePin?.applyCrop(displayScale: previousScale)
        tool = .select
        imagePin?.annotationToolbar?.syncSelection()
    }

    func cancelCrop() {
        cropDraft = nil
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // return / enter
            if tool == .crop { confirmCrop() } else { super.keyDown(with: event) }
        case 51, 117: // delete / forward delete
            deleteSelection()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if cropDraft != nil {
            cancelCrop()
        } else if selectedID != nil {
            selectedID = nil
            needsDisplay = true
        } else {
            imagePin?.endEditing()
        }
    }

    func deleteSelection() {
        guard let selectedID else { return }
        store.remove(id: selectedID)
        self.selectedID = nil
        needsDisplay = true
    }

    private func applyStyleToSelection() {
        guard let selectedID, var annotation = store.annotation(with: selectedID) else { return }
        annotation.style = style
        store.update(annotation)
    }

    var selectedAnnotation: Annotation? {
        selectedID.flatMap { store.annotation(with: $0) }
    }

    /// Programmatic selection (the toolbar and tests use this; nil clears).
    func selectAnnotation(id: UUID?) {
        selectedID = id
        needsDisplay = true
    }

    /// Style edit scoped correctly: with a selection it changes only that
    /// annotation (undoable via the store); without one it becomes the style
    /// new annotations get on this pin. Never touches a global default.
    func updateSelectedStyle(_ mutate: (inout AnnotationStyle) -> Void) {
        if let selectedID, var annotation = store.annotation(with: selectedID) {
            mutate(&annotation.style)
            store.update(annotation)
        } else {
            mutate(&style)
        }
    }

    // MARK: - Text annotations

    /// A read-only snapshot for previews, including the field's unsaved text.
    /// Never commits the editor or adds an undo step just to open a menu.
    var previewAnnotations: [Annotation] {
        var annotations = store.annotations
        if var annotation = editingAnnotation, let textEditor {
            annotation.text = textEditor.stringValue
            if let index = annotations.firstIndex(where: { $0.id == annotation.id }) {
                annotations[index] = annotation
            } else {
                annotations.append(annotation)
            }
        }
        return annotations
    }

    private func beginTextEditing(at imageOrigin: CGPoint) {
        let annotation = Annotation(tool: .text, points: [imageOrigin], style: style, text: "")
        presentTextEditor(for: annotation, isNew: true)
    }

    private func beginTextEditing(for annotation: Annotation) {
        suppressedID = annotation.id
        needsDisplay = true
        presentTextEditor(for: annotation, isNew: false)
    }

    private func presentTextEditor(for annotation: Annotation, isNew: Bool) {
        commitTextEditor()
        editingAnnotation = annotation
        let origin = viewPoint(from: annotation.points.first ?? .zero)
        let fontSize = max(annotation.style.fontSize * scaleY, 6)

        let field = NSTextField(frame: NSRect(x: origin.x - 4, y: origin.y - fontSize * 1.5, width: 160, height: fontSize * 1.5))
        field.stringValue = annotation.text ?? ""
        field.font = annotation.style.font(pointSize: fontSize)
        field.textColor = annotation.style.color
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85)
        field.focusRingType = .none
        field.target = self
        field.action = #selector(textEditorCommitted)
        addSubview(field)
        textEditor = field
        imagePin?.pinController?.requestKeyboardFocus()
        window?.makeFirstResponder(field)
        if !isNew { selectedID = annotation.id }
    }

    @objc private func textEditorCommitted() {
        commitTextEditor()
    }

    func commitTextEditor() {
        guard let textEditor, var annotation = editingAnnotation else { return }
        let value = textEditor.stringValue
        textEditor.removeFromSuperview()
        self.textEditor = nil
        editingAnnotation = nil
        suppressedID = nil

        let existed = store.annotation(with: annotation.id) != nil
        annotation.text = value
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if existed { store.remove(id: annotation.id) }
        } else if existed {
            store.update(annotation)
        } else {
            store.add(annotation)
            selectedID = annotation.id
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - Cursor

    func cursor(at point: NSPoint) -> NSCursor {
        guard isActive else { return .openHand }
        switch tool {
        case .select:
            return topmostAnnotation(at: imagePoint(from: point)) != nil ? .openHand : .arrow
        case .text:
            return .iBeam
        default:
            return .crosshair
        }
    }
}
