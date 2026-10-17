import AppKit
import XCTest
@testable import PinboardKit

/// HTML image sources: parsing, data URIs and local files.
final class HTMLImageSourceTests: XCTestCase {
    func testDiscordStyleSourcesAreDecodedInDocumentOrder() throws {
        let html = """
        <meta charset='utf-8'><div>notes</div>
        <img src="https://cdn.discordapp.com/attachments/1/2/chart.png?ex=1&amp;is=2&amp;hm=3" alt="Image">
        <img class="x" src='https://cdn.discordapp.com/attachments/1/3/second.png' width=100>
        """
        let sources = HTMLImages.sources(in: Data(html.utf8))
        XCTAssertEqual(sources as [String?], [
            "https://cdn.discordapp.com/attachments/1/2/chart.png?ex=1&is=2&hm=3",
            "https://cdn.discordapp.com/attachments/1/3/second.png"
        ])
    }

    /// Discord ships its blurred loading placeholder as a second, hidden
    /// `<img>`; resolving it would leave a stray strip under the real chart.
    func testHiddenImagesBecomeNilEntriesInPlace() {
        let html = """
        <img src="https://example.com/chart.png">
        <img class="imagePlaceholder" alt="" src="data:image/png;base64,AAAA" style="display: block; position: absolute; opacity: 0;">
        <img src="https://example.com/after.png">
        """
        XCTAssertEqual(HTMLImages.sources(in: Data(html.utf8)) as [String?], [
            "https://example.com/chart.png",
            nil,
            "https://example.com/after.png"
        ])
    }

    func testInvisibleStyleVariantsAndOpacity() {
        XCTAssertTrue(HTMLImages.isInvisible("<img style=\"display: none\">"))
        XCTAssertTrue(HTMLImages.isInvisible("<img style='display:none;'>"))
        XCTAssertTrue(HTMLImages.isInvisible("<img style=\"visibility: hidden\">"))
        XCTAssertTrue(HTMLImages.isInvisible("<img style=\"opacity: 0\">"))
        XCTAssertTrue(HTMLImages.isInvisible("<img style=\"opacity: 0.0;\">"))
        XCTAssertTrue(HTMLImages.isInvisible("<img style=\"opacity: .00;\">"))
        XCTAssertFalse(HTMLImages.isInvisible("<img style=\"opacity: 0.5\">"))
        XCTAssertFalse(HTMLImages.isInvisible("<img style=\"opacity: 1\">"))
        XCTAssertFalse(HTMLImages.isInvisible("<img src=\"a.png\">"))
    }

    func testUnquotedSourcesAndMissingImages() {
        XCTAssertEqual(HTMLImages.sources(in: Data("<img src=https://example.com/a.png>".utf8)) as [String?],
                       ["https://example.com/a.png"])
        XCTAssertEqual(HTMLImages.sources(in: Data("<p>no images here</p>".utf8)) as [String?], [])
        XCTAssertEqual(HTMLImages.sources(in: Data("<img alt=\"Image\">".utf8)) as [String?], [])
    }

    func testDataURIDecodesImageBytes() throws {
        let png = try XCTUnwrap(Self.makePNG(width: 20, height: 10, color: .orange))
        let source = "data:image/png;base64,\(png.base64EncodedString())"
        XCTAssertEqual(DeferredImages.dataURI(source), png)
        XCTAssertEqual(DeferredImages.localData(from: source), png)
    }

    func testDataURINonImageAndPlainPayload() {
        XCTAssertNil(DeferredImages.dataURI("data:text/plain;base64,\(Data("hi".utf8).base64EncodedString())"))
        XCTAssertEqual(DeferredImages.dataURI("data:image/svg+xml,%3Csvg/%3E"), Data("<svg/>".utf8))
        XCTAssertNil(DeferredImages.dataURI("data:image/png;base64"))
    }

