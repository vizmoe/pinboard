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

    func testSnapshotRoundTripKeepsOriginalPixelsAndEditableAnnotations() throws {
        let (pin, view) = try makePin(width: 400, height: 300)
        view.annotationStore.add(Annotation(
            tool: .highlight,
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 300)],
            style: AnnotationStyle(colorHex: "#FF0000", lineWidth: 3, fontSize: 18)
        ))
        view.annotationStore.setCrop(CGRect(x: 50, y: 40, width: 200, height: 100))

        let snapshot = try JSONDecoder().decode(PinSnapshot.self, from: JSONEncoder().encode(pin.snapshot()))
        let restored = manager.createPin(content: try XCTUnwrap(snapshot.makeContent()),
                                         annotations: try snapshot.annotationData.map(AnnotationStore.decode))
        let restoredView = try XCTUnwrap(restored.contentView as? ImagePinView)

        XCTAssertEqual(restoredView.baseImage.pixelSize, CGSize(width: 400, height: 300))
        XCTAssertEqual(restoredView.annotationStore.annotations, view.annotationStore.annotations)
        XCTAssertEqual(restoredView.annotationStore.cropRect, view.annotationStore.cropRect)
        let original = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(view.renderedImage().pngData())))
        let roundTrip = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(restoredView.renderedImage().pngData())))
        let expected = try XCTUnwrap(original.colorAt(x: 100, y: 50)?.usingColorSpace(.sRGB))
        let actual = try XCTUnwrap(roundTrip.colorAt(x: 100, y: 50)?.usingColorSpace(.sRGB))
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.01,
                       "restoring must not apply the highlight twice")

        restoredView.annotationStore.reset()
        XCTAssertEqual(restoredView.renderedImage().pixelSize, CGSize(width: 400, height: 300))
        let reset = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(restoredView.renderedImage().pngData())))
        let pixel = try XCTUnwrap(reset.colorAt(x: 200, y: 150)?.usingColorSpace(.sRGB))
        XCTAssertEqual(pixel.greenComponent, 1, accuracy: 0.01,
                       "reset must recover untinted original pixels")
    }

    func testCropUndoRedoAndResetKeepWindowGeometryProportional() throws {
        let (pin, view) = try makePin(width: 800, height: 600)
        let originalFrame = pin.panel.frame
        XCTAssertEqual(originalFrame.width, 400, accuracy: 1)
        XCTAssertEqual(originalFrame.height, 300, accuracy: 1)

        view.annotationStore.setCrop(CGRect(x: 100, y: 100, width: 400, height: 200))
        XCTAssertEqual(pin.panel.frame.width, 200, accuracy: 1, "crop shrinks the window at the same display scale")
        XCTAssertEqual(pin.panel.frame.height, 100, accuracy: 1)
        XCTAssertEqual(pin.panel.frame.maxY, originalFrame.maxY, accuracy: 1, "top-left corner stays anchored")

        view.annotationStore.undoManager.undo()
        XCTAssertEqual(pin.panel.frame, originalFrame,
                       "undoing a crop must restore the window size instead of squashing the image into the cropped frame")

        view.annotationStore.undoManager.redo()
        XCTAssertEqual(pin.panel.frame.size, CGSize(width: 200, height: 100),
                       "redoing a crop must re-apply the cropped window size")

        view.annotationStore.reset()
        XCTAssertEqual(pin.panel.frame, originalFrame,
                       "restoring the original image must restore the uncropped window dimensions")
    }
}
