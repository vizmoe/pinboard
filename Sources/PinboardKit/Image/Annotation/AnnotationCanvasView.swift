import AppKit

/// Interactive annotation layer stacked on top of an image pin.
///
/// All geometry is kept in image pixel coordinates; the view only applies a
/// scale transform, so annotations follow the window at any size (including
/// non-proportional resizing) and export at full resolution.
final class AnnotationCanvasView: NSView, NSTextFieldDelegate {
    weak var imagePin: ImagePinView?
    let store: AnnotationStore
    let imageSize: CGSize
    var effects: ImageEffects?

    /// Mutually-exclusive interactive edit session on the annotation canvas.
    /// Bundling the live preview/editor state into a single sum type makes
    /// overlapping states (e.g. a dangling `suppressedID`, an orphaned
    /// `NSTextField` without an `editingAnnotation`, or a crop marquee
    /// coexisting with shape dragging) unrepresentable.
    enum EditSession {
        case idle
        /// Live preview while drawing a new shape (`replacingID == nil`) or
        /// moving/resizing a committed shape (`replacingID == annotation.id`).
        case draggingShape(draft: Annotation, replacingID: UUID?)
        /// Live on-canvas text field editing a new (`isExisting == false`) or
        /// committed (`isExisting == true`) text annotation.
        case editingText(field: NSTextField, annotation: Annotation, isExisting: Bool)
        /// Unconfirmed crop marquee in image pixel coordinates.
        case cropping(rect: CGRect)
    }

    var tool: AnnotationTool = .select {
        willSet { if newValue != tool { commitTextEditor() } }
        didSet {
            if tool != .select, selectedAnnotation?.tool != tool { selectedID = nil }
            if tool != .crop, case .cropping = editSession { editSession = .idle }
            needsDisplay = true
            onSelectionChange?()
        }
    }

    var style: AnnotationStyle = .current() {
        didSet { applyStyleToSelection() }
    }

