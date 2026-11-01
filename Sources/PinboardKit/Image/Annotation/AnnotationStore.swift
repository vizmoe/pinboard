import AppKit

/// Non-destructive annotation state for one image pin: the original image is
/// never modified, only this list and the crop rectangle.
final class AnnotationStore {
    private(set) var annotations: [Annotation] = []
    private(set) var cropRect: CGRect?

    let undoManager = UndoManager()
    var onChange: (() -> Void)?

    var isEmpty: Bool { annotations.isEmpty && cropRect == nil }

    init() {
        // Edits happen inside modal mouse-tracking loops, where run loop
        // boundaries are unreliable; group explicitly so every edit is exactly
        // one undo step.
        undoManager.groupsByEvent = false
    }

    /// Wraps one user-visible edit in its own undo group. Nested calls made
    /// while undoing/redoing reuse the group the manager already opened.
    private func transaction(_ body: () -> Void) {
        let shouldGroup = !undoManager.isUndoing && !undoManager.isRedoing && undoManager.groupingLevel == 0
        if shouldGroup { undoManager.beginUndoGrouping() }
        body()
        if shouldGroup { undoManager.endUndoGrouping() }
    }

    func annotation(with id: UUID) -> Annotation? {
        annotations.first { $0.id == id }
    }

    func add(_ annotation: Annotation) {
        transaction { apply(annotations + [annotation], actionName: "Add Annotation") }
    }

    func update(_ annotation: Annotation, actionName: String = "Move Annotation") {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }),
              annotations[index] != annotation else { return }
        var next = annotations
        next[index] = annotation
        transaction { apply(next, actionName: actionName) }
    }

    func remove(id: UUID) {
        transaction { apply(annotations.filter { $0.id != id }, actionName: "Delete Annotation") }
    }

    func bringToFront(id: UUID) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        var next = annotations
        let item = next.remove(at: index)
        next.append(item)
        transaction { apply(next, actionName: "Reorder Annotations") }
    }

    func setCrop(_ rect: CGRect?) {
        guard cropRect != rect else { return }
        transaction { applyCrop(rect) }
    }

    func reset() {
        guard !isEmpty else { return }
        transaction {
            restore(annotations: [], crop: nil, actionName: "Restore Original")
        }
    }

    private func applyCrop(_ rect: CGRect?) {
        let previous = cropRect
        undoManager.registerUndo(withTarget: self) { store in
            store.applyCrop(previous)
        }
        undoManager.setActionName(rect == nil ? "Remove Crop" : "Crop Image")
        cropRect = rect
        onChange?()
    }

    /// Snapshot based undo: simple and safe for the small lists a pin holds.
    private func apply(_ next: [Annotation], actionName: String) {
        let previous = annotations
        undoManager.registerUndo(withTarget: self) { store in
            store.apply(previous, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        annotations = next
        onChange?()
    }

    private func restore(annotations next: [Annotation], crop: CGRect?, actionName: String) {
        let previousAnnotations = annotations
        let previousCrop = cropRect
        undoManager.registerUndo(withTarget: self) { store in
            store.restore(annotations: previousAnnotations, crop: previousCrop, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        annotations = next
        cropRect = crop
        onChange?()
    }

    // MARK: - Persistence

    struct Payload: Codable {
        var annotations: [Annotation]
        var cropRect: CGRect?
    }

    func encoded() -> Data {
        // Live geometry contains only finite values. Encoding failure here is
        // a programming error and must never turn an annotated pin into nil.
        try! JSONEncoder().encode(Payload(annotations: annotations, cropRect: cropRect))
    }

    enum PayloadError: Error { case invalidGeometry }

    static func decode(_ data: Data) throws -> Payload {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        for annotation in payload.annotations {
            let minimumPoints = [.text, .counter].contains(annotation.tool) ? 1 : 2
            guard annotation.points.count >= minimumPoints,
                  annotation.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  annotation.style.lineWidth.isFinite, annotation.style.lineWidth > 0,
                  annotation.style.fontSize.isFinite, annotation.style.fontSize > 0,
                  annotation.tool != .select, annotation.tool != .crop else { throw PayloadError.invalidGeometry }
        }
        if let crop = payload.cropRect {
            guard crop.origin.x.isFinite, crop.origin.y.isFinite,
                  crop.width.isFinite, crop.height.isFinite, crop.width > 0, crop.height > 0 else {
                throw PayloadError.invalidGeometry
            }
        }
        return payload
    }

    /// Restoration accepts a decoded payload; the history/UI boundary reports
    /// corrupt data before constructing a pin or replacing clipboard contents.
    func restore(_ payload: Payload) {
        annotations = payload.annotations
        cropRect = payload.cropRect
        undoManager.removeAllActions()
        onChange?()
    }
}
