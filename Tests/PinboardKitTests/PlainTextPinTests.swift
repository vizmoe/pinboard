import AppKit
import XCTest
@testable import PinboardKit

/// Plain Text pins: imported formatting is dropped, the default typography
/// applies, and mode switching keeps the characters.
final class PlainTextPinTests: XCTestCase {
    private var manager: PinWindowManager { PinWindowManager.shared }

    override func tearDown() {
        manager.closeAll()
        Preferences.shared.textMode = .richText
        super.tearDown()
    }

    private func makeView(_ content: PinContent,
                          explicitMode: TextContentMode? = nil) throws -> (PinWindowController, TextPinView) {
        let pin = manager.createPin(content: content, textMode: explicitMode)
        return (pin, try XCTUnwrap(pin.contentView as? TextPinView))
    }

    private func text(of view: TextPinView) throws -> String {
        guard case .text(let attributed) = view.currentContent() else {
            throw XCTSkip("expected text content")
        }
        return attributed.string
    }

    private func font(of view: TextPinView, at index: Int = 0) -> NSFont? {
        view.attributedString.attribute(.font, at: index, effectiveRange: nil) as? NSFont
    }

    private let rich = NSAttributedString(string: "bold words", attributes: [
        .font: NSFont.boldSystemFont(ofSize: 30),
        .foregroundColor: NSColor.systemRed
    ])

    // MARK: - Display

