import AppKit
import XCTest
@testable import PinboardKit

final class ClipboardReaderTests: XCTestCase {
    private func makePasteboard(_ name: String = UUID().uuidString) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        pasteboard.clearContents()
        return pasteboard
    }

    private func rtfData(_ string: String, color: NSColor = .systemRed) -> Data {
        let attributed = NSAttributedString(string: string, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 18),
            .foregroundColor: color
        ])
        return attributed.rtfRepresentation()!
    }

    func testRichTextWinsOverImagePreview() throws {
        // Word and Pages put a bitmap preview of the selection next to the RTF.
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.rtf, .tiff, .string], owner: nil)
        pasteboard.setData(rtfData("格式化文本"), forType: .rtf)
        pasteboard.setData(NSImage(size: NSSize(width: 10, height: 10)).tiffRepresentation, forType: .tiff)
        pasteboard.setString("格式化文本", forType: .string)

        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected rich text")
        }
        XCTAssertEqual(text.string, "格式化文本")
        let color = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color?.usingColorSpace(.sRGB)?.redComponent ?? 0, 1, accuracy: 0.15)
    }

    func testImageWinsOverPlainTextAndHTML() throws {
        let image = TestImage.make(width: 24, height: 12, color: .systemBlue)
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.tiff, .html, .string], owner: nil)
        pasteboard.setData(image.tiffRepresentation, forType: .tiff)
        pasteboard.setString("<img src=\"x\">", forType: .html)
        pasteboard.setString("https://example.com/x.png", forType: .string)

        guard case .image(let result)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected image")
        }
        XCTAssertEqual(result.pixelSize.width, 24, accuracy: 0.5)
    }

    func testHTMLFallsBackToRichText() throws {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setString("<b>粗体</b>网页文本", forType: .html)
        pasteboard.setString("粗体网页文本", forType: .string)

        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(text.string, "粗体网页文本")
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    /// Chat apps (Discord & co.) ship `public.html` whose message text holds
    /// raw newlines inside normal-flow markup relying on `white-space:
    /// pre-wrap`. The importer ignores that CSS and collapses the breaks to
    /// spaces; the plain-text flavour keeps them. The reader must splice the
    /// plain text's whitespace back into the rich result.
    func testHTMLImportRestoresPlainTextLineBreaks() throws {
        let html = "<div class=\"markup\"><span style=\"color:#fff\">Hello <b>world</b>\nnext line\n\nthird line</span></div>"
        let plain = "Hello world\nnext line\n\nthird line"
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setString(html, forType: .html)
        pasteboard.setString(plain, forType: .string)

        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(text.string, plain, "line breaks from the plain-text flavour must survive")
        // Formatting from HTML is preserved: "world" stays bold.
        let world = (text.string as NSString).range(of: "world")
        let font = text.attribute(.font, at: world.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    /// An unrelated stale plain-text flavour must not corrupt the import.
    func testHTMLImportKeepsRichWhenPlainTextDiffers() throws {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setString("<div>alpha</div><div>beta</div>", forType: .html)
        pasteboard.setString("completely different clipboard text", forType: .string)

        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(text.string, "alpha\nbeta\n")
    }

    func testPlainTextOnly() throws {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("纯文本", forType: .string)

        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(text.string, "纯文本")
    }

    func testHTMLRestoresWhitespaceAroundSupplementaryUnicodeAndKeepsFormatting() throws {
        let pasteboard = makePasteboard()
        let plain = "  👩🏽‍💻\t𠮷野\n\n🇨🇳 cafe\u{301}  "
        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setString("<b>👩🏽‍💻</b> 𠮷野 🇨🇳 cafe\u{301}", forType: .html)
        pasteboard.setString(plain, forType: .string)

        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected rich text")
        }
        XCTAssertEqual(text.string, plain)
        let emoji = (text.string as NSString).range(of: "👩🏽‍💻")
        let font = text.attribute(.font, at: emoji.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func testHTMLWithEmojiIgnoresUnrelatedPlainText() throws {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setString("<b>😀 rich</b>", forType: .html)
        pasteboard.setString("😀 unrelated", forType: .string)

        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected rich text")
        }
        XCTAssertEqual(text.string, "😀 rich")
    }

    func testUnsupportedContentReturnsNil() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([NSPasteboard.PasteboardType("com.example.unknown")], owner: nil)
        pasteboard.setData(Data([0x00, 0x01]), forType: NSPasteboard.PasteboardType("com.example.unknown"))
        XCTAssertNil(ClipboardReader.read(from: pasteboard))
    }

    func testEmptyPasteboardReturnsNil() {
        XCTAssertNil(ClipboardReader.read(from: makePasteboard()))
    }

    func testWebHTMLNormalizesHangingIndentsSerifItalicsContainerBackgroundAndCSSVariables() throws {
        let html = """
        <p style="margin-left: 92px; margin-right: 92px; text-indent: 0px; font-family: ui-serif, Georgia, serif; font-size: 19px; font-style: italic; color: rgb(238, 238, 238); background-color: rgb(17, 18, 19); -webkit-text-stroke-color: rgb(238, 238, 238);">
            Elevator Down, Failed Breakdown, Short Squeeze. <strong>It applies in uptrends and downtrends.</strong>
        </p>
        <p style="margin-left: 92px; margin-right: 92px; text-indent: 0px; font-family: sans-serif; font-size: 19px; font-style: italic; color: var(--immersive-translate-theme, #20a162); background-color: rgb(17, 18, 19);">
            电梯式下跌、失败下破、逼空。它适用于上升趋势和下降趋势。
        </p>
        """
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.html], owner: nil)
        pasteboard.setString(html, forType: .html)

        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected rich text")
        }

        let nsString = text.string as NSString
        let englishRange = nsString.range(of: "Elevator Down")
        let boldEnglishRange = nsString.range(of: "It applies")
        let chineseRange = nsString.range(of: "电梯式下跌")

        // 1. Hanging indent and fixed right indent from container margins are cleared.
        let paragraph = try XCTUnwrap(text.attribute(.paragraphStyle, at: englishRange.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.headIndent, 0)
        XCTAssertEqual(paragraph.firstLineHeadIndent, 0)
        XCTAssertEqual(paragraph.tailIndent, 0)

        // 2. Serif italic and bold-italic are preserved on English runs.
        let englishFont = try XCTUnwrap(text.attribute(.font, at: englishRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(englishFont.fontDescriptor.symbolicTraits.contains(.italic))
        let boldEnglishFont = try XCTUnwrap(text.attribute(.font, at: boldEnglishRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(boldEnglishFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(boldEnglishFont.fontDescriptor.symbolicTraits.contains(.italic))

        // 3. Chinese italic text receives obliqueness because PingFang SC has no italic face.
        let chineseObliqueness = text.attribute(.obliqueness, at: chineseRange.location, effectiveRange: nil) as? CGFloat
        XCTAssertGreaterThan(chineseObliqueness ?? 0, 0.1, "CJK italic text must slant via obliqueness")

        // 4. Container dark background is stripped; neutral white text becomes labelColor;
        //    translated text keeps its CSS var() fallback green colour.
        XCTAssertNil(text.attribute(.backgroundColor, at: englishRange.location, effectiveRange: nil))
        XCTAssertEqual(text.attribute(.foregroundColor, at: englishRange.location, effectiveRange: nil) as? NSColor, .labelColor)
        let chineseColor = try XCTUnwrap(
            (text.attribute(.foregroundColor, at: chineseRange.location, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
        )
        XCTAssertGreaterThan(chineseColor.greenComponent, chineseColor.redComponent + 0.2,
                             "CSS var() fallback colour for translated text must survive")
    }

    func testHTMLStyleRewritesNeverTouchVisibleText() throws {
        let visible = "Use margin-left: 92px; text-indent: 0px with var(--accent, red) and ui-serif."
        let html = "<p style=\"margin-left: 92px; font-family: ui-serif\">\(visible)</p>"
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.html], owner: nil)
        pasteboard.setString(html, forType: .html)

        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected rich text")
        }
        XCTAssertEqual(text.string.trimmingCharacters(in: .whitespacesAndNewlines), visible)
        let paragraph = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(paragraph?.headIndent ?? 0, 0, "the inline container margin is still stripped")
    }

    func testNativeRTFKeepsIntentionalHangingIndent() throws {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent = 36
        let source = NSAttributedString(string: "Author, A. A Long Reference Title That Wraps.", attributes: [
            .font: NSFont(name: "Helvetica", size: 13)!,
            .paragraphStyle: paragraph
        ])
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.rtf], owner: nil)
        pasteboard.setData(source.rtfRepresentation()!, forType: .rtf)

        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected rich text")
        }
        let imported = try XCTUnwrap(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(imported.headIndent, 36, "bibliography-style hanging indents from native apps survive")
    }

    func testHTMLListItemsWithNestedDivAndParagraphWrappersDoNotEmitExtraBlankLineSeparators() throws {
        let html = """
        <meta charset='utf-8'><h2>二、从算法角度，自动切分其实有三个独立决策</h2><h3>1. 选择切分区域（Where to split）</h3><p>新窗口出现时，应该切分哪一块区域？</p><ul><li><div><div><p><span>Focused</span>：切分当前焦点窗口所在区域。</p></div></div></li><li><div><div><p><span>Largest</span>：切分面积最大的窗口区域。</p></div></div></li></ul>
        """
        let plain = """
        二、从算法角度，自动切分其实有三个独立决策
        1. 选择切分区域（Where to split）
        新窗口出现时，应该切分哪一块区域？
        - Focused：切分当前焦点窗口所在区域。
        - Largest：切分面积最大的窗口区域。
        """
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setString(html, forType: .html)
        pasteboard.setString(plain, forType: .string)

        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected rich text")
        }
        XCTAssertFalse(text.string.contains("\u{2028}"),
                       "nested <div>/<p> wrappers inside <li> must not leave trailing U+2028 blank lines")
        XCTAssertFalse(text.string.hasSuffix("\n"),
                       "synthetic trailing block newline from </ul> must be trimmed when plain counterpart has none")
        XCTAssertEqual(text.string.components(separatedBy: "\n").count, 5)
    }
}
