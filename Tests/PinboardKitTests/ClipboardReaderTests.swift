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

    func testUnsupportedContentReturnsNil() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([NSPasteboard.PasteboardType("com.example.unknown")], owner: nil)
        pasteboard.setData(Data([0x00, 0x01]), forType: NSPasteboard.PasteboardType("com.example.unknown"))
        XCTAssertNil(ClipboardReader.read(from: pasteboard))
    }

    func testEmptyPasteboardReturnsNil() {
        XCTAssertNil(ClipboardReader.read(from: makePasteboard()))
    }
}
