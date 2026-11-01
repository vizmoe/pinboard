import AppKit
import XCTest
@testable import PinboardKit

/// Markdown images: `![alt](url)` renders as a real picture, is fetched and
/// sized like any other deferred image, and never touches the source.
final class MarkdownImageTests: XCTestCase {
    private var manager: PinWindowManager { PinWindowManager.shared }
    private var loader: StubImageLoader!
    private var png: Data!

    private final class StubImageLoader: RemoteImageFetching {
        var requested: [URL] = []
        var data: Data?
        func fetch(_ url: URL, completion: @escaping (Data?) -> Void) {
            requested.append(url)
            completion(data)
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        png = try XCTUnwrap(HTMLImageSourceTests.makePNG(width: 400, height: 200, color: .systemTeal))
        loader = StubImageLoader()
        loader.data = png
        manager.remoteImageLoader = loader
    }

    override func tearDown() {
        manager.closeAll()
        manager.remoteImageLoader = RemoteImageLoader.shared
        manager.historyStore = nil
        Preferences.shared.textMode = .richText
        super.tearDown()
    }

    private var dataURI: String { "data:image/png;base64,\(png!.base64EncodedString())" }

    private func makeView(_ source: String) throws -> (PinWindowController, TextPinView) {
        let pin = manager.createPin(content: .text(NSAttributedString(string: source)), textMode: .markdown)
        let view = try XCTUnwrap(pin.contentView as? TextPinView)
        return (pin, view)
    }

    private func displayedAttachment(of view: TextPinView) throws -> NSTextAttachment {
        let storage = try XCTUnwrap(view.editableTextView.textStorage)
        var found: NSTextAttachment?
        storage.enumerateAttribute(.attachment, in: storage.fullRange, options: []) { value, _, _ in
            if let attachment = value as? NSTextAttachment { found = attachment }
        }
        return try XCTUnwrap(found)
    }

    private func displayedText(of view: TextPinView) -> String {
        view.editableTextView.string
    }

    // MARK: - Rendering

    func testImageRendersAsATaggedPlaceholder() {
        let rendered = MarkdownRenderer.render("before ![chart](https://example.com/c.png) after")

        XCTAssertEqual(rendered.string, "before \u{FFFC} after", "the syntax gives way to a picture slot")
        let index = 7
        XCTAssertTrue(rendered.attribute(.attachment, at: index, effectiveRange: nil) is NSTextAttachment)
        XCTAssertEqual(rendered.attribute(DeferredImages.sourceAttribute, at: index, effectiveRange: nil) as? String,
                       "https://example.com/c.png")
        XCTAssertEqual(rendered.attribute(DeferredImages.altAttribute, at: index, effectiveRange: nil) as? String,
                       "chart")
    }

    func testEmptyAltHasNoFallbackText() {
        let rendered = MarkdownRenderer.render("![](https://example.com/c.png)")

        XCTAssertEqual(rendered.string, "\u{FFFC}")
        XCTAssertNil(rendered.attribute(DeferredImages.altAttribute, at: 0, effectiveRange: nil))
    }

    func testImagesInsideBlocksAndDataURIsAreFound() {
        let rendered = MarkdownRenderer.render("""
        - item ![one](https://example.com/1.png)
        - item ![two](data:image/png;base64,AAAA)

        > quoted ![three](https://example.com/3.png)
        """)
        var sources: [String] = []
        rendered.enumerateAttribute(DeferredImages.sourceAttribute, in: rendered.fullRange, options: []) { value, _, _ in
            if let source = value as? String { sources.append(source) }
        }
        XCTAssertEqual(sources, [
            "https://example.com/1.png",
            "data:image/png;base64,AAAA",
            "https://example.com/3.png"
        ])
    }

    func testPlainLinksStayLinks() {
        let rendered = MarkdownRenderer.render("[docs](https://example.com/docs)")

        XCTAssertEqual(rendered.string, "docs")
        XCTAssertEqual(rendered.attribute(.link, at: 0, effectiveRange: nil) as? String,
                       "https://example.com/docs")
    }

