import AppKit
import XCTest
@testable import PinboardKit

/// History ↔ pin association: a pin's record tracks its *latest* content, and
/// re-pinning a record yields an independent window + a new record.
final class HistorySyncTests: XCTestCase {
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
        manager.onHistoryWriteError = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makePin() throws -> PinWindowController {
        let text = NSAttributedString(string: "original", attributes: ClipboardReader.defaultTextAttributes())
        return manager.createPin(content: .text(text))
    }

    func testNewPinCreatesRecord() throws {
        let pin = try makePin()
        XCTAssertNotNil(pin.historyRecordID)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records[0].text, "original")
    }

    func testFailedInitialSaveReportsErrorAndCanRetryForTheSamePin() throws {
        try Data("blocked".utf8).write(to: directory)
        var errors: [Error] = []
        manager.onHistoryWriteError = { errors.append($0) }

        let pin = try makePin()
        let recordID = try XCTUnwrap(pin.historyRecordID)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(pin.isPinVisible, "a history failure must not discard the live pin")

        try FileManager.default.removeItem(at: directory)
        manager.flushHistorySync(for: pin)
        XCTAssertEqual(store.records.map(\.id), [recordID])
        XCTAssertEqual(store.record(id: recordID)?.text, "original")
        XCTAssertEqual(errors.count, 1)
    }

    func testEditSyncsToSameRecord() throws {
        let pin = try makePin()
        let recordID = try XCTUnwrap(pin.historyRecordID)
        let view = try XCTUnwrap(pin.contentView as? TextPinView)

        view.beginEditing(at: nil)
        let textView = view.editableTextView
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        textView.insertText(" +edited", replacementRange: textView.selectedRange())
        manager.flushHistorySync(for: pin)

        XCTAssertEqual(store.records.count, 1, "edits update the record instead of appending")
        XCTAssertEqual(store.record(id: recordID)?.text, "original +edited")
    }

    func testFormatEditSyncsToRecord() throws {
        let pin = try makePin()
        let recordID = try XCTUnwrap(pin.historyRecordID)
        let view = try XCTUnwrap(pin.contentView as? TextPinView)
        view.beginEditing(at: nil)
        view.editableTextView.setSelectedRange(NSRange(location: 0, length: 4))
        TextFormatter(textView: view.editableTextView).setAttribute(.backgroundColor, value: NSColor.systemYellow)
        manager.flushHistorySync(for: pin)

        guard case .text(let stored) = store.entry(id: recordID)?.content else { return XCTFail() }
        XCTAssertNotNil(stored.attribute(.backgroundColor, at: 0, effectiveRange: nil),
                        "record holds the latest RTF state")
    }

    func testClosedPinKeepsItsRecord() throws {
        let pin = try makePin()
        let recordID = try XCTUnwrap(pin.historyRecordID)
        pin.closePin()
        XCTAssertNotNil(store.record(id: recordID), "closing a pin keeps the history entry")
    }

    func testRepinCreatesIndependentWindowAndRecord() throws {
        let pin = try makePin()
        let recordID = try XCTUnwrap(pin.historyRecordID)
        let view = try XCTUnwrap(pin.contentView as? TextPinView)
        view.beginEditing(at: nil)
        view.editableTextView.insertText(" repinned", replacementRange: NSRange(location: 8, length: 0))
        manager.flushHistorySync(for: pin)

        let repinned = try XCTUnwrap(manager.repin(recordID: recordID))
        XCTAssertNotEqual(repinned.historyRecordID, recordID, "re-pin creates a new record")
        XCTAssertEqual(store.records.count, 2)
        guard case .text(let text) = repinned.contentView.currentContent() else { return XCTFail() }
        XCTAssertEqual(text.string, "original repinned")

        // Editing the new pin must not touch the old record.
        pin.closePin()
        repinned.closePin()
        XCTAssertNotNil(store.record(id: recordID))
        XCTAssertNotNil(store.record(id: repinned.historyRecordID!))
    }

    func testNoRecordWithoutStore() throws {
        manager.historyStore = nil
        let pin = manager.createPin(content: .text(NSAttributedString(string: "x")))
        XCTAssertNil(pin.historyRecordID)
        pin.closePin()
        manager.historyStore = store
    }

    func testAnnotationEditSyncs() throws {
        let image = NSImage(size: NSSize(width: 30, height: 30))
        image.lockFocus()
        NSColor.systemGreen.setFill()
        NSRect(x: 0, y: 0, width: 30, height: 30).fill()
        image.unlockFocus()

        let pin = manager.createPin(content: .image(image))
        let recordID = try XCTUnwrap(pin.historyRecordID)
        let view = try XCTUnwrap(pin.contentView as? ImagePinView)
        view.annotationStore.add(Annotation(tool: .arrow,
                                            points: [CGPoint(x: 1, y: 1), CGPoint(x: 9, y: 9)],
                                            style: .current(), text: nil))
        manager.flushHistorySync(for: pin)

        XCTAssertTrue(store.record(id: recordID)?.hasAnnotations == true)
        // Re-pin restores editable annotations, not a flattened bitmap.
        let repinned = try XCTUnwrap(manager.repin(recordID: recordID))
        let repinnedView = try XCTUnwrap(repinned.contentView as? ImagePinView)
        XCTAssertEqual(repinnedView.annotationStore.annotations.count, 1)
        XCTAssertEqual(repinnedView.annotationStore.annotations[0].tool, .arrow)
    }

    func testHideShowDoesNotDuplicateRecords() throws {
        let pin = try makePin()
        pin.hidePin()
        pin.showPin()
        XCTAssertEqual(store.records.count, 1)
    }
}
