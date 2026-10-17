import AppKit
import XCTest
@testable import PinboardKit

final class ColorPickerTests: XCTestCase {
    func testPresetGridHasExpectedColors() {
        let picker = ColorPickerView(clearTitle: nil)
        XCTAssertEqual(picker.presetSwatches.count, 11)
        XCTAssertEqual(picker.presetSwatches[0].fill, .black)
        XCTAssertEqual(picker.presetSwatches[10].fill, .systemPink)
        XCTAssertNil(picker.clearButton, "no clear row without a title")
    }

    func testPresetClickReportsColorAndMarksSelection() {
        let picker = ColorPickerView(clearTitle: nil)
        var picked: NSColor?
        picker.onPick = { picked = $0 }

        let red = picker.presetSwatches[3]
        red.sendAction(red.action, to: red.target)

        XCTAssertEqual(picked?.usingColorSpace(.sRGB), NSColor.systemRed.usingColorSpace(.sRGB))
        XCTAssertTrue(red.isChosen)
        XCTAssertEqual(picker.hexField.stringValue, NSColor.systemRed.hexString)
    }

    func testClearRowReportsClear() {
        let picker = ColorPickerView(clearTitle: "None")
        var cleared = false
        picker.onClear = { cleared = true }
        let button = picker.clearButton
        XCTAssertEqual(button?.title, "None")
        button?.sendAction(button?.action, to: button?.target)
        XCTAssertTrue(cleared)
    }

    func testValidHexAppliesImmediately() {
        let picker = ColorPickerView(clearTitle: nil)
        var picked: NSColor?
        picker.onPick = { picked = $0 }

        picker.hexField.stringValue = "#FF5733"
        XCTAssertTrue(picker.applyHexField())
        let color = picked?.usingColorSpace(.sRGB)
        XCTAssertNotNil(color)
        XCTAssertEqual(color?.redComponent ?? 0, 1.0, accuracy: 0.01)
        XCTAssertEqual(color?.greenComponent ?? 0, CGFloat(0x57) / 255, accuracy: 0.01)
        XCTAssertEqual(color?.blueComponent ?? 0, CGFloat(0x33) / 255, accuracy: 0.01)
    }

    func testHexWithAlphaParses() {
        let picker = ColorPickerView(clearTitle: nil)
        var picked: NSColor?
        picker.onPick = { picked = $0 }
        picker.hexField.stringValue = "#00FF0080"
        XCTAssertTrue(picker.applyHexField())
        let color = picked?.usingColorSpace(.sRGB)
        XCTAssertEqual(color?.alphaComponent ?? 0, 0x80 / 255.0, accuracy: 0.01)
        XCTAssertEqual(color?.greenComponent ?? 0, 1.0, accuracy: 0.01)
    }

    func testInvalidHexIsRejectedWithoutApplying() {
        let picker = ColorPickerView(clearTitle: nil)
        var picked = false
        picker.onPick = { _ in picked = true }

        picker.hexField.stringValue = "#GGGGGG"
        XCTAssertFalse(picker.applyHexField())
        XCTAssertFalse(picked, "invalid input must not report a colour")
        XCTAssertEqual(picker.hexField.textColor, .systemRed, "invalid input gets visible feedback")
    }

    func testSwatchOpensPopoverNotSystemPanel() {
        let swatch = ColorSwatchButton(tooltip: "Text Color")
        swatch.clearTitle = "Default"
        swatch.applyPickedColor(.systemBlue)
        XCTAssertEqual(swatch.color, .systemBlue)
        XCTAssertFalse(NSColorPanel.shared.isVisible)
    }
}
