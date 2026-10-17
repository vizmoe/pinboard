import AppKit
import XCTest
@testable import PinboardKit

/// Markdown pins: rendered display, source editing, and the global/per-window
/// mode switch.
final class MarkdownPinTests: XCTestCase {
    private var manager: PinWindowManager { PinWindowManager.shared }

    override func tearDown() {
        manager.closeAll()
        Preferences.shared.textMode = .richText
        super.tearDown()
    }

    /// `explicitMode == nil` creates a pin that follows the global default.
    private func makeView(_ source: String,
                          explicitMode: TextContentMode? = nil) throws -> (PinWindowController, TextPinView) {
        let pin = manager.createPin(content: .text(NSAttributedString(string: source)), textMode: explicitMode)
        let view = try XCTUnwrap(pin.contentView as? TextPinView)
        return (pin, view)
    }

    private func text(of view: TextPinView) throws -> String {
        guard case .text(let attributed) = view.currentContent() else {
            throw XCTSkip("expected text content")
        }
        return attributed.string
    }

    // MARK: - Display

    func testMarkdownPinRendersDocumentAndKeepsSource() throws {
        let (_, view) = try makeView("# Title\n\nSome **bold** text.", explicitMode: .markdown)

        XCTAssertEqual(view.textMode, .markdown)
        XCTAssertEqual(try text(of: view), "# Title\n\nSome **bold** text.",
                       "canonical content is the raw source")

        let rendered = view.renderedAttributedString.string
        XCTAssertTrue(rendered.contains("Title"))
        XCTAssertFalse(rendered.contains("#"), "the heading marker is not shown")
        XCTAssertFalse(rendered.contains("**"), "emphasis markers are not shown")
    }

    func testRichPinKeepsItsContentAndGetsTheFormatToolbar() throws {
        let source = NSAttributedString(string: "plain", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 20)
        ])
        let pin = manager.createPin(content: .text(source), textMode: .richText)
        let view = try XCTUnwrap(pin.contentView as? TextPinView)

        view.beginEditing(at: nil)
        XCTAssertNotNil(view.formatToolbar, "rich text keeps its formatting toolbar")
        XCTAssertEqual(view.editableTextView.string, "plain")
        let font = view.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    // MARK: - Source editing

    func testEditingShowsAndCommitsTheSource() throws {
        let (_, view) = try makeView("**bold**", explicitMode: .markdown)

        view.beginEditing(at: nil)
        let editor = view.editableTextView
        XCTAssertEqual(editor.string, "**bold**", "editing exposes the markdown source")
        XCTAssertNil(view.formatToolbar, "markdown source has no rich formatting controls")

        editor.insertText(" tail", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        view.endEditing()

        XCTAssertEqual(try text(of: view), "**bold** tail", "the edit lands in the source, markers intact")
        XCTAssertTrue(view.renderedAttributedString.string.contains("bold tail"))
        XCTAssertFalse(view.renderedAttributedString.string.contains("**"), "the idle display is rendered again")
    }

    // MARK: - Mode switching

    func testPerWindowSwitchRoundTripsWithoutEdits() throws {
        let (_, view) = try makeView("**bold**", explicitMode: .markdown)

        view.setTextMode(.richText, explicit: true)
        XCTAssertEqual(view.textMode, .richText)
        XCTAssertTrue(view.hasExplicitTextMode)
        XCTAssertEqual(try text(of: view), "bold", "markdown becomes the rendered rich text")

        view.setTextMode(.markdown, explicit: true)
        XCTAssertEqual(view.textMode, .markdown)
        XCTAssertEqual(try text(of: view), "**bold**", "switching back restores the source")
    }

    func testEditsSurviveAnIntermediateModeSwitch() throws {
        let (_, view) = try makeView("one", explicitMode: .markdown)
        view.setTextMode(.richText, explicit: true)

        view.beginEditing(at: nil)
        view.editableTextView.insertText(" two",
                                         replacementRange: NSRange(location: 3, length: 0))
        view.endEditing()

        view.setTextMode(.markdown, explicit: true)
        XCTAssertEqual(try text(of: view), "one two", "edits made after a switch are not rolled back")
    }

    func testNewPinsUseTheGlobalDefault() throws {
        Preferences.shared.textMode = .markdown
        let (_, view) = try makeView("**x**")

        XCTAssertEqual(view.textMode, .markdown)
        XCTAssertFalse(view.hasExplicitTextMode)
    }

    func testGlobalModeAppliesToPinsThatWereNotSwitched() throws {
        Preferences.shared.textMode = .richText
        let (_, following) = try makeView("**bold**")
        XCTAssertFalse(following.hasExplicitTextMode)

        Preferences.shared.textMode = .markdown
        XCTAssertEqual(following.textMode, .markdown, "an untouched pin follows the global default")
        XCTAssertFalse(following.renderedAttributedString.string.contains("**"))

        Preferences.shared.textMode = .richText
        XCTAssertEqual(following.textMode, .richText)
        XCTAssertEqual(try text(of: following), "**bold**",
                       "flipping back restores the pre-switch representation")
    }

    func testExplicitSwitchStopsFollowingTheGlobalDefault() throws {
        Preferences.shared.textMode = .richText
        let (_, switched) = try makeView("stays markdown")
        switched.setTextMode(.markdown, explicit: true)

        Preferences.shared.textMode = .markdown
        Preferences.shared.textMode = .richText

        XCTAssertEqual(switched.textMode, .markdown, "a pin switched per window ignores the global default")
    }

    func testSnapshotCarriesTheMode() throws {
        let (pin, _) = try makeView("**x**", explicitMode: .markdown)
        XCTAssertEqual(pin.snapshot().textMode, .markdown)
        XCTAssertEqual(pin.snapshot().plainText, "**x**")
    }

    // MARK: - Copy

    func testMarkdownCopyWritesTheRawSource() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pinboard.markdown.copy"))
        pasteboard.clearContents()
        let (_, view) = try makeView("# Title\n\n**bold**", explicitMode: .markdown)

        view.copy(to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "# Title\n\n**bold**")
        XCTAssertNil(pasteboard.data(forType: .rtf), "the rendered document is not what gets copied")
    }

    func testRichCopyStillWritesRTF() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pinboard.rich.copy"))
        pasteboard.clearContents()
        let (_, view) = try makeView("plain", explicitMode: .richText)

        view.copy(to: pasteboard)

        XCTAssertNotNil(pasteboard.data(forType: .rtf))
        XCTAssertEqual(pasteboard.string(forType: .string), "plain")
    }
}