    func testLocalDataReadsFilesButNotRemoteURLs() throws {
        let png = try XCTUnwrap(Self.makePNG(width: 20, height: 10, color: .green))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(DeferredImages.localData(from: url.absoluteString), png)
        XCTAssertNil(DeferredImages.localData(from: "https://example.com/chart.png"))
    }

    func testLoaderRefusesNonWebSchemes() {
        let loader = RemoteImageLoader()
        var result: Data? = Data("sentinel".utf8)
        loader.fetch(URL(fileURLWithPath: "/tmp/chart.png")) { result = $0 }
        XCTAssertNil(result, "only http(s) is ever fetched")
    }

    /// A tiny valid PNG.
    static func makePNG(width: CGFloat, height: CGFloat, color: NSColor) -> Data? {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image.tiffRepresentation
            .flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .png, properties: [:])
    }
}

/// Pasted HTML whose image is only a reference: the pin resolves it.
final class HTMLImagePinTests: XCTestCase {
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
        png = try XCTUnwrap(HTMLImageSourceTests.makePNG(width: 400, height: 200, color: .systemBlue))
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

    /// A pasteboard shaped like Discord's copy of a message whose chart is an
    /// `<img>`: the plain-text flavour carries the alt word, no image bytes.
    private func discordStylePasteboard(imageSource: String) -> NSPasteboard {
        let id = UUID().uuidString
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pinboard.html.\(id)"))
        pasteboard.clearContents()
        let html = """
        <meta charset='utf-8'><div>IWM:</div><div>274P: Entry on a LAAF</div><img src="\(imageSource)" alt="Image">
        """
        pasteboard.setData(Data(html.utf8), forType: .html)
        pasteboard.setString("IWM:\n274P: Entry on a LAAF\nImage", forType: .string)
        return pasteboard
    }

    private func attachment(of view: TextPinView, at index: Int = 0) throws -> NSTextAttachment {
        let storage = try XCTUnwrap(view.editableTextView.textStorage)
        var matches: [NSTextAttachment] = []
        storage.enumerateAttribute(.attachment, in: storage.fullRange, options: []) { value, _, _ in
            if let attachment = value as? NSTextAttachment { matches.append(attachment) }
        }
        return try XCTUnwrap(matches.dropFirst(index).first)
    }

