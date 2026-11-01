import AppKit
import XCTest
@testable import PinboardKit

final class ReviewRegressionTests: XCTestCase {
    override func tearDown() {
        PinWindowManager.shared.closeAll()
        Preferences.shared.markdownTheme = .standard
        super.tearDown()
    }

    func testExplicitOpaqueBackgroundTracksThemeAndMode() throws {
        let pin = PinWindowManager.shared.createPin(
            content: .text(NSAttributedString(string: "body")), textMode: .markdown
        )
        pin.setBackgroundVisible(true)
        Preferences.shared.markdownTheme = .everforestDarkHard
        XCTAssertEqual(pin.rootView.effectiveBackgroundColor.hexString, "#272E33")
        let text = try XCTUnwrap(pin.contentView as? TextPinView)
        text.setTextMode(.richText, explicit: true)
        XCTAssertTrue(pin.rootView.drawsBackground)
        XCTAssertNil(pin.rootView.themedBackground)
    }

    func testExportCommitsTheActiveTextAnnotation() throws {
        let pin = PinWindowManager.shared.createPin(content: .image(TestImage.make(width: 400, height: 300)))
        let image = try XCTUnwrap(pin.contentView as? ImagePinView)
        image.beginAnnotating()
        let canvas = try XCTUnwrap(image.subviews.compactMap { $0 as? AnnotationCanvasView }.first)
        canvas.tool = .text
        let location = canvas.convert(NSPoint(x: 40, y: 40), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: pin.panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: event)
        let field = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        field.stringValue = "Latest draft"
        _ = image.renderedImage()
        XCTAssertEqual(image.annotationStore.annotations.first?.text, "Latest draft")
    }

    func testDeletingActiveTextDraftDoesNotBringItBackWhenEditingEnds() throws {
        let pin = PinWindowManager.shared.createPin(content: .image(TestImage.make(width: 400, height: 300)))
        let image = try XCTUnwrap(pin.contentView as? ImagePinView)
        image.beginAnnotating()
        let canvas = try XCTUnwrap(image.subviews.compactMap { $0 as? AnnotationCanvasView }.first)
        canvas.tool = .text
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 40, y: 40),
            modifierFlags: [], timestamp: 0, windowNumber: pin.panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: event)
        let field = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        field.stringValue = "draft"
        canvas.deleteSelection()
        image.endEditing()
        XCTAssertTrue(image.annotationStore.annotations.isEmpty)
    }

    func testCorruptAnnotationsCannotSilentlyBecomeAnUnannotatedRepin() throws {
        let manager = PinWindowManager.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HistoryStore(directory: directory)
        manager.historyStore = store
        defer {
            manager.historyStore = nil
            manager.onHistoryError = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let id = try store.upsert(content: .image(TestImage.make(width: 100, height: 100)),
                                  annotationData: Data("{broken".utf8))
        var reported = false
        manager.onHistoryError = { _ in reported = true }
        XCTAssertNil(manager.repin(recordID: id))
        XCTAssertTrue(reported)
        XCTAssertEqual(manager.count, 0)
        XCTAssertThrowsError(try AnnotationStore.decode(Data("{}".utf8)))
    }

    func testFreehandSelectionHitsSegmentsBetweenSamples() {
        let stroke = Annotation(tool: .freehand, points: [.zero, CGPoint(x: 200, y: 0)], style: .current())
        XCTAssertTrue(stroke.hitTest(CGPoint(x: 100, y: 1), textSizer: AnnotationRenderer.textSize))
    }
}
