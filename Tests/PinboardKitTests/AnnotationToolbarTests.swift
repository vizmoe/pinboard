import AppKit
import XCTest
@testable import PinboardKit

final class AnnotationToolbarTests: XCTestCase {
    private var manager: PinWindowManager { .shared }

    override func tearDown() {
        manager.closeAll()
        super.tearDown()
    }

    private func makeEditor() throws -> (ImagePinView, AnnotationCanvasView, NSSlider) {
        let pin = manager.createPin(content: .image(TestImage.make(width: 200, height: 100)))
        let view = try XCTUnwrap(pin.contentView as? ImagePinView)
        view.beginAnnotating()
        let canvas = try XCTUnwrap(view.subviews.compactMap { $0 as? AnnotationCanvasView }.first)
        let toolbar = try XCTUnwrap(view.annotationToolbar)
        let properties = try XCTUnwrap(toolbar.stack.arrangedSubviews.last as? NSStackView)
        let slider = try XCTUnwrap(properties.arrangedSubviews.compactMap { $0 as? NSSlider }.first)
        return (view, canvas, slider)
    }

    func testSelectedWidthTracksSelectionAndUndoWithoutChangingDefaults() throws {
        let preference = Preferences.shared.annotationLineWidth
        defer { Preferences.shared.annotationLineWidth = preference }
        let (view, canvas, slider) = try makeEditor()
        let first = Annotation(tool: .line, points: [.zero, CGPoint(x: 30, y: 30)],
                               style: AnnotationStyle(colorHex: "#FF0000", lineWidth: 2, fontSize: 18))
        let second = Annotation(tool: .line, points: [.zero, CGPoint(x: 40, y: 40)],
                                style: AnnotationStyle(colorHex: "#0000FF", lineWidth: 12, fontSize: 18))
        view.annotationStore.add(first)
        view.annotationStore.add(second)
        canvas.selectAnnotation(id: first.id)
        XCTAssertEqual(slider.doubleValue, 2)
        canvas.selectAnnotation(id: second.id)
        XCTAssertEqual(slider.doubleValue, 12)

        slider.doubleValue = 9
        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
        XCTAssertEqual(view.annotationStore.annotation(with: second.id)?.style.lineWidth, 9)
        XCTAssertEqual(view.annotationStore.annotation(with: first.id), first)
        XCTAssertEqual(Preferences.shared.annotationLineWidth, preference)
        XCTAssertEqual(canvas.style.lineWidth, CGFloat(preference))

        view.annotationStore.undoManager.undo()
        XCTAssertEqual(view.annotationStore.annotation(with: second.id), second)
        XCTAssertEqual(slider.doubleValue, 12)
        view.annotationStore.undoManager.redo()
        XCTAssertEqual(slider.doubleValue, 9)

        canvas.selectAnnotation(id: nil)
        XCTAssertEqual(slider.doubleValue, preference)
    }

    func testWidthWithoutSelectionSeedsNewAnnotations() throws {
        let preference = Preferences.shared.annotationLineWidth
        defer { Preferences.shared.annotationLineWidth = preference }
        let (_, canvas, slider) = try makeEditor()
        slider.doubleValue = 7
        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
        XCTAssertEqual(canvas.style.lineWidth, 7)
        XCTAssertEqual(Preferences.shared.annotationLineWidth, 7)
    }

    func testFontSizeWithoutSelectionSeedsPreferences() throws {
        let preference = Preferences.shared.annotationFontSize
        defer { Preferences.shared.annotationFontSize = preference }
        let (view, canvas, _) = try makeEditor()
        canvas.tool = .text
        let toolbar = try XCTUnwrap(view.annotationToolbar)
        let properties = try XCTUnwrap(toolbar.stack.arrangedSubviews.last as? NSStackView)
        let fontControls = try XCTUnwrap(properties.arrangedSubviews.compactMap { $0 as? NSStackView }.first)
        let sizeField = try XCTUnwrap(fontControls.arrangedSubviews.compactMap { $0 as? NSTextField }.first)
        sizeField.doubleValue = 32
        XCTAssertTrue(sizeField.sendAction(sizeField.action, to: sizeField.target))
        XCTAssertEqual(canvas.style.fontSize, 32)
        XCTAssertEqual(Preferences.shared.annotationFontSize, 32)
    }
}
