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
        let shouldGroup = !undoManager.isUndoing && !undoManager.isRedoing
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

    func update(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        var next = annotations
        next[index] = annotation
        transaction { apply(next, actionName: "Move Annotation") }
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

    func encoded() -> Data? {
        try? JSONEncoder().encode(Payload(annotations: annotations, cropRect: cropRect))
    }

    /// Restores editable annotation state (e.g. from a history record).
    /// Loaded state has no undo steps — undoing past it would be meaningless.
    func restore(from data: Data) {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        annotations = payload.annotations
        cropRect = payload.cropRect
        undoManager.removeAllActions()
        onChange?()
    }
}
