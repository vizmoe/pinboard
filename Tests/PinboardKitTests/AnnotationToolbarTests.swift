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

    func testRedactionToolsAreMergedInMainStripWithModeSwitcherInProperties() throws {
        let (view, canvas, slider) = try makeEditor()
        let toolbar = try XCTUnwrap(view.annotationToolbar)
        let toolsRow = try XCTUnwrap(toolbar.stack.arrangedSubviews.first as? NSStackView)
        let properties = try XCTUnwrap(toolbar.stack.arrangedSubviews.last as? NSStackView)

        let toolButtons = toolsRow.arrangedSubviews.compactMap { $0 as? NSButton }
        XCTAssertFalse(toolButtons.contains { $0.toolTip?.hasPrefix("Blur") == true },
                       "Blur and Mosaic must be merged into a single redaction tool button in the main strip")
        let redactButton = try XCTUnwrap(toolButtons.first { $0.toolTip?.contains("Mosaic") == true || $0.toolTip?.contains("Redact") == true })

        redactButton.performClick(nil)
        XCTAssertEqual(canvas.tool, .mosaic)
        let modeControl = try XCTUnwrap(properties.arrangedSubviews.compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertFalse(modeControl.isHidden)
        XCTAssertEqual(modeControl.segmentCount, 3, "3-in-1 Redaction offers Mosaic, Secure Blur, and Solid Fill")
        XCTAssertEqual(modeControl.selectedSegment, 0, "Mosaic segment is selected by default")
        let colorSwatch = try XCTUnwrap(properties.arrangedSubviews.compactMap { $0 as? ColorSwatchButton }.first)
        XCTAssertTrue(colorSwatch.isHidden, "Mosaic derives colors from image tiles rather than a solid color swatch")
        XCTAssertFalse(slider.isHidden, "Mosaic exposes the block-size slider")

        // Switch to Secure Blur (segment 1) in the contextual properties bar.
        modeControl.selectedSegment = 1
        XCTAssertTrue(modeControl.sendAction(modeControl.action, to: modeControl.target))
        XCTAssertEqual(canvas.style.redactionStyle, .blur)
        XCTAssertTrue(colorSwatch.isHidden, "Secure Blur derives colors from scrambled image tiles")
        XCTAssertFalse(slider.isHidden, "Secure Blur exposes the intensity slider")

        // Switch to Solid Fill (segment 2) in the contextual properties bar.
        modeControl.selectedSegment = 2
        XCTAssertTrue(modeControl.sendAction(modeControl.action, to: modeControl.target))
        XCTAssertEqual(canvas.tool, .blur)
        XCTAssertEqual(canvas.style.redactionStyle, .solid)
        XCTAssertFalse(colorSwatch.isHidden, "Solid Fill exposes the color swatch")
        XCTAssertTrue(slider.isHidden, "Solid Fill does not use a stroke/block-size slider")

        // Selecting an existing Mosaic annotation and toggling the segmented control converts it to Solid Fill (undoably).
        let mosaicAnnotation = Annotation(tool: .mosaic, points: [.zero, CGPoint(x: 60, y: 60)], style: .current())
        view.annotationStore.add(mosaicAnnotation)
        canvas.selectAnnotation(id: mosaicAnnotation.id)
        XCTAssertEqual(modeControl.selectedSegment, 0)

        modeControl.selectedSegment = 2
        XCTAssertTrue(modeControl.sendAction(modeControl.action, to: modeControl.target))
        XCTAssertEqual(view.annotationStore.annotation(with: mosaicAnnotation.id)?.tool, .blur)
        XCTAssertEqual(view.annotationStore.annotation(with: mosaicAnnotation.id)?.effectiveRedactionStyle, .solid)

        view.annotationStore.undoManager.undo()
        XCTAssertEqual(view.annotationStore.annotation(with: mosaicAnnotation.id)?.tool, .mosaic)
    }

    func testSpotlightTextAndHighlighterModeControlsInToolbar() throws {
        let (view, canvas, slider) = try makeEditor()
        let toolbar = try XCTUnwrap(view.annotationToolbar)
        let properties = try XCTUnwrap(toolbar.stack.arrangedSubviews.last as? NSStackView)
        let segmentedControls = properties.arrangedSubviews.compactMap { $0 as? NSSegmentedControl }
        XCTAssertEqual(segmentedControls.count, 3)
        let spotlightControl = segmentedControls[1]
        let highlightControl = segmentedControls[2]

        canvas.tool = .spotlight
        toolbar.syncSelection()
        XCTAssertFalse(spotlightControl.isHidden)
        XCTAssertFalse(slider.isHidden)
        spotlightControl.selectedSegment = 1
        XCTAssertTrue(spotlightControl.sendAction(spotlightControl.action, to: spotlightControl.target))
        XCTAssertEqual(canvas.style.spotlightShape, .ellipse)

        canvas.tool = .highlight
        toolbar.syncSelection()
        XCTAssertFalse(highlightControl.isHidden)
        XCTAssertTrue(slider.isHidden, "Rectangle highlighter hides thickness slider")
        highlightControl.selectedSegment = 1
        XCTAssertTrue(highlightControl.sendAction(highlightControl.action, to: highlightControl.target))
        XCTAssertEqual(canvas.style.highlightMode, .freehand)
        XCTAssertFalse(slider.isHidden, "Freehand highlighter exposes thickness slider")

        canvas.tool = .text
        toolbar.syncSelection()
        let fontControls = try XCTUnwrap(properties.arrangedSubviews.compactMap { $0 as? NSStackView }.first)
        let textStyleControl = try XCTUnwrap(fontControls.arrangedSubviews.compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertFalse(textStyleControl.isHidden)
        textStyleControl.selectedSegment = 1
        XCTAssertTrue(textStyleControl.sendAction(textStyleControl.action, to: textStyleControl.target))
        XCTAssertEqual(canvas.style.textStyle, .box)
    }

    func testSecondaryPropertiesRowIsHorizontallyCenteredAcrossAllToolsAndModes() throws {
        let (view, canvas, _) = try makeEditor()
        let toolbar = try XCTUnwrap(view.annotationToolbar)
        let properties = try XCTUnwrap(toolbar.stack.arrangedSubviews.last as? NSStackView)

        let states: [(String, () -> Void)] = [
            ("rectangle", { canvas.tool = .rectangle }),
            ("ellipse", { canvas.tool = .ellipse }),
            ("arrow", { canvas.tool = .arrow }),
            ("line", { canvas.tool = .line }),
            ("freehand", { canvas.tool = .freehand }),
            ("text", { canvas.tool = .text }),
            ("counter", { canvas.tool = .counter }),
            ("highlight-rect", { canvas.style.highlightMode = .rectangle; canvas.tool = .highlight }),
            ("highlight-freehand", { canvas.style.highlightMode = .freehand; canvas.tool = .highlight }),
            ("redact-mosaic", { canvas.style.redactionStyle = .mosaic; canvas.tool = .mosaic }),
            ("redact-blur", { canvas.style.redactionStyle = .blur; canvas.tool = .mosaic }),
            ("redact-solid", { canvas.style.redactionStyle = .solid; canvas.tool = .blur }),
            ("spotlight", { canvas.tool = .spotlight })
        ]

        for (name, applyState) in states {
            applyState()
            toolbar.syncSelection()
            toolbar.panel.contentView?.layoutSubtreeIfNeeded()
            XCTAssertFalse(properties.isHidden, "\(name) should show secondary properties")

            let visibleControls = properties.arrangedSubviews.filter { !$0.isHidden }
            XCTAssertFalse(visibleControls.isEmpty, "\(name) should have visible property controls")
            for control in visibleControls where control is NSSegmentedControl {
                XCTAssertLessThanOrEqual(control.frame.width, 110, "\(name): segmented control must hug its segments")
            }
            let propertiesInStack = properties.convert(properties.bounds, to: toolbar.stack)
            XCTAssertEqual(propertiesInStack.midX, toolbar.stack.bounds.midX, accuracy: 2.0,
                           "\(name): secondary properties stack must be centered in the toolbar")
            let unionRect = visibleControls
                .map { $0.convert($0.bounds, to: toolbar.stack) }
                .reduce(into: CGRect.null) { $0 = $0.union($1) }
            XCTAssertEqual(unionRect.midX, toolbar.stack.bounds.midX, accuracy: 2.0,
                           "\(name): secondary property controls must be horizontally centered in the toolbar")
        }
    }
}
