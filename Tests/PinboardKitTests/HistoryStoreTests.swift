import AppKit
import XCTest
@testable import PinboardKit

final class HistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = HistoryStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeText(_ string: String = "Hello") -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.systemRed,
            .backgroundColor: NSColor.systemYellow
        ])
    }

    func testCreatePersistsTextAndReloadsIt() throws {
        let id = try store.upsert(content: .text(makeText("persistent text")))
        XCTAssertEqual(store.records.count, 1)

        let reloaded = HistoryStore(directory: directory)
        XCTAssertEqual(reloaded.records.count, 1)
        let entry = try XCTUnwrap(reloaded.entry(id: id))
        guard case .text(let attributed) = entry.content else { return XCTFail("expected text") }
        XCTAssertEqual(attributed.string, "persistent text")
        XCTAssertNotNil(attributed.attribute(.backgroundColor, at: 0, effectiveRange: nil),
                        "RTF background colour survives the round trip")
        XCTAssertNotNil(attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil))
    }

    func testTextAttachmentsSurviveRecordReplacementAndReload() throws {
        let wrapper = FileWrapper(regularFileWithContents: try XCTUnwrap(TestImage.make(width: 12, height: 8).pngData()))
        wrapper.preferredFilename = "attachment.png"
        let text = NSMutableAttributedString(attributedString: makeText("with image "))
        text.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        let id = try store.upsert(content: .text(makeText("before")))
        try store.upsert(id: id, content: .text(text))

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(id.uuidString).path)
        XCTAssertEqual(Set(files), ["record.json", "content.rtfd"])
        let reloaded = HistoryStore(directory: directory)
        guard case .text(let restored) = reloaded.entry(id: id)?.content else { return XCTFail("expected rich text") }
        XCTAssertEqual(restored.string, text.string)
        let attachment = try XCTUnwrap(restored.attribute(.attachment, at: restored.length - 1, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertEqual(attachment.fileWrapper?.regularFileContents, wrapper.regularFileContents)
    }

    func testEditsUpdateSameRecord() throws {
        let id = try store.upsert(content: .text(makeText("first")))
        try store.upsert(id: id, content: .text(makeText("second")))
        try store.upsert(id: id, content: .text(makeText("third")))

        XCTAssertEqual(store.records.count, 1, "edits must not create new entries")
        let record = try XCTUnwrap(store.record(id: id))
        XCTAssertEqual(record.text, "third")
        XCTAssertLessThanOrEqual(record.createdAt, record.updatedAt)
        guard case .text(let attributed) = store.entry(id: id)?.content else { return XCTFail() }
        XCTAssertEqual(attributed.string, "third")
    }

    func testFailedEncodingPreservesCommittedImageAndMetadata() throws {
        let id = try store.upsert(content: .image(TestImage.make(width: 40, height: 20)))
        let record = try XCTUnwrap(store.record(id: id))
        let imageURL = directory.appendingPathComponent(id.uuidString).appendingPathComponent("image.png")
        let original = try Data(contentsOf: imageURL)
        var changes = 0
        store.onChange = { changes += 1 }

        XCTAssertThrowsError(try store.upsert(id: id, content: .image(NSImage(size: .zero))))

        XCTAssertEqual(store.record(id: id), record)
        XCTAssertEqual(try? Data(contentsOf: imageURL), original)
        XCTAssertEqual(changes, 0, "failed writes must not announce a new saved state")
        let reloaded = HistoryStore(directory: directory)
        XCTAssertNotNil(reloaded.entry(id: id), "the last committed image must survive a failed update")
    }

    func testUnwritableDestinationDoesNotPublishAnUnsavedRecord() throws {
        // A regular file where the history directory should be makes failure
        // deterministic without relying on the test user's permission level.
        try Data("blocked".utf8).write(to: directory)
        var changes = 0
        store.onChange = { changes += 1 }

        XCTAssertThrowsError(try store.upsert(content: .text(makeText())))
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(changes, 0)
    }

    func testReloadIgnoresUncommittedStagingDirectories() throws {
        let id = try store.upsert(content: .text(makeText("committed")))
        let staged = directory.appendingPathComponent(".staging-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: directory.appendingPathComponent(id.uuidString), to: staged)

        let reloaded = HistoryStore(directory: directory)
        XCTAssertEqual(reloaded.records.map(\.id), [id], "a staged copy must not become another record")
    }

    func testReplacingRecordRemovesStalePayloadsAndKeepsCreationDate() throws {
        let id = try store.upsert(content: .image(TestImage.make(width: 20, height: 10)),
                                  annotationData: Data("{}".utf8))
        let createdAt = try XCTUnwrap(store.record(id: id)).createdAt
        try store.upsert(id: id, content: .text(makeText("replacement")))

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(id.uuidString).path)
        XCTAssertEqual(Set(files), ["record.json", "content.rtf"])
        XCTAssertEqual(store.record(id: id)?.createdAt, createdAt)
        let reloaded = HistoryStore(directory: directory)
        guard case .text(let text) = reloaded.entry(id: id)?.content else { return XCTFail("expected text") }
        XCTAssertEqual(text.string, "replacement")
    }

    func testImageRoundTripWithAnnotations() throws {
        let image = NSImage(size: NSSize(width: 40, height: 20))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 20).fill()
        image.unlockFocus()

        let annotation = Annotation(tool: .rectangle,
                                    points: [CGPoint(x: 1, y: 1), CGPoint(x: 10, y: 8)],
                                    style: AnnotationStyle.current(), text: nil)
        let payload = AnnotationStore.Payload(annotations: [annotation], cropRect: nil)
        let annotationData = try XCTUnwrap(JSONEncoder().encode(payload))

        let id = try store.upsert(content: .image(image), annotationData: annotationData)
        let reloaded = HistoryStore(directory: directory)
        let entry = try XCTUnwrap(reloaded.entry(id: id))
        guard case .image(let restored) = entry.content else { return XCTFail("expected image") }
        XCTAssertGreaterThan(restored.pixelSize.width, 0)
        XCTAssertNotNil(entry.annotationData)

        let annotationStore = AnnotationStore()
        annotationStore.restore(from: try XCTUnwrap(entry.annotationData))
        XCTAssertEqual(annotationStore.annotations.count, 1)
        XCTAssertEqual(annotationStore.annotations[0].tool, .rectangle)
    }

    func testDeleteRemovesFiles() throws {
        let id = try store.upsert(content: .text(makeText()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString).path))
        try store.delete(id: id)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString).path))
    }

    func testDeleteFailureKeepsRecordAndPayload() throws {
        let id = try store.upsert(content: .text(makeText("keep me")))
        let path = directory.appendingPathComponent(id.uuidString).path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path) }
        var changes = 0
        store.onChange = { changes += 1 }

        XCTAssertThrowsError(try store.delete(id: id))

        XCTAssertNotNil(store.record(id: id))
        XCTAssertNotNil(store.entry(id: id))
        XCTAssertNotNil(HistoryStore(directory: directory).entry(id: id))
        XCTAssertEqual(changes, 0)
    }

    func testClearReportsPartialFailureAndKeepsUndeletableRecords() throws {
        let locked = try store.upsert(content: .text(makeText("locked")))
        let removable = try store.upsert(content: .text(makeText("removable")))
        let path = directory.appendingPathComponent(locked.uuidString).path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path) }

        XCTAssertThrowsError(try store.clear())

        XCTAssertEqual(store.records.map(\.id), [locked])
        XCTAssertNil(store.record(id: removable))
        XCTAssertEqual(HistoryStore(directory: directory).records.map(\.id), [locked])
    }

    func testPruneReportsFailureWithoutForgettingUndeletableRecord() throws {
        let id = try store.upsert(content: .text(makeText("locked")))
        let path = directory.appendingPathComponent(id.uuidString).path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path) }

        XCTAssertThrowsError(try store.prune(olderThan: Date().addingTimeInterval(60)))
        XCTAssertNotNil(store.record(id: id))
    }

    func testDeletingAlreadyMissingPayloadRemovesItsMetadata() throws {
        let id = try store.upsert(content: .text(makeText()))
        try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString))
        try store.delete(id: id)
        XCTAssertNil(store.record(id: id))
    }

    func testPruneRespectsCutoffAndLiveIDs() throws {
        let old = try store.upsert(content: .text(makeText("old")))
        let live = try store.upsert(content: .text(makeText("live")))
        try store.prune(olderThan: Date().addingTimeInterval(60), excluding: [live])

        XCTAssertNil(store.record(id: old))
        XCTAssertNotNil(store.record(id: live), "a record attached to an open pin is never pruned")
    }

    func testCorruptRecordLosesOnlyItself() throws {
        let good = try store.upsert(content: .text(makeText("good")))
        let bad = try store.upsert(content: .text(makeText("bad")))
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent(bad.uuidString).appendingPathComponent("record.json")
        )

        let reloaded = HistoryStore(directory: directory)
        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertEqual(reloaded.records[0].id, good)
    }

    func testSearchFiltersByText() throws {
        try store.upsert(content: .text(makeText("meeting notes for Friday")))
        try store.upsert(content: .text(makeText("grocery list")))
        XCTAssertEqual(store.filtered(query: "meeting").count, 1)
        XCTAssertEqual(store.filtered(query: "").count, 2)
    }

    func testRetentionCutoff() throws {
        let preferences = Preferences.shared
        preferences.historyRetention = .days30
        let cutoff = try XCTUnwrap(preferences.historyRetentionCutoff)
        XCTAssertEqual(Date().timeIntervalSince(cutoff), 30 * 86_400, accuracy: 5)
        preferences.historyRetention = .forever
        XCTAssertNil(preferences.historyRetentionCutoff)
        preferences.historyRetention = .days30
    }
}