    var isActive = false {
        didSet {
            if !isActive {
                selectedID = nil
                commitTextEditor()
                editSession = .idle
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
    private(set) var editSession: EditSession = .idle

    private var draft: Annotation? {
        if case .draggingShape(let draft, _) = editSession { return draft }
        return nil
    }

    private var suppressedID: UUID? {
        switch editSession {
        case .draggingShape(_, let replacingID):
            return replacingID
        case .editingText(_, let annotation, isExisting: true):
            return annotation.id
        case .idle, .editingText(_, _, isExisting: false), .cropping:
            return nil
        }
    }

    var cropDraft: CGRect? {
        get {
            if case .cropping(let rect) = editSession { return rect }
            return nil
        }
        set {
            if let rect = newValue {
                commitTextEditor()
                editSession = .cropping(rect: rect)
            } else if case .cropping = editSession {
                editSession = .idle
            }
        }
    }

    private var textEditor: NSTextField? {
        if case .editingText(let field, _, _) = editSession { return field }
        return nil
    }

    private var editingAnnotation: Annotation? {
        if case .editingText(_, let annotation, _) = editSession { return annotation }
        return nil
    }

    var hasUncommittedDraft: Bool {
        switch editSession {
        case .idle: return false
        case .draggingShape, .editingText, .cropping: return true
        }
    }

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
        var visible = store.annotations.filter { $0.id != suppressedID }
        if let draft { visible.append(draft) }
        AnnotationRenderer.draw(visible, imageSize: imageSize, effects: effects, in: context)
        context.restoreGraphicsState()

        guard isActive else { return }
        drawSelection()
        drawCropOverlay()
    }

    private func drawSelection() {
        guard let selectedID,
              let annotation = draft?.id == selectedID ? draft : store.annotation(with: selectedID) else { return }
        let box = viewRect(from: annotation.boundingBox(textSizer: AnnotationRenderer.textSize)).insetBy(dx: -3, dy: -3)
        let path = NSBezierPath(rect: box)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
        NSColor.controlAccentColor.setFill()
        for point in selectionHandles(for: annotation).map({ viewPoint(from: $0) }) {
            NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
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
        let committedActiveText = textEditor?.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        commitTextEditor()
        window.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        if let selected = selectedAnnotation, let handle = handleIndex(at: point, for: selected) {
            runResizeLoop(for: selected, handle: handle)
            return
        }
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
            if let hit = topmostAnnotation(at: imagePoint(from: point)), hit.tool == .text {
                selectedID = hit.id
                needsDisplay = true
                if event.clickCount >= 2 {
                    beginTextEditing(for: hit)
                } else {
                    runMoveLoop(for: hit, from: point)
                }
            } else if !committedActiveText {
                beginTextEditing(at: imagePoint(from: point))
            }
        case .counter:
            if let hit = topmostAnnotation(at: imagePoint(from: point)), hit.tool == .counter {
                selectedID = hit.id
                needsDisplay = true
                runMoveLoop(for: hit, from: point)
            } else {
                addCounter(at: imagePoint(from: point))
            }
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
        WindowInteraction.applyCursor(.crosshair)

        let isFreehandPath = tool == .freehand || (tool == .highlight && style.highlightMode == .freehand)
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            var current = imagePoint(from: convert(event.locationInWindow, from: nil))
            if event.modifierFlags.contains(.shift) { current = tool.constrainedEndpoint(from: start, to: current) }
            if isFreehandPath {
                annotation.points.append(current)
            } else {
                annotation.points = [start, current]
            }
            editSession = .draggingShape(draft: annotation, replacingID: nil)
            needsDisplay = true
            if event.type == .leftMouseUp { break }
        }

        editSession = .idle
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
        case .highlight where annotation.effectiveHighlightMode == .freehand:
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
        editSession = .draggingShape(draft: annotation, replacingID: annotation.id)
        WindowInteraction.applyCursor(.closedHand)

        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let current = imagePoint(from: convert(event.locationInWindow, from: nil))
            var candidate = annotation
            candidate.translate(by: CGVector(dx: current.x - start.x, dy: current.y - start.y))
            moved = candidate
            editSession = .draggingShape(draft: candidate, replacingID: annotation.id)
            needsDisplay = true
            if event.type == .leftMouseUp { break }
        }

        editSession = .idle
        if moved != annotation { store.update(moved) }
        WindowInteraction.applyCursor(.openHand)
        needsDisplay = true
    }

    /// Handles are hit-tested in view points so they remain usable at every zoom.
    private func selectionHandles(for annotation: Annotation) -> [CGPoint] {
        switch annotation.tool {
        case .line:
            return Array(annotation.points.prefix(2))
        case .arrow:
            guard annotation.points.count >= 2 else { return [] }
            let start = annotation.points[0]
            let end = annotation.points[1]
            let mid = annotation.points.count >= 3
                ? annotation.points[2]
                : CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            return [start, end, mid]
        case .highlight where annotation.effectiveHighlightMode == .freehand:
            return []
        case .rectangle, .ellipse, .highlight, .blur, .mosaic, .spotlight:
            let rect = annotation.rect
            return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        default: return []
        }
    }

    private func handleIndex(at point: CGPoint, for annotation: Annotation) -> Int? {
        selectionHandles(for: annotation).firstIndex {
            let handle = viewPoint(from: $0)
            return hypot(handle.x - point.x, handle.y - point.y) <= 7
        }
    }

    private func runResizeLoop(for annotation: Annotation, handle: Int) {
        guard let window else { return }
        let handles = selectionHandles(for: annotation)
        let isLine = annotation.tool == .line || annotation.tool == .arrow
        let isCurveHandle = annotation.tool == .arrow && handle == 2
        let fixed = isCurveHandle
            ? handles[0]
            : handles[isLine ? 1 - handle : (handle + 2) % 4]
        var resized = annotation
        editSession = .draggingShape(draft: annotation, replacingID: annotation.id)
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { break }
            var point = imagePoint(from: convert(event.locationInWindow, from: nil))
            if event.modifierFlags.contains(.shift), !isCurveHandle {
                point = annotation.tool.constrainedEndpoint(from: fixed, to: point)
            }
            if isCurveHandle {
                resized.points = [annotation.points[0], annotation.points[1], point]
            } else if isLine {
                resized.points[handle] = point
            } else {
                resized.points = [fixed, point]
            }
            editSession = .draggingShape(draft: resized, replacingID: annotation.id)
            needsDisplay = true
        }
        editSession = .idle
        if resized != annotation, isMeaningful(resized) { store.update(resized, actionName: "Resize Annotation") }
        needsDisplay = true
    }

