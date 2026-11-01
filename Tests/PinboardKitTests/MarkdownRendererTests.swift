import AppKit
import XCTest
@testable import PinboardKit

/// Structure-level tests for the Markdown → attributed string renderer. They
/// assert on fonts, paragraph styles and markers, not on pixels, so they stay
/// independent of window layout.
final class MarkdownRendererTests: XCTestCase {
    private let style = MarkdownRenderer.Style.default

    private func render(_ source: String) -> NSAttributedString {
        MarkdownRenderer.render(source)
    }

    /// Index of the first occurrence of `needle`; fails the test when absent.
    private func index(of needle: String, in text: NSAttributedString,
                       file: StaticString = #filePath, line: UInt = #line) -> Int? {
        let location = (text.string as NSString).range(of: needle).location
        if location == NSNotFound {
            XCTFail("expected \(needle.debugDescription) in \(text.string.debugDescription)", file: file, line: line)
            return nil
        }
        return location
    }

    private func font(_ text: NSAttributedString, at needle: String) -> NSFont? {
        guard let location = index(of: needle, in: text) else { return nil }
        return text.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    }

    private func paragraphStyle(_ text: NSAttributedString, at needle: String) -> NSParagraphStyle? {
        guard let location = index(of: needle, in: text) else { return nil }
        return text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
    }

    private func isBold(_ font: NSFont?) -> Bool {
        font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
    }

    /// Italic either as a real face trait or as AppKit's synthetic
    /// obliqueness, which the renderer uses when the family has no italic face
    /// (PingFang SC).
    private func isItalic(_ text: NSAttributedString, at needle: String) -> Bool {
        guard let location = index(of: needle, in: text) else { return false }
        if let font = text.attribute(.font, at: location, effectiveRange: nil) as? NSFont,
           font.fontDescriptor.symbolicTraits.contains(.italic) {
            return true
        }
        return (text.attribute(.obliqueness, at: location, effectiveRange: nil) as? CGFloat ?? 0) > 0
    }

    // MARK: - Blocks

    func testHeadingsScaleWithLevelAndStayBold() {
        let output = render("# One\n\n### Three\n\nbody")
        let h1 = font(output, at: "One")
        let h3 = font(output, at: "Three")
        let body = font(output, at: "body")

        XCTAssertNotNil(h1)
        XCTAssertTrue(isBold(h1), "headings are bold")
        XCTAssertTrue(isBold(h3))
        XCTAssertGreaterThan(h1!.pointSize, h3!.pointSize, "h1 is larger than h3")
        XCTAssertGreaterThan(h3!.pointSize, body!.pointSize, "h3 is larger than body text")
        XCTAssertFalse(output.string.contains("#"), "the ATX markers are consumed")
    }

    func testParagraphsAreSeparatedAndPlainTextSurvives() {
        let output = render("first paragraph\n\nsecond paragraph")
        XCTAssertEqual(output.string, "first paragraph\nsecond paragraph")
    }

    func testSoftAndHardBreaksBecomeNewlines() {
        let output = render("soft\nbreak\n\nhard  \nbreak")
        XCTAssertTrue(output.string.contains("soft\nbreak"), "a soft break keeps its line")
        XCTAssertTrue(output.string.contains("hard\nbreak"), "two trailing spaces are a hard break")
    }

    func testBlockQuoteGetsABarOnEveryLine() {
        let output = render("> quoted line\n> second line")
        XCTAssertTrue(output.string.contains("▎ quoted line"))
        XCTAssertTrue(output.string.contains("▎ second line"), "soft-wrapped quote lines keep the bar")
        let quote = paragraphStyle(output, at: "quoted")
        XCTAssertGreaterThan(quote?.firstLineHeadIndent ?? 0, 0, "quotes are indented")
    }

    func testFencedCodeBlockIsMonospacedAndTrimmed() {
        let output = render("```swift\nlet x = 1\n```")
        let codeFont = font(output, at: "let x = 1")
        XCTAssertEqual(codeFont?.isFixedPitch, true, "code uses a monospaced face")
        XCTAssertEqual(output.string.trimmingCharacters(in: .whitespacesAndNewlines), "let x = 1",
                       "fences and the trailing newline are consumed")
        let location = index(of: "let x = 1", in: output)!
        XCTAssertNotNil(output.attribute(.backgroundColor, at: location, effectiveRange: nil))
    }

    func testThematicBreakRendersARule() {
        let output = render("before\n\n---\n\nafter")
        XCTAssertTrue(output.string.contains("─"), "a rule line replaces ---")
        XCTAssertFalse(output.string.contains("---"))
    }