    func testLinkedImagesKeepBothImageAndLinkDestinations() {
        let rendered = MarkdownRenderer.render("[![badge](https://example.com/b.png)](https://example.com/target)")

        XCTAssertEqual(rendered.string, "\u{FFFC}")
        XCTAssertEqual(rendered.attribute(DeferredImages.sourceAttribute, at: 0, effectiveRange: nil) as? String,
                       "https://example.com/b.png")
        XCTAssertEqual(rendered.attribute(.link, at: 0, effectiveRange: nil) as? String,
                       "https://example.com/target")
    }

    // MARK: - Pins

    func testLocalImageIsInstalledAndScaledToTheWrapWidth() throws {
        let (_, view) = try makeView("chart:\n\n![chart](\(dataURI))")

        let attachment = try displayedAttachment(of: view)
        XCTAssertEqual(attachment.image?.size, NSSize(width: 400, height: 200))
        XCTAssertLessThanOrEqual(attachment.bounds.width, view.textWrapWidth + 2, "fitted to the pin")
        XCTAssertEqual(attachment.bounds.height, attachment.bounds.width / 2, accuracy: 1, "aspect ratio kept")
        XCTAssertTrue(loader.requested.isEmpty, "a data URI needs no network")
    }

    func testRemoteImageIsFetched() throws {
        let (_, view) = try makeView("![chart](https://cdn.example.com/chart.png)")

        XCTAssertEqual(loader.requested.map(\.absoluteString), ["https://cdn.example.com/chart.png"])
        XCTAssertEqual(try displayedAttachment(of: view).image?.size, NSSize(width: 400, height: 200))
        XCTAssertFalse(displayedText(of: view).contains("chart"), "the alt text gave way to the picture")
    }

    func testUnloadableImagesFallBackToTheirAltText() throws {
        loader.data = nil
        let (_, view) = try makeView("before ![chart](https://cdn.example.com/gone.png) after")

        XCTAssertEqual(loader.requested.count, 1, "the fetch was attempted")
        XCTAssertEqual(displayedText(of: view), "before chart after", "the alt text stands in")
        var attachments = 0
        let storage = try XCTUnwrap(view.editableTextView.textStorage)
        storage.enumerateAttribute(.attachment, in: storage.fullRange, options: []) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        XCTAssertEqual(attachments, 0, "the empty placeholder is gone")
    }

    func testBytesThatAreNotAnImageFallBackToTheirAltText() throws {
        loader.data = Data("not a picture".utf8)
        let (_, view) = try makeView("![chart](https://cdn.example.com/broken.png)")

        XCTAssertEqual(displayedText(of: view), "chart")
    }

    func testRelativeURLsFallBackWithoutFetching() throws {
        let (_, view) = try makeView("![local](pictures/chart.png)")

        XCTAssertTrue(loader.requested.isEmpty, "a relative URL cannot be loaded")
        XCTAssertEqual(displayedText(of: view), "local")
    }

    func testSourceStaysUntouchedAndCanonical() throws {
        let source = "# Charts\n\n![chart](\(dataURI))"
        let (_, view) = try makeView(source)

        guard case .text(let canonical) = view.currentContent() else {
            return XCTFail("expected text content")
        }
        XCTAssertEqual(canonical.string, source, "the markdown syntax is the content, the picture is only display")
        XCTAssertFalse(canonical.string.contains("\u{FFFC}"))
    }