    func addCounter(at point: CGPoint) {
        let next = (store.annotations.filter { $0.tool == .counter }.compactMap { Int($0.text ?? "") }.max() ?? 0) + 1
        let annotation = Annotation(tool: .counter, points: [point], style: style, text: String(next))
        store.add(annotation)
        selectedID = annotation.id
        needsDisplay = true
    }

    func duplicateSelection() {
        commitTextEditor()
        guard var copy = selectedAnnotation else { return }
        copy.id = UUID()
        copy.translate(by: CGVector(dx: 10 / scaleX, dy: -10 / scaleY))
        store.add(copy)
        selectedID = copy.id
        needsDisplay = true
    }

    func moveSelection(by offset: CGVector) {
        guard var annotation = selectedAnnotation else { return }
        annotation.translate(by: CGVector(dx: offset.dx / scaleX, dy: offset.dy / scaleY))
        store.update(annotation)
        needsDisplay = true
    }

    func reconcileSelection() {
        if let selectedID, store.annotation(with: selectedID) == nil { self.selectedID = nil }
    }

    private func runCropLoop(from startView: NSPoint) {
        guard let window else { return }
        let start = imagePoint(from: startView)
        WindowInteraction.applyCursor(.crosshair)

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
        cropDraft = nil
        store.setCrop(rect)
        tool = .select
        imagePin?.annotationToolbar?.syncSelection()
    }

    func cancelCrop() {
        cropDraft = nil
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased()
        if event.modifierFlags.contains(.command), key == "d" {
            duplicateSelection()
            return
        }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let tool = AnnotationTool.allCases.first(where: { $0.shortcut == key }) {
            self.tool = tool
            return
        }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: moveSelection(by: CGVector(dx: -step, dy: 0))
        case 124: moveSelection(by: CGVector(dx: step, dy: 0))
        case 125: moveSelection(by: CGVector(dx: 0, dy: -step))
        case 126: moveSelection(by: CGVector(dx: 0, dy: step))
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
        commitTextEditor()
        guard let selectedID else { return }
        store.remove(id: selectedID)
        self.selectedID = nil
        needsDisplay = true
    }

    private func applyStyleToSelection() {
        guard let selectedID, var annotation = store.annotation(with: selectedID) else { return }
        annotation.style = style
        store.update(annotation, actionName: "Style Annotation")
    }

    var selectedAnnotation: Annotation? {
        selectedID.flatMap { store.annotation(with: $0) }
    }

    /// The annotation currently being edited in the live text field, or the
    /// selected committed annotation on the canvas.
    var activeAnnotation: Annotation? {
        editingAnnotation ?? selectedAnnotation
    }

    var isEditingText: Bool {
        if case .editingText = editSession { return true }
        return false
    }

    /// Programmatic selection (the toolbar and tests use this; nil clears).
    func selectAnnotation(id: UUID?) {
        selectedID = id
        needsDisplay = true
    }

    /// Style edit scoped correctly: when the on-canvas text editor is active,
    /// updates that live text annotation in place; when a committed annotation
    /// is selected, updates only that annotation (undoable via the store);
    /// otherwise updates the style new annotations receive on this pin.
    func updateSelectedStyle(_ mutate: (inout AnnotationStyle) -> Void) {
        if case .editingText(let field, var editing, let isExisting) = editSession {
            editing.text = field.stringValue
            mutate(&editing.style)
            editSession = .editingText(field: field, annotation: editing, isExisting: isExisting)
            refreshTextEditorAppearance()
            if store.annotation(with: editing.id) != nil {
                store.update(editing, actionName: "Style Annotation")
            } else {
                mutate(&style)
            }
            needsDisplay = true
            onSelectionChange?()
            return
        }
        if let selectedID, var annotation = store.annotation(with: selectedID) {
            mutate(&annotation.style)
            store.update(annotation, actionName: "Style Annotation")
        } else {
            mutate(&style)
        }
    }