/// Markdown state across history: records keep the source plus the mode, and
/// re-pinning reproduces the pin.
final class MarkdownHistoryTests: XCTestCase {
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

    private func makeMarkdownPin(_ source: String) throws -> (PinWindowController, TextPinView) {
        let pin = manager.createPin(content: .text(NSAttributedString(string: source)), textMode: .markdown)
        return (pin, try XCTUnwrap(pin.contentView as? TextPinView))
    }

    func testMarkdownEditsPersistSourceAndMode() throws {
        let (pin, view) = try makeMarkdownPin("# Title")
        let recordID = try XCTUnwrap(pin.historyRecordID)

        view.beginEditing(at: nil)
        view.editableTextView.insertText("\ntail",
                                         replacementRange: NSRange(location: view.editableTextView.string.utf16.count, length: 0))
        manager.flushHistorySync(for: pin)

        XCTAssertEqual(store.record(id: recordID)?.text, "# Title\ntail")
        XCTAssertEqual(store.record(id: recordID)?.textMode, .markdown)

        // The mode must be on disk, not just in memory.
        let reloaded = HistoryStore(directory: directory)
        XCTAssertEqual(reloaded.record(id: recordID)?.textMode, .markdown)
        XCTAssertEqual(reloaded.entry(id: recordID)?.textMode, .markdown)
    }

    func testRepinRestoresMarkdownMode() throws {
        let (pin, _) = try makeMarkdownPin("**bold**")
        let recordID = try XCTUnwrap(pin.historyRecordID)
        manager.flushHistorySync(for: pin)

        let repinned = try XCTUnwrap(manager.repin(recordID: recordID))
        let view = try XCTUnwrap(repinned.contentView as? TextPinView)

        XCTAssertEqual(view.textMode, .markdown)
        XCTAssertTrue(view.hasExplicitTextMode,
                      "the record's mode is authoritative: a repin must not drift with the global default")
        XCTAssertEqual(view.renderedAttributedString.string, "bold")
        guard case .text(let restored) = repinned.contentView.currentContent() else { return XCTFail() }
        XCTAssertEqual(restored.string, "**bold**")
    }

    func testGlobalSwitchUpdatesTheRecordedMode() throws {
        Preferences.shared.textMode = .richText
        let pin = manager.createPin(content: .text(NSAttributedString(string: "plain words")))
        let view = try XCTUnwrap(pin.contentView as? TextPinView)
        let recordID = try XCTUnwrap(pin.historyRecordID)

        Preferences.shared.textMode = .markdown
        XCTAssertEqual(view.textMode, .markdown)
        manager.flushHistorySync(for: pin)

        XCTAssertEqual(store.record(id: recordID)?.textMode, .markdown)
        XCTAssertEqual(store.record(id: recordID)?.text, "plain words")
    }

    func testUpsertWithoutModeKeepsAMarkdownRecord() throws {
        let id = try store.upsert(content: .text(NSAttributedString(string: "source")), textMode: .markdown)
        try store.upsert(id: id, content: .text(NSAttributedString(string: "edited")))
        XCTAssertEqual(store.record(id: id)?.textMode, .markdown)
    }

    func testLegacyRecordDecodesAsRichText() throws {
        let id = try store.upsert(content: .text(NSAttributedString(string: "legacy")))
        // Simulate a record written before text modes existed.
        let file = directory.appendingPathComponent(id.uuidString).appendingPathComponent("record.json")
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json.removeValue(forKey: "textMode")
        try JSONSerialization.data(withJSONObject: json).write(to: file)

        let reloaded = HistoryStore(directory: directory)
        XCTAssertNil(reloaded.record(id: id)?.textMode)
        XCTAssertEqual(reloaded.entry(id: id)?.textMode, .richText)
    }
}
