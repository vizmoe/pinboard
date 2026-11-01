import AppKit
import XCTest
@testable import PinboardKit

/// Representative GFM extension cases, not a claim of full HTML conformance.
final class GFMCompatibilityTests: XCTestCase {
    func testAutolinksAndTrailingPunctuation() {
        let output = MarkdownRenderer.render("Visit www.example.com, https://example.com/a. Email a@example.com.")
        var links: [String] = []
        output.enumerateAttribute(.link, in: output.fullRange) { value, _, _ in
            if let value = value as? String { links.append(value) }
        }
        XCTAssertEqual(links, ["http://www.example.com", "https://example.com/a", "mailto:a@example.com"])
    }

    func testTaskMarkersRespectSyntaxInsteadOfRenderedText() {
        let output = MarkdownRenderer.render("- [X] checked\n- [ ]\ttab\n- ` [x] literal `\n- \\[x] escaped")
        XCTAssertTrue(output.string.contains("☑ checked"))
        XCTAssertTrue(output.string.contains("☐ tab"))
        XCTAssertTrue(output.string.contains("[x] literal"))
        XCTAssertTrue(output.string.contains("[x] escaped"))
        XCTAssertEqual(output.string.filter { $0 == "☑" }.count, 1)
    }

    func testTableAlignmentAndEmptyCellsArePreserved() throws {
        let output = MarkdownRenderer.render("| left | center | right |\n| :--- | :---: | ---: |\n| a | | 123 |")
        let location = (output.string as NSString).range(of: "123").location
        let style = try XCTUnwrap(output.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.alignment, .right)
        let block = try XCTUnwrap(style.textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(block.startingColumn, 2)
        XCTAssertEqual(block.table.numberOfColumns, 3)
    }

    func testRawHTMLIsLiteralAndNeverCreatesImages() {
        let source = "<script>alert(1)</script>\n\n<img src='http://127.0.0.1/secret'>"
        let output = MarkdownRenderer.render(source)
        XCTAssertTrue(output.string.contains("<script>"))
        XCTAssertTrue(output.string.contains("<img"))
        output.enumerateAttribute(.attachment, in: output.fullRange) { value, _, _ in XCTAssertNil(value) }
    }

    func testNestedQuoteRetainsListAndHeading() {
        let output = MarkdownRenderer.render("> # Title\n>\n> - item\n>   - nested")
        XCTAssertTrue(output.string.contains("▎ Title"))
        XCTAssertTrue(output.string.contains("▎ • item"))
        XCTAssertTrue(output.string.contains("▎ • nested"))
    }
}
