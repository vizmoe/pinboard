import AppKit
import XCTest
@testable import PinboardKit

final class TextFormatterTests: XCTestCase {
    private var manager: PinWindowManager { PinWindowManager.shared }

    override func tearDown() {
        manager.closeAll()
        super.tearDown()
    }

    /// "AAAA" in 24pt red, "BBBB" in 12pt blue.
    private func makePin() throws -> (TextPinView, TextFormatter) {
        let text = NSMutableAttributedString(string: "AAAA", attributes: [
            .font: NSFont(name: "Helvetica", size: 24) ?? NSFont.systemFont(ofSize: 24),
            .foregroundColor: NSColor.systemRed
        ])
        text.append(NSAttributedString(string: "BBBB", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.systemBlue
        ]))
        let pin = manager.createPin(content: .text(text))
        let view = try XCTUnwrap(pin.contentView as? TextPinView)
        view.beginEditing(at: nil)
        return (view, TextFormatter(textView: view.editableTextView))
    }

    private func font(_ view: TextPinView, at index: Int) throws -> NSFont {
        let stored = view.attributedString
        return try XCTUnwrap(stored.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
    }

    func testBoldOnSelectionKeepsOtherRunsIntact() throws {
        let (view, formatter) = try makePin()
        view.editableTextView.setSelectedRange(NSRange(location: 0, length: 4))
        formatter.toggleTrait(.bold)

        let first = try font(view, at: 0)
        XCTAssertTrue(first.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(first.pointSize, 24, "size of the edited run is preserved")
        XCTAssertEqual(first.familyName, "Helvetica", "family of the edited run is preserved")

        let second = try font(view, at: 5)
        XCTAssertFalse(second.fontDescriptor.symbolicTraits.contains(.bold), "other runs untouched")
        XCTAssertEqual(second.pointSize, 12)
        let color = view.attributedString.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, NSColor.systemBlue)
    }

    func testSizeChangeOverMixedRunsKeepsEachFamilyAndTraits() throws {
        let (view, formatter) = try makePin()
        view.editableTextView.setSelectedRange(NSRange(location: 0, length: 8))
        formatter.setFontSize(30)

        XCTAssertEqual(try font(view, at: 0).pointSize, 30)
        XCTAssertEqual(try font(view, at: 5).pointSize, 30)
        XCTAssertEqual(try font(view, at: 0).familyName, "Helvetica")
        XCTAssertEqual(try font(view, at: 5).familyName, NSFont.systemFont(ofSize: 12).familyName)
    }

    func testUnderlineStrikethroughAndHighlightAreRangeScoped() throws {
        let (view, formatter) = try makePin()
        view.editableTextView.setSelectedRange(NSRange(location: 0, length: 4))
        formatter.toggleAttribute(.underlineStyle)
        formatter.toggleAttribute(.strikethroughStyle)
        formatter.setAttribute(.backgroundColor, value: NSColor.systemYellow)

        let stored = view.attributedString
        XCTAssertEqual(stored.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int,
                       NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(stored.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int,
                       NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(stored.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemYellow)
        XCTAssertNil(stored.attribute(.underlineStyle, at: 5, effectiveRange: nil))
        XCTAssertNil(stored.attribute(.backgroundColor, at: 5, effectiveRange: nil))

        formatter.toggleAttribute(.underlineStyle)
        XCTAssertEqual(view.attributedString.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, 0)
        formatter.setAttribute(.backgroundColor, value: nil)
        XCTAssertNil(view.attributedString.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    }

    func testFormattingWithoutSelectionAppliesToTypingAttributes() throws {
        let (view, formatter) = try makePin()
        let textView = view.editableTextView
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        formatter.toggleTrait(.bold)
        formatter.setAttribute(.foregroundColor, value: NSColor.systemGreen)

        let typingFont = try XCTUnwrap(textView.typingAttributes[.font] as? NSFont)
        XCTAssertTrue(typingFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(textView.typingAttributes[.foregroundColor] as? NSColor, .systemGreen)
        XCTAssertEqual(view.attributedString.string, "AAAABBBB", "text is unchanged")
        XCTAssertFalse(try font(view, at: 0).fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testFormattingIsUndoable() throws {
        let (view, formatter) = try makePin()
        view.editableTextView.setSelectedRange(NSRange(location: 0, length: 4))
        formatter.toggleTrait(.bold)
        XCTAssertTrue(try font(view, at: 0).fontDescriptor.symbolicTraits.contains(.bold))

        let undoManager = try XCTUnwrap(view.editableTextView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertFalse(try font(view, at: 0).fontDescriptor.symbolicTraits.contains(.bold))
        undoManager.redo()
        XCTAssertTrue(try font(view, at: 0).fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testFamilyChangeKeepsBoldAndItalic() throws {
        let (view, formatter) = try makePin()
        let textView = view.editableTextView
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        formatter.toggleTrait(.bold)
        formatter.toggleTrait(.italic)
        formatter.setFontFamily("Times New Roman")

        let font = try font(view, at: 0)
        XCTAssertEqual(font.familyName, "Times New Roman")
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold), "bold survives a family change")
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.italic), "italic survives a family change")
        XCTAssertEqual(font.pointSize, 24)
    }

    func testClearFormattingResetsOnlySelection() throws {
        let (view, formatter) = try makePin()
        let textView = view.editableTextView
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        formatter.setAttribute(.backgroundColor, value: NSColor.systemYellow)
        formatter.toggleAttribute(.underlineStyle)
        formatter.clearFormatting()

        let stored = view.attributedString
        XCTAssertNil(stored.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        XCTAssertNil(stored.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        XCTAssertEqual(stored.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .labelColor)
        XCTAssertEqual(try font(view, at: 0).pointSize, TextFormatter.baseFont.pointSize)
        XCTAssertEqual(stored.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor, .systemBlue,
                       "text outside the selection keeps its formatting")
        XCTAssertEqual(stored.string, "AAAABBBB")
    }

    func testStateReflectsCaretPosition() throws {
        let (view, formatter) = try makePin()
        view.editableTextView.setSelectedRange(NSRange(location: 0, length: 4))
        XCTAssertEqual(formatter.currentFont.pointSize, 24)
        XCTAssertEqual(formatter.currentColor(.foregroundColor), .systemRed)

        view.editableTextView.setSelectedRange(NSRange(location: 4, length: 4))
        XCTAssertEqual(formatter.currentFont.pointSize, 12)
        XCTAssertEqual(formatter.currentColor(.foregroundColor), .systemBlue)
    }

    func testFormattedTextStillCopiesAsRTF() throws {
        let (view, formatter) = try makePin()
        view.editableTextView.setSelectedRange(NSRange(location: 0, length: 4))
        formatter.toggleTrait(.bold)
        formatter.setAttribute(.backgroundColor, value: NSColor.systemYellow)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pinboard.format.test"))
        pasteboard.clearContents()
        pasteboard.writeObjects([view.attributedString])
        let data = try XCTUnwrap(pasteboard.data(forType: .rtf))
        let roundTripped = try XCTUnwrap(NSAttributedString(rtf: data, documentAttributes: nil))
        let font = try XCTUnwrap(roundTripped.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertNotNil(roundTripped.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    }

    func testToolbarVisibilityFollowsEditing() throws {
        let (view, _) = try makePin()
        XCTAssertTrue(view.isEditing)
        XCTAssertNotNil(view.formatToolbar)
        view.endEditing()
        XCTAssertFalse(view.isEditing)
        XCTAssertFalse(view.formatToolbar?.panel.isVisible ?? false)
    }
}
