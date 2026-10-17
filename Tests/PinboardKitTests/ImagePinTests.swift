import AppKit
import XCTest
@testable import PinboardKit

final class ImagePinTests: XCTestCase {
    private var manager: PinWindowManager { PinWindowManager.shared }

    override func tearDown() {
        manager.closeAll()
        super.tearDown()
    }

    private func makePin(width: Int = 400, height: Int = 300) throws -> (PinWindowController, ImagePinView) {
        let pin = manager.createPin(content: .image(TestImage.make(width: width, height: height, color: .white)))
        return (pin, try XCTUnwrap(pin.contentView as? ImagePinView))
    }

    func testAnnotationModeIsOptInAndExposesItsUndoStack() throws {
        let (pin, view) = try makePin()
        XCTAssertFalse(view.isAnnotating)
        XCTAssertNil(view.pinUndoManager)

        view.beginAnnotating()
        XCTAssertTrue(view.isAnnotating)
        XCTAssertNotNil(pin.contentView.pinUndoManager)

        view.endEditing()
        XCTAssertFalse(view.isAnnotating)
    }

    func testAnnotationModeSurvivesLosingKeyFocus() throws {
        let (_, view) = try makePin()
        view.beginAnnotating()
        view.handleResignKey()
        XCTAssertTrue(view.isAnnotating, "colour panel or save sheet must not cancel annotating")
    }

    func testAnnotationsAreCompositedIntoTheExport() throws {
        let (_, view) = try makePin()
        let style = AnnotationStyle(colorHex: "#FF0000", lineWidth: 40, fontSize: 18)
        view.annotationStore.add(Annotation(
            tool: .highlight,
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 300)],
            style: style
        ))

        let exported = view.renderedImage()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(exported.pngData())))
        let pixel = try XCTUnwrap(rep.colorAt(x: 200, y: 150)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(pixel.redComponent, pixel.greenComponent + 0.2, "highlight must tint the export")
    }

    func testCropIsNonDestructiveAndUndoable() throws {
        let (_, view) = try makePin(width: 400, height: 300)
        XCTAssertEqual(view.renderedImage().pixelSize.width, 400, accuracy: 1)

        view.annotationStore.setCrop(CGRect(x: 50, y: 40, width: 200, height: 100))
        let cropped = view.renderedImage()
        XCTAssertEqual(cropped.pixelSize.width, 200, accuracy: 1)
        XCTAssertEqual(cropped.pixelSize.height, 100, accuracy: 1)

        view.annotationStore.undoManager.undo()
        XCTAssertNil(view.annotationStore.cropRect)
        XCTAssertEqual(view.renderedImage().pixelSize.width, 400, accuracy: 1, "original pixels are kept")
    }

    func testResetRestoresOriginalImage() throws {
        let (_, view) = try makePin()
        view.annotationStore.add(Annotation(
            tool: .rectangle,
            points: [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 100)],
            style: .current()
        ))
        view.annotationStore.setCrop(CGRect(x: 0, y: 0, width: 100, height: 100))
        view.annotationStore.reset()
        XCTAssertTrue(view.annotationStore.isEmpty)
        XCTAssertEqual(view.renderedImage().pixelSize.width, 400, accuracy: 1)
    }

    func testEachEditIsOneUndoStep() throws {
        let (_, view) = try makePin()
        for index in 0..<3 {
            view.annotationStore.add(Annotation(
                tool: .ellipse,
                points: [CGPoint(x: index * 10, y: 0), CGPoint(x: index * 10 + 30, y: 30)],
                style: .current()
            ))
        }
        XCTAssertEqual(view.annotationStore.annotations.count, 3)
        view.annotationStore.undoManager.undo()
        XCTAssertEqual(view.annotationStore.annotations.count, 2)
        view.annotationStore.undoManager.undo()
        XCTAssertEqual(view.annotationStore.annotations.count, 1)
        view.annotationStore.undoManager.redo()
        XCTAssertEqual(view.annotationStore.annotations.count, 2)
    }
}
