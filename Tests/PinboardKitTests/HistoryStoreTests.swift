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
        let id = store.upsert(content: .text(makeText("persistent text")))
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

    func testEditsUpdateSameRecord() throws {
        let id = store.upsert(content: .text(makeText("first")))
        store.upsert(id: id, content: .text(makeText("second")))
        store.upsert(id: id, content: .text(makeText("third")))

        XCTAssertEqual(store.records.count, 1, "edits must not create new entries")
        let record = try XCTUnwrap(store.record(id: id))
        XCTAssertEqual(record.text, "third")
        XCTAssertLessThanOrEqual(record.createdAt, record.updatedAt)
        guard case .text(let attributed) = store.entry(id: id)?.content else { return XCTFail() }
        XCTAssertEqual(attributed.string, "third")
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

        let id = store.upsert(content: .image(image), annotationData: annotationData)
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
        let id = store.upsert(content: .text(makeText()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString).path))
        store.delete(id: id)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString).path))
    }

    func testPruneRespectsCutoffAndLiveIDs() throws {
        let old = store.upsert(content: .text(makeText("old")))
        let live = store.upsert(content: .text(makeText("live")))
        store.prune(olderThan: Date().addingTimeInterval(60), excluding: [live])

        XCTAssertNil(store.record(id: old))
        XCTAssertNotNil(store.record(id: live), "a record attached to an open pin is never pruned")
    }

    func testCorruptRecordLosesOnlyItself() throws {
        let good = store.upsert(content: .text(makeText("good")))
        let bad = store.upsert(content: .text(makeText("bad")))
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent(bad.uuidString).appendingPathComponent("record.json")
        )

        let reloaded = HistoryStore(directory: directory)
        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertEqual(reloaded.records[0].id, good)
    }

    func testSearchFiltersByText() {
        store.upsert(content: .text(makeText("meeting notes for Friday")))
        store.upsert(content: .text(makeText("grocery list")))
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
