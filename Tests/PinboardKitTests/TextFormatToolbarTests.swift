import AppKit
import XCTest
@testable import PinboardKit

/// Drives the real toolbar controls instead of calling `TextFormatter`
/// directly, so wiring bugs are caught too.
final class TextFormatToolbarTests: XCTestCase {
    private var manager: PinWindowManager { PinWindowManager.shared }

    override func tearDown() {
        manager.closeAll()
        super.tearDown()
    }

    private func makeEditingPin() throws -> (TextPinView, TextFormatToolbar) {
        let text = NSAttributedString(string: "Hello Pinboard", attributes: ClipboardReader.defaultTextAttributes())
        let pin = manager.createPin(content: .text(text))
        let view = try XCTUnwrap(pin.contentView as? TextPinView)
        view.beginEditing(at: nil)
        return (view, try XCTUnwrap(view.formatToolbar))
    }

    private func swatches(in toolbar: TextFormatToolbar) -> [ColorSwatchButton] {
        toolbar.stack.arrangedSubviews.compactMap { $0 as? ColorSwatchButton }
    }

    /// Mirrors the popover palette reporting a colour live.
    private func pick(_ color: NSColor, with swatch: ColorSwatchButton) {
        swatch.applyPickedColor(color)
    }

    private func color(_ key: NSAttributedString.Key, _ view: TextPinView, at index: Int) -> NSColor? {
        (view.attributedString.attribute(key, at: index, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
    }

    func testTextColorAppliesToSelectionOnly() throws {
        let (view, toolbar) = try makeEditingPin()
        let swatches = swatches(in: toolbar)
        XCTAssertEqual(swatches.count, 2, "text colour and background colour swatches")

        view.editableTextView.setSelectedRange(NSRange(location: 0, length: 5))
        pick(.systemPurple, with: swatches[0])

        XCTAssertEqual(color(.foregroundColor, view, at: 0), NSColor.systemPurple.usingColorSpace(.sRGB))
        XCTAssertNotEqual(color(.foregroundColor, view, at: 10), NSColor.systemPurple.usingColorSpace(.sRGB))
    }

    func testTextColorKeepsOtherAttributes() throws {
        let (view, toolbar) = try makeEditingPin()
        let swatches = swatches(in: toolbar)
        let formatter = TextFormatter(textView: view.editableTextView)
        view.editableTextView.setSelectedRange(NSRange(location: 0, length: 5))
        formatter.toggleTrait(.bold)
        formatter.setFontSize(27)
        pick(.systemTeal, with: swatches[0])

        let font = try XCTUnwrap(view.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(font.pointSize, 27)
        XCTAssertEqual(color(.foregroundColor, view, at: 0), NSColor.systemTeal.usingColorSpace(.sRGB))
    }

    func testBackgroundColorAppliesAndClears() throws {
        let (view, toolbar) = try makeEditingPin()
        let swatches = swatches(in: toolbar)
        view.editableTextView.setSelectedRange(NSRange(location: 0, length: 5))

        pick(.systemYellow, with: swatches[1])
        XCTAssertEqual(color(.backgroundColor, view, at: 0), NSColor.systemYellow.usingColorSpace(.sRGB))
        XCTAssertNil(view.attributedString.attribute(.backgroundColor, at: 10, effectiveRange: nil))
        XCTAssertNil(color(.foregroundColor, view, at: 0).flatMap { $0 == NSColor.systemYellow.usingColorSpace(.sRGB) ? $0 : nil },
                     "background and text colour stay independent")

        swatches[1].applyClear()
        XCTAssertNil(view.attributedString.attribute(.backgroundColor, at: 0, effectiveRange: nil),
                     "the popover's None row removes the attribute")
    }

    func testTextBackgroundDoesNotChangeTheWindowBackground() throws {
        let (view, toolbar) = try makeEditingPin()
        let pin = try XCTUnwrap(view.pinController)
        view.editableTextView.setSelectedRange(NSRange(location: 0, length: 5))
        pick(.systemYellow, with: swatches(in: toolbar)[1])

        XCTAssertFalse(pin.rootView.drawsBackground, "the pin window stays transparent")
        XCTAssertEqual(pin.panel.backgroundColor, NSColor.clear)
        XCTAssertTrue(view.isFullyTransparent)
    }

    func testColorsSurviveStateSync() throws {
        let (view, toolbar) = try makeEditingPin()
        let swatches = swatches(in: toolbar)
        view.editableTextView.setSelectedRange(NSRange(location: 0, length: 5))
        pick(.systemGreen, with: swatches[0])

        view.editableTextView.setSelectedRange(NSRange(location: 12, length: 0))
        toolbar.syncFromSelection()
        view.editableTextView.setSelectedRange(NSRange(location: 0, length: 5))
        toolbar.syncFromSelection()

        XCTAssertEqual(color(.foregroundColor, view, at: 0), NSColor.systemGreen.usingColorSpace(.sRGB))
    }

    func testColorWithoutSelectionAppliesToTypedText() throws {
        let (view, toolbar) = try makeEditingPin()
        let swatches = swatches(in: toolbar)
        let textView = view.editableTextView
        textView.setSelectedRange(NSRange(location: 14, length: 0))

        pick(.systemOrange, with: swatches[0])
        pick(.systemBlue, with: swatches[1])
        XCTAssertEqual((textView.typingAttributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB),
                       NSColor.systemOrange.usingColorSpace(.sRGB))

        textView.insertText("!", replacementRange: NSRange(location: 14, length: 0))
        let last = view.attributedString.length - 1
        XCTAssertEqual(color(.foregroundColor, view, at: last), NSColor.systemOrange.usingColorSpace(.sRGB))
        XCTAssertEqual(color(.backgroundColor, view, at: last), NSColor.systemBlue.usingColorSpace(.sRGB))
    }

    func testColorChangeIsUndoableAndCopiesAsRTF() throws {
        let (view, toolbar) = try makeEditingPin()
        let swatches = swatches(in: toolbar)
        view.editableTextView.setSelectedRange(NSRange(location: 0, length: 5))
        pick(.systemPink, with: swatches[0])
        pick(.systemYellow, with: swatches[1])

        let data = try XCTUnwrap(view.attributedString.rtfRepresentation())
        let roundTripped = try XCTUnwrap(NSAttributedString(rtf: data, documentAttributes: nil))
        XCTAssertNotNil(roundTripped.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        XCTAssertNotNil(roundTripped.attribute(.backgroundColor, at: 0, effectiveRange: nil))

        let undoManager = try XCTUnwrap(view.editableTextView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertNil(view.attributedString.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    }

    func testBackgroundClearKeepsForeground() throws {
        let (view, toolbar) = try makeEditingPin()
        let swatches = swatches(in: toolbar)
        view.editableTextView.setSelectedRange(NSRange(location: 0, length: 5))
        pick(.systemRed, with: swatches[0])
        pick(.systemYellow, with: swatches[1])
        swatches[1].applyClear()

        XCTAssertNil(view.attributedString.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        XCTAssertEqual(color(.foregroundColor, view, at: 0), NSColor.systemRed.usingColorSpace(.sRGB),
                       "clearing the text background keeps the text colour")
    }

    func testTextColorDefaultRestoresLabelColor() throws {
        let (view, toolbar) = try makeEditingPin()
        let swatch = swatches(in: toolbar)[0]
        view.editableTextView.setSelectedRange(NSRange(location: 0, length: 5))
        pick(.systemPurple, with: swatch)
        swatch.applyClear()
        XCTAssertEqual(color(.foregroundColor, view, at: 0), NSColor.labelColor.usingColorSpace(.sRGB))
    }

    func testPickerClosesWhenEditingEnds() throws {
        let (view, toolbar) = try makeEditingPin()
        let swatch = swatches(in: toolbar)[0]
        swatch.sendAction(swatch.action, to: swatch.target)
        XCTAssertTrue(swatch.isPicking)
        XCTAssertFalse(NSColorPanel.shared.isVisible, "the system colour panel must not be used")
        view.endEditing()
        XCTAssertFalse(swatch.isPicking)
    }

    func testSystemUIFontResolvesToConcreteFontFamilyInToolbar() throws {
        let systemText = NSAttributedString(
            string: "System Font Text",
            attributes: [.font: NSFont.systemFont(ofSize: 15)]
        )
        let pin = manager.createPin(content: .text(systemText), textMode: .richText)
        let view = try XCTUnwrap(pin.contentView as? TextPinView)
        view.beginEditing(at: nil)
        let toolbar = try XCTUnwrap(view.formatToolbar)
        toolbar.syncFromSelection()

        let selectedTitle = try XCTUnwrap(toolbar.selectedFontFamilyTitle)
        XCTAssertFalse(selectedTitle.hasPrefix("."), "toolbar must never show .AppleSystemUIFont")
        XCTAssertEqual(selectedTitle, TextDefaults.font.familyName)
    }
}