    func restoreKeyboardFocus() {
        guard let window else { return }
        if imagePin?.annotationToolbar?.panel.isKeyWindow == true {
            window.makeKey()
        }
        if let textEditor {
            window.makeFirstResponder(textEditor)
        } else {
            window.makeFirstResponder(self)
        }
    }

    // MARK: - Text annotations

    /// A read-only snapshot for previews, including the field's unsaved text.
    /// Never commits the editor or adds an undo step just to open a menu.
    var previewAnnotations: [Annotation] {
        var annotations = store.annotations
        if case .editingText(let field, var annotation, _) = editSession {
            annotation.text = field.stringValue
            if let index = annotations.firstIndex(where: { $0.id == annotation.id }) {
                annotations[index] = annotation
            } else {
                annotations.append(annotation)
            }
        }
        return annotations
    }

    func beginTextEditing(at imageOrigin: CGPoint) {
        let annotation = Annotation(tool: .text, points: [imageOrigin], style: style, text: "")
        presentTextEditor(for: annotation, isNew: true)
    }

    func beginTextEditing(for annotation: Annotation) {
        presentTextEditor(for: annotation, isNew: false)
    }

    private func presentTextEditor(for annotation: Annotation, isNew: Bool) {
        commitTextEditor()
        if isNew {
            selectedID = nil
        } else {
            selectedID = annotation.id
        }

        let field = NSTextField(frame: .zero)
        field.stringValue = annotation.text ?? ""
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85)
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(textEditorCommitted)
        addSubview(field)
        editSession = .editingText(field: field, annotation: annotation, isExisting: !isNew)
        refreshTextEditorAppearance()
        needsDisplay = true
        imagePin?.pinController?.requestKeyboardFocus()
        window?.makeFirstResponder(field)
        onSelectionChange?()
    }

    private func refreshTextEditorAppearance() {
        guard case .editingText(let field, var annotation, let isExisting) = editSession else { return }
        annotation.text = field.stringValue
        editSession = .editingText(field: field, annotation: annotation, isExisting: isExisting)
        let origin = viewPoint(from: annotation.points.first ?? .zero)
        let fontSize = max(annotation.style.fontSize * scaleY, 6)
        let font = annotation.style.font(pointSize: fontSize)
        field.font = font
        field.textColor = annotation.style.color
        let measured = (field.stringValue as NSString).size(withAttributes: [.font: font])
        let width = max(ceil(measured.width) + 28, 160)
        let height = max(ceil(measured.height) + 8, fontSize * 1.5, 22)
        field.frame = NSRect(x: origin.x - 4, y: origin.y - height, width: width, height: height)
    }

    func controlTextDidChange(_ obj: Notification) {
        refreshTextEditorAppearance()
    }

    @objc private func textEditorCommitted() {
        commitTextEditor()
    }

    func commitTextEditor() {
        guard case .editingText(let field, var annotation, _) = editSession else { return }
        let value = field.stringValue
        field.removeFromSuperview()
        editSession = .idle

        let existed = store.annotation(with: annotation.id) != nil
        annotation.text = value
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if existed { store.remove(id: annotation.id) }
        } else if existed {
            store.update(annotation, actionName: "Edit Text")
            selectedID = annotation.id
        } else {
            store.add(annotation)
            selectedID = annotation.id
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
        onSelectionChange?()
    }

    // MARK: - Cursor

    func cursor(at point: NSPoint) -> NSCursor {
        guard isActive else { return .openHand }
        if let selected = selectedAnnotation, handleIndex(at: point, for: selected) != nil { return .crosshair }
        switch tool {
        case .select:
            return topmostAnnotation(at: imagePoint(from: point)) != nil ? .openHand : .arrow
        case .text:
            if let hit = topmostAnnotation(at: imagePoint(from: point)), hit.tool == .text {
                return .openHand
            }
            return .iBeam
        default:
            return .crosshair
        }
    }
}