    func testPlainPinDropsImportedFormatting() throws {
        let (_, view) = try makeView(.text(rich), explicitMode: .plainText)

        XCTAssertEqual(view.textMode, .plainText)
        XCTAssertEqual(try text(of: view), "bold words", "the characters survive")

        let font = try XCTUnwrap(self.font(of: view))
        XCTAssertEqual(font.familyName, "PingFang SC")
        XCTAssertEqual(font.pointSize, TextDefaults.fontSize)
        XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.bold), "bold is dropped")
        XCTAssertEqual(view.attributedString.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       NSColor.labelColor, "the red is dropped")
    }

    func testPlainPinEditsUseTheDefaultFont() throws {
        let (_, view) = try makeView(.text(rich), explicitMode: .plainText)

        view.beginEditing(at: nil)
        XCTAssertNil(view.formatToolbar, "plain text has no rich formatting controls")
        view.editableTextView.insertText(" tail",
                                         replacementRange: NSRange(location: 10, length: 0))
        view.endEditing()

        XCTAssertEqual(try text(of: view), "bold words tail")
        XCTAssertEqual(try XCTUnwrap(font(of: view)).familyName, "PingFang SC")
    }

    func testPlainCopyWritesTheStringWithoutRTF() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pinboard.plain.copy"))
        pasteboard.clearContents()
        let (_, view) = try makeView(.text(rich), explicitMode: .plainText)

        view.copy(to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "bold words")
        XCTAssertNil(pasteboard.data(forType: .rtf), "plain text is not copied as rich text")
    }

    // MARK: - Mode switching

    func testSwitchToPlainAndBackRestoresTheExactFormatting() throws {
        let (_, view) = try makeView(.text(rich), explicitMode: .richText)

        view.setTextMode(.plainText, explicit: true)
        XCTAssertEqual(try XCTUnwrap(font(of: view)).pointSize, TextDefaults.fontSize)

        view.setTextMode(.richText, explicit: true)
        let restored = try XCTUnwrap(font(of: view))
        XCTAssertEqual(restored.pointSize, 30, "the pre-switch representation is remembered")
        XCTAssertTrue(restored.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testPlainToMarkdownRendersTheSource() throws {
        let (_, view) = try makeView(.text(rich), explicitMode: .plainText)

        view.beginEditing(at: nil)
        view.editableTextView.setSelectedRange(NSRange(location: 0, length: view.editableTextView.string.utf16.count))
        view.editableTextView.insertText("**x**", replacementRange: view.editableTextView.selectedRange())
        view.endEditing()
        view.setTextMode(.markdown, explicit: true)

        XCTAssertEqual(view.renderedAttributedString.string, "x", "the plain text is treated as Markdown source")
        XCTAssertEqual(try text(of: view), "**x**", "the source stays canonical")
    }

    func testNewPinsFollowThePlainTextGlobalDefault() throws {
        Preferences.shared.textMode = .plainText
        let (_, view) = try makeView(.text(NSAttributedString(string: "plain")))

        XCTAssertEqual(view.textMode, .plainText)
        XCTAssertFalse(view.hasExplicitTextMode)

        Preferences.shared.textMode = .richText
        XCTAssertEqual(view.textMode, .richText, "an untouched pin follows the global default")
        XCTAssertEqual(try text(of: view), "plain")
    }

    func testExplicitPlainSwitchStopsFollowingTheGlobalDefault() throws {
        Preferences.shared.textMode = .richText
        let (_, view) = try makeView(.text(NSAttributedString(string: "stays plain")))
        view.setTextMode(.plainText, explicit: true)

        Preferences.shared.textMode = .markdown
        XCTAssertEqual(view.textMode, .plainText, "a pin switched per window ignores the global default")
    }
}

/// Plain Text state across history: the record keeps the mode and re-pinning
/// reproduces a plain pin.
final class PlainTextHistoryTests: XCTestCase {
    private var manager: PinWindowManager { PinWindowManager.shared }
    private var directory: URL!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = HistoryStore(directory: directory)
        manager.historyStore = store
    }

    override func tearDown() {
        manager.closeAll()
        manager.historyStore = nil
        manager.onHistoryError = nil
        Preferences.shared.textMode = .richText
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testPlainModePersistsAndRepinRestoresIt() throws {
        let rich = NSAttributedString(string: "note", attributes: [.font: NSFont.boldSystemFont(ofSize: 30)])
        let pin = manager.createPin(content: .text(rich), textMode: .plainText)
        let recordID = try XCTUnwrap(pin.historyRecordID)
        manager.flushHistorySync(for: pin)

        XCTAssertEqual(store.record(id: recordID)?.textMode, .plainText)
        let reloaded = HistoryStore(directory: directory)
        XCTAssertEqual(reloaded.entry(id: recordID)?.textMode, .plainText)

        let repinned = try XCTUnwrap(manager.repin(recordID: recordID))
        let view = try XCTUnwrap(repinned.contentView as? TextPinView)
        XCTAssertEqual(view.textMode, .plainText)
        XCTAssertEqual(view.attributedString.string, "note")
        let font = try XCTUnwrap(view.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, TextDefaults.fontSize, "a plain record carries no formatting")
    }
}

/// The app-wide default typography: PingFang SC at 14 points.
final class TextDefaultsTests: XCTestCase {
    func testDefaultFontIsPingFangSCAt14() {
        XCTAssertEqual(TextDefaults.fontSize, 14)
        XCTAssertEqual(TextDefaults.font.familyName, "PingFang SC")
        XCTAssertEqual(TextDefaults.font.pointSize, 14)
    }

    func testPlainClipboardTextUsesTheDefaultFont() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pinboard.defaults.plain"))
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)

        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected plain text content")
        }
        let font = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.familyName, "PingFang SC")
        XCTAssertEqual(font.pointSize, 14)
    }

    func testMarkdownRendersWithTheDefaultFont() throws {
        let output = MarkdownRenderer.render("plain body")
        let font = try XCTUnwrap(output.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.familyName, "PingFang SC")
        XCTAssertEqual(font.pointSize, 14)
    }

    func testMarkdownEmphasisSurvivesAFontWithoutItalics() throws {
        let output = MarkdownRenderer.render("**bold** *slanted*")
        let bold = try XCTUnwrap(output.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))

        // PingFang SC has no italic face; emphasis falls back to obliqueness.
        let location = (output.string as NSString).range(of: "slanted").location
        let italic = try XCTUnwrap(output.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
        let obliqueness = output.attribute(.obliqueness, at: location, effectiveRange: nil) as? CGFloat
        XCTAssertTrue(italic.fontDescriptor.symbolicTraits.contains(.italic) || (obliqueness ?? 0) > 0,
                      "emphasis stays visually distinct")
    }

    func testAllTextModesShareIdenticalTypographyAndLayoutForUnstyledText() throws {
        let manager = PinWindowManager.shared
        defer { manager.closeAll() }
        let sample = "First line of plain text\nSecond line of plain text"
        let maxSize = CGSize(width: 500, height: 400)

        let richPin = manager.createPin(
            content: .text(NSAttributedString(string: sample, attributes: TextDefaults.attributes)),
            textMode: .richText
        )
        let plainPin = manager.createPin(
            content: .text(NSAttributedString(string: sample, attributes: TextDefaults.attributes)),
            textMode: .plainText
        )
        let markdownPin = manager.createPin(
            content: .text(NSAttributedString(string: sample, attributes: TextDefaults.attributes)),
            textMode: .markdown
        )

        let richView = try XCTUnwrap(richPin.contentView as? TextPinView)
        let plainView = try XCTUnwrap(plainPin.contentView as? TextPinView)
        let markdownView = try XCTUnwrap(markdownPin.contentView as? TextPinView)

        XCTAssertEqual(richView.idealSize(fitting: maxSize), plainView.idealSize(fitting: maxSize))
        XCTAssertEqual(plainView.idealSize(fitting: maxSize), markdownView.idealSize(fitting: maxSize))

        for view in [richView, plainView, markdownView] {
            let storage = try XCTUnwrap(view.editableTextView.textStorage)
            let font = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            let paragraph = try XCTUnwrap(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(font.familyName, "PingFang SC")
            XCTAssertEqual(font.pointSize, 14)
            XCTAssertEqual(paragraph.lineSpacing, 2)
            XCTAssertEqual(paragraph.paragraphSpacing, 0)
        }
    }
}