    func testReaderTagsThePlaceholderWithItsSource() throws {
        let source = "data:image/png;base64,\(png.base64EncodedString())"
        let pasteboard = discordStylePasteboard(imageSource: source)

        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected text content")
        }
        var tagged: String?
        text.enumerateAttribute(DeferredImages.sourceAttribute, in: text.fullRange, options: []) { value, range, _ in
            guard value != nil else { return }
            XCTAssertTrue(text.attribute(.attachment, at: range.location, effectiveRange: nil) is NSTextAttachment)
            tagged = value as? String
        }
        XCTAssertEqual(tagged, source, "the placeholder carries its image source")
        XCTAssertTrue(text.string.contains("IWM:"))
    }

    func testDataURIOrFileImagesAreInstalledWithoutFetching() throws {
        let source = "data:image/png;base64,\(png!.base64EncodedString())"
        let pasteboard = discordStylePasteboard(imageSource: source)

        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected text content")
        }
        let pin = manager.createPin(content: .text(text))
        let view = try XCTUnwrap(pin.contentView as? TextPinView)

        let attachment = try self.attachment(of: view)
        XCTAssertNotNil(attachment.image, "the chart is displayed")
        XCTAssertEqual(attachment.image?.size, NSSize(width: 400, height: 200))
        XCTAssertTrue(loader.requested.isEmpty, "local images need no network")

        var stillTagged = false
        view.editableTextView.textStorage?.enumerateAttribute(
            DeferredImages.sourceAttribute,
            in: view.editableTextView.textStorage?.fullRange ?? NSRange(), options: []
        ) { value, _, _ in stillTagged = value != nil }
        XCTAssertFalse(stillTagged, "a resolved image is not resolved twice")
    }

    func testRemoteImagesAreFetchedAndScaledToTheWrapWidth() throws {
        let pasteboard = discordStylePasteboard(imageSource: "https://cdn.discordapp.com/attachments/1/2/chart.png?ex=1&amp;is=2")
        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected text content")
        }
        let pin = manager.createPin(content: .text(text))
        let view = try XCTUnwrap(pin.contentView as? TextPinView)

        XCTAssertEqual(loader.requested.map(\.absoluteString),
                       ["https://cdn.discordapp.com/attachments/1/2/chart.png?ex=1&is=2"],
                       "the entity-decoded URL is what gets fetched")

        let attachment = try self.attachment(of: view)
        let image = try XCTUnwrap(attachment.image)
        XCTAssertGreaterThan(image.size.width, 1)
        // The window grows a touch after installation, so the wrap width the
        // image was fitted to may be a couple of points narrower.
        XCTAssertLessThanOrEqual(attachment.bounds.width, view.textWrapWidth + 2,
                                 "the chart never overflows the pin")
        XCTAssertGreaterThan(attachment.bounds.width, view.textWrapWidth * 0.8,
                             "the chart is scaled to the pin's wrap width")
        XCTAssertEqual(attachment.bounds.height, attachment.bounds.width / 2, accuracy: 1,
                       "the aspect ratio is kept")
    }

    func testFailedFetchLeavesThePinUsable() throws {
        loader.data = nil
        let pasteboard = discordStylePasteboard(imageSource: "https://cdn.discordapp.com/attachments/1/2/chart.png")
        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected text content")
        }
        let pin = manager.createPin(content: .text(text))
        let view = try XCTUnwrap(pin.contentView as? TextPinView)

        XCTAssertEqual(loader.requested.count, 1)
        XCTAssertEqual(view.editableTextView.string.contains("IWM:"), true)
        XCTAssertTrue(stillDeferred(view), "the placeholder stays unresolved, the pin stays usable")
    }

    /// True when the pin still carries an unresolved image source.
    private func stillDeferred(_ view: TextPinView) -> Bool {
        var tagged = false
        view.editableTextView.textStorage?.enumerateAttribute(
            DeferredImages.sourceAttribute,
            in: view.editableTextView.textStorage?.fullRange ?? NSRange(), options: []
        ) { value, _, _ in if value != nil { tagged = true } }
        return tagged
    }

    func testPinGrowsToFitTheArrivingImage() throws {
        let pasteboard = discordStylePasteboard(imageSource: "https://cdn.discordapp.com/attachments/1/2/tall.png")
        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected text content")
        }
        let pin = manager.createPin(content: .text(text))

        XCTAssertGreaterThan(pin.panel.frame.height, 100,
                             "the window grew so the chart is fully visible")
    }

    /// The shape of the message that motivated the fix: a chart plus Discord's
    /// blurred loading placeholder, which the page hides with `opacity: 0`.
    func testHiddenLoadingPlaceholderIsDroppedAndTheChartShows() throws {
        let id = UUID().uuidString
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pinboard.discord.\(id)"))
        pasteboard.clearContents()
        let placeholder = "data:image/png;base64,\(try XCTUnwrap(HTMLImageSourceTests.makePNG(width: 32, height: 18, color: .darkGray)).base64EncodedString())"
        let html = """
        <meta charset='utf-8'><div>IWM:</div><img src="https://cdn.discordapp.com/attachments/1/2/chart.png" alt="Image">
        <img class="imagePlaceholder imagePlaceholderHidden" alt="" src="\(placeholder)" style="display: block; position: absolute; opacity: 0;">
        """
        pasteboard.setData(Data(html.utf8), forType: .html)
        pasteboard.setString("IWM:\nImage", forType: .string)

        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected text content")
        }
        XCTAssertEqual(text.string.components(separatedBy: "\u{FFFC}").count - 1, 1,
                       "only the chart's placeholder character survives the read")

        let pin = manager.createPin(content: .text(text))
        let view = try XCTUnwrap(pin.contentView as? TextPinView)
        let attachment = try self.attachment(of: view)
        XCTAssertEqual(attachment.image?.size, NSSize(width: 400, height: 200),
                       "the chart is installed, the hidden placeholder is gone")
    }

    func testEveryVisibleImageIsResolvedInPlace() throws {
        let first = "data:image/png;base64,\(try XCTUnwrap(HTMLImageSourceTests.makePNG(width: 30, height: 10, color: .red)).base64EncodedString())"
        let second = "data:image/png;base64,\(try XCTUnwrap(HTMLImageSourceTests.makePNG(width: 40, height: 20, color: .blue)).base64EncodedString())"
        let id = UUID().uuidString
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pinboard.multi.\(id)"))
        pasteboard.clearContents()
        let html = "<div>two</div><img src=\"\(first)\"><img src=\"\(second)\">"
        pasteboard.setData(Data(html.utf8), forType: .html)
        pasteboard.setString("two", forType: .string)

        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected text content")
        }
        let pin = manager.createPin(content: .text(text))
        let view = try XCTUnwrap(pin.contentView as? TextPinView)

        XCTAssertEqual(try attachment(of: view, at: 0).image?.size, NSSize(width: 30, height: 10))
        XCTAssertEqual(try attachment(of: view, at: 1).image?.size, NSSize(width: 40, height: 20))
    }

    /// When the raw HTML and the importer disagree about how many images
    /// exist, positions cannot be trusted and nothing is resolved.
    func testPositionalMismatchLeavesThePlaceholdersUntouched() throws {
        let id = UUID().uuidString
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pinboard.mismatch.\(id)"))
        pasteboard.clearContents()
        let html = """
        <div>text</div><script>var ghost = "<img src='https://example.com/ghost.png'>";</script><img src="https://example.com/real.png">
        """
        pasteboard.setData(Data(html.utf8), forType: .html)
        pasteboard.setString("text", forType: .string)

        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected text content")
        }
        var tagged = false
        text.enumerateAttribute(DeferredImages.sourceAttribute, in: text.fullRange, options: []) { value, _, _ in
            if value != nil { tagged = true }
        }
        XCTAssertFalse(tagged)

        let pin = manager.createPin(content: .text(text))
        let view = try XCTUnwrap(pin.contentView as? TextPinView)
        XCTAssertEqual(loader.requested, [])
    }

    func testFetchedImageSurvivesTheHistoryRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HistoryStore(directory: directory)
        manager.historyStore = store
        defer { try? FileManager.default.removeItem(at: directory) }

        let pasteboard = discordStylePasteboard(imageSource: "https://cdn.discordapp.com/attachments/1/2/chart.png")
        guard case .text(let text)? = ClipboardReader.read(from: pasteboard) else {
            return XCTFail("expected text content")
        }
        // The fetch resolves before the first history write, so a single write
        // already carries the image.
        let pin = manager.createPin(content: .text(text))
        let recordID = try XCTUnwrap(pin.historyRecordID)
        manager.flushHistorySync(for: pin)

        let reloaded = HistoryStore(directory: directory)
        guard case .text(let stored) = try XCTUnwrap(reloaded.entry(id: recordID)).content else {
            return XCTFail("expected text record")
        }
        var storedImage: NSImage?
        stored.enumerateAttribute(.attachment, in: stored.fullRange, options: []) { value, _, _ in
            if let attachment = value as? NSTextAttachment,
               let bytes = attachment.fileWrapper?.regularFileContents {
                storedImage = NSImage(data: bytes)
            }
        }
        let image = try XCTUnwrap(storedImage, "the record keeps the real pixels, not the placeholder")
        XCTAssertEqual(image.size, NSSize(width: 400, height: 200))
    }
}