    func testTableUsesSharedGridAndBoldsHeader() {
        let output = render("""
        | name | value |
        |------|-------|
        | a    | 1     |
        """)
        XCTAssertTrue(output.string.contains("name\nvalue"))
        XCTAssertTrue(output.string.contains("a\n1"))
        XCTAssertTrue(isBold(font(output, at: "name")))
        XCTAssertFalse(isBold(font(output, at: "a\n1")), "body rows stay regular")
        let header = paragraphStyle(output, at: "name")?.textBlocks.first as? NSTextTableBlock
        let body = paragraphStyle(output, at: "a\n1")?.textBlocks.first as? NSTextTableBlock
        XCTAssertNotNil(header)
        XCTAssertTrue(header?.table === body?.table)
        XCTAssertEqual(body?.startingRow, 1)
    }

    // MARK: - Inline

    func testInlineEmphasisCodeAndStrikethrough() {
        let output = render("plain **bold** *italic* ***both*** `code` ~~gone~~")
        XCTAssertTrue(isBold(font(output, at: "bold")))
        XCTAssertTrue(isItalic(output, at: "italic"))
        XCTAssertTrue(isBold(font(output, at: "both")) && isItalic(output, at: "both"))
        XCTAssertFalse(isBold(font(output, at: "plain")))
        XCTAssertEqual(font(output, at: "code")?.isFixedPitch, true)
        let strikethrough = index(of: "gone", in: output)!
        XCTAssertNotNil(output.attribute(.strikethroughStyle, at: strikethrough, effectiveRange: nil))
        XCTAssertFalse(output.string.contains("**"))
        XCTAssertFalse(output.string.contains("`"))
    }

    func testLinksKeepTheirURL() {
        let output = render("see [Pinboard](https://pinboard.in) now")
        let location = index(of: "Pinboard", in: output)!
        XCTAssertEqual(output.attribute(.link, at: location, effectiveRange: nil) as? String,
                       "https://pinboard.in")
        XCTAssertNotNil(output.attribute(.underlineStyle, at: location, effectiveRange: nil))
    }

    // MARK: - Lists

    func testUnorderedAndOrderedListsGetMarkers() throws {
        let output = render("- apple\n- banana\n\n1. first\n2. second")
        XCTAssertTrue(output.string.contains("• apple"))
        XCTAssertTrue(output.string.contains("• banana"))
        XCTAssertTrue(output.string.contains("1. first"))
        XCTAssertTrue(output.string.contains("2. second"))

        let bullet = try XCTUnwrap(paragraphStyle(output, at: "apple"))
        XCTAssertEqual(bullet.firstLineHeadIndent, 18, accuracy: 0.5)
        XCTAssertGreaterThan(bullet.headIndent, bullet.firstLineHeadIndent,
                             "wrapped lines hang past the marker")

        let number = try XCTUnwrap(paragraphStyle(output, at: "first"))
        XCTAssertEqual(number.firstLineHeadIndent, 18, accuracy: 0.5)
    }

    func testNestedListsIndentDeeperAndKeepTheirMarkers() throws {
        let output = render("- outer\n    - inner")
        XCTAssertTrue(output.string.contains("• outer"))
        XCTAssertTrue(output.string.contains("• inner"), "nested items keep a marker")
        let outer = try XCTUnwrap(paragraphStyle(output, at: "outer"))
        let inner = try XCTUnwrap(paragraphStyle(output, at: "inner"))
        XCTAssertEqual(outer.firstLineHeadIndent, 18, accuracy: 0.5)
        XCTAssertEqual(inner.firstLineHeadIndent, 36, accuracy: 0.5, "one indent step per nesting level")
    }

    func testOrderedListContinuesInsideOneItem() {
        let output = render("1. first paragraph\n\n   second paragraph of the same item\n2. next")
        XCTAssertTrue(output.string.contains("1. first paragraph"))
        XCTAssertFalse(output.string.contains("1. second paragraph of the same item"),
                       "only the first paragraph of an item gets the number")
        XCTAssertTrue(output.string.contains("2. next"))
    }

    func testTaskListItemsRenderCheckboxes() {
        let output = render("- [ ] todo\n- [x] done")
        XCTAssertTrue(output.string.contains("☐ todo"))
        XCTAssertTrue(output.string.contains("☑ done"))
        let todo = index(of: "todo", in: output)!
        let done = index(of: "done", in: output)!
        XCTAssertNil(output.attribute(.strikethroughStyle, at: todo, effectiveRange: nil))
        XCTAssertNotNil(output.attribute(.strikethroughStyle, at: done, effectiveRange: nil),
                        "checked items are struck through")
    }

    // MARK: - Robustness

    func testMalformedMarkdownStillShowsItsText() {
        let output = render("**unclosed emphasis\n\n[broken](link")
        XCTAssertTrue(output.string.contains("**unclosed emphasis"))
        XCTAssertTrue(output.string.contains("[broken](link"))
    }

    func testEmptySourceRendersEmpty() {
        XCTAssertEqual(render("").length, 0)
    }

    func testPlainTextPassesThroughUnchanged() {
        let output = render("just some words")
        XCTAssertEqual(output.string, "just some words")
        let font = font(output, at: "just")
        XCTAssertEqual(font?.pointSize, style.baseFont.pointSize)
        XCTAssertFalse(isBold(font))
    }
}