    func testEndingAnEditResolvesImagesAddedToTheSource() throws {
        let (_, view) = try makeView("no pictures yet")

        view.beginEditing(at: nil)
        let editor = view.editableTextView
        editor.insertText("\n![chart](\(dataURI))",
                          replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        view.endEditing()

        XCTAssertEqual(try displayedAttachment(of: view).image?.size, NSSize(width: 400, height: 200),
                       "the re-rendered display resolves the new image")
    }

    func testSwitchingToRichTextKeepsTheImage() throws {
        let (_, view) = try makeView("![chart](\(dataURI))")

        view.setTextMode(.richText, explicit: true)

        guard case .text(let rich) = view.currentContent() else {
            return XCTFail("expected text content")
        }
        var image: NSImage?
        rich.enumerateAttribute(.attachment, in: rich.fullRange, options: []) { value, _, _ in
            image = (value as? NSTextAttachment)?.image
        }
        XCTAssertEqual(image?.size, NSSize(width: 400, height: 200),
                       "a rendered Markdown document carries its pictures into rich text")
    }

    func testPinGrowsToFitTheArrivingImage() throws {
        let text = "IWM: 274P: Entry on a LAAF of today's high rejecting 275.5, looking for the gap fill to 276.75 after trims."

        // Same source text, one chart that loads and one that cannot: the
        // window has to make room for the picture, not just for its slot.
        loader.data = nil
        let (broken, _) = try makeView("\(text)\n\n![chart](https://cdn.example.com/gone.png)")

        loader.data = png
        let (pin, _) = try makeView("\(text)\n\n![chart](https://cdn.example.com/tall.png)")

        let chart = try displayedAttachment(of: try XCTUnwrap(pin.contentView as? TextPinView))
        XCTAssertGreaterThan(chart.bounds.height, 100, "the chart is scaled to the pin, not to a thumbnail")
        XCTAssertGreaterThan(pin.panel.frame.height, broken.panel.frame.height + 150,
                             "the window grew so the chart is fully visible")
    }

    func testHistoryKeepsTheSourceNotTheRenderedImage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        manager.historyStore = HistoryStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = "![chart](\(dataURI))"
        let (pin, _) = try makeView(source)
        let recordID = try XCTUnwrap(pin.historyRecordID)
        manager.flushHistorySync(for: pin)

        let reloaded = HistoryStore(directory: directory)
        let entry = try XCTUnwrap(reloaded.entry(id: recordID))
        guard case .text(let stored) = entry.content else {
            return XCTFail("expected text record")
        }
        XCTAssertEqual(stored.string, source, "re-pinning renders the source again")
        var attachments = 0
        stored.enumerateAttribute(.attachment, in: stored.fullRange, options: []) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        XCTAssertEqual(attachments, 0, "no picture bytes are baked into the record")
    }
}

/// The loader's own behaviour: status handling, the size cap and the session
/// cache that keeps a re-render from hitting the network twice.
final class RemoteImageLoaderTests: XCTestCase {
    private final class Downloads {
        var requests: [URL] = []
        var fails = false
        var payload = Data()
        func download(_ url: URL, limit: Int) throws -> Data {
            requests.append(url)
            if fails { throw RemoteImageLoader.DownloadError(code: 22) }
            return payload
        }
    }
    private var downloads: Downloads!

    private var loader: RemoteImageLoader!
    private var png: Data!

    override func setUpWithError() throws {
        try super.setUpWithError()
        png = try XCTUnwrap(HTMLImageSourceTests.makePNG(width: 24, height: 12, color: .systemPink))
        downloads = Downloads()
        downloads.payload = png
        loader = RemoteImageLoader(download: downloads.download)
    }

    private func fetch(_ url: URL) throws -> Data? {
        var result: Data?
        var done = false
        let expectation = expectation(description: url.absoluteString)
        loader.fetch(url) {
            result = $0
            done = true
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertTrue(done)
        return result
    }

    func testSuccessfulDownloadsAreCached() throws {
        let url = URL(string: "https://cdn.example.com/chart.png")!
        XCTAssertEqual(try fetch(url), png)
        XCTAssertEqual(try fetch(url), png)
        XCTAssertEqual(downloads.requests, [url], "the second fetch never left the app")
    }

    func testFailedStatusReturnsNil() throws {
        downloads.fails = true
        XCTAssertNil(try fetch(URL(string: "https://cdn.example.com/missing.png")!))
    }

    func testOversizedPayloadsAreDiscarded() throws {
        let small = RemoteImageLoader(maximumBytes: 4, download: downloads.download)
        var result: Data? = Data("sentinel".utf8)
        let expectation = expectation(description: "oversized")
        small.fetch(URL(string: "https://cdn.example.com/huge.png")!) {
            result = $0
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertNil(result)
    }
}
