import AppKit
import XCTest
@testable import PinboardKit

final class AnnotationInteractionTests: XCTestCase {
    func testShiftConstrainsShapeAndLine() {
        let start = CGPoint(x: 10, y: 20)
        let square = AnnotationTool.rectangle.constrainedEndpoint(from: start, to: CGPoint(x: 60, y: -10))
        XCTAssertEqual(square, CGPoint(x: 60, y: -30))
        let line = AnnotationTool.line.constrainedEndpoint(from: .zero, to: CGPoint(x: 100, y: 5))
        XCTAssertEqual(line.y, 0, accuracy: 0.001)
    }

    func testCountersDuplicateNudgeAndUndo() throws {
        let store = AnnotationStore()
        let canvas = AnnotationCanvasView(store: store, imageSize: CGSize(width: 400, height: 200), effects: nil)
        canvas.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        canvas.addCounter(at: CGPoint(x: 80, y: 80))
        canvas.addCounter(at: CGPoint(x: 160, y: 80))
        XCTAssertEqual(store.annotations.compactMap(\.text), ["1", "2"])
        canvas.duplicateSelection()
        let copy = try XCTUnwrap(store.annotations.last)
        XCTAssertEqual(copy.text, "2")
        XCTAssertEqual(copy.points.first, CGPoint(x: 180, y: 60))
        canvas.moveSelection(by: CGVector(dx: 1, dy: 0))
        XCTAssertEqual(store.annotations.last?.points.first, CGPoint(x: 182, y: 60))
        store.undoManager.undo()
        XCTAssertEqual(store.annotations.last, copy)
        store.undoManager.undo()
        XCTAssertEqual(store.annotations.count, 2)
        let data = try XCTUnwrap(store.encoded())
        let restored = AnnotationStore()
        restored.restore(try AnnotationStore.decode(data))
        XCTAssertEqual(restored.annotations, store.annotations)
    }

    func testEndpointHandleDragCommitsOneUndoStep() throws {
        let manager = PinWindowManager.shared
        let pin = manager.createPin(content: .image(TestImage.make(width: 400, height: 200)))
        defer { manager.closeAll() }
        let image = try XCTUnwrap(pin.contentView as? ImagePinView)
        image.beginAnnotating()
        let canvas = try XCTUnwrap(image.subviews.compactMap { $0 as? AnnotationCanvasView }.first)
        let original = Annotation(tool: .arrow, points: [CGPoint(x: 50, y: 60), CGPoint(x: 150, y: 60)], style: .current())
        image.annotationStore.add(original)
        canvas.selectAnnotation(id: original.id)
        let start = canvas.convert(canvas.viewPoint(from: original.points[1]), to: nil)
        let finish = canvas.convert(canvas.viewPoint(from: CGPoint(x: 200, y: 100)), to: nil)
        func event(_ type: NSEvent.EventType, _ location: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: pin.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try event(.leftMouseDragged, finish), atStart: false)
        NSApp.postEvent(try event(.leftMouseUp, finish), atStart: false)
        canvas.mouseDown(with: try event(.leftMouseDown, start))
        XCTAssertEqual(image.annotationStore.annotations[0].points[1].x, 200, accuracy: 0.1)
        XCTAssertEqual(image.annotationStore.annotations[0].points[1].y, 100, accuracy: 0.1)
        image.annotationStore.undoManager.undo()
        XCTAssertEqual(image.annotationStore.annotations, [original])
    }

    func testGestureGroupsContinuousStyleChangesIntoOneUndo() {
        let store = AnnotationStore()
        var annotation = Annotation(tool: .line, points: [.zero, CGPoint(x: 100, y: 100)], style: .current())
        store.add(annotation)
        let original = annotation
        store.undoManager.beginUndoGrouping()
        for width in 4...8 {
            annotation.style.lineWidth = CGFloat(width)
            store.update(annotation, actionName: "Style Annotation")
        }
        store.undoManager.endUndoGrouping()
        store.undoManager.undo()
        XCTAssertEqual(store.annotations, [original])
        store.undoManager.redo()
        XCTAssertEqual(store.annotations, [annotation])
    }
}
