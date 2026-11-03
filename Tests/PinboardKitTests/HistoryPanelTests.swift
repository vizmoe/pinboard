import AppKit
import XCTest
@testable import PinboardKit

final class HistoryPanelTests: XCTestCase {
    private let manager = PinWindowManager.shared
    private var directory: URL!
    private var store: HistoryStore!
    private var pasteboard: NSPasteboard!
    private var model: HistoryViewModel!
    private var panel: HistoryPanelViewController!

    override func setUpWithError() throws {
        manager.closeAll()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = HistoryStore(directory: directory)
        manager.historyStore = store
        pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        model = HistoryViewModel(store: store, manager: manager, pasteboard: pasteboard)
        panel = HistoryPanelViewController(model: model)
        panel.reloadHistory()
    }

    override func tearDown() {
        manager.closeAll()
        manager.historyStore = nil
        manager.onHistoryError = nil
        manager.onChange = nil
        panel = nil
        model = nil
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }

    private func click(_ title: String) throws {
        try XCTUnwrap(buttons(panel.view).first { $0.identifier?.rawValue == title && !$0.isHiddenOrHasHiddenAncestor }).performClick(nil)
    }

    private func select(_ id: UUID) throws {
        let row = try XCTUnwrap(panel.records.firstIndex { $0.id == id })
        panel.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        XCTAssertEqual(model.selection, id)
    }

    private func search(_ text: String) {
        panel.searchField.stringValue = text
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.searchField))
    }

    func testSearchDetailCopyRepinAndReturnPreserveSourceAndQuery() throws {
        let id = try store.upsert(content: .text(NSAttributedString(string: "# Release notes\nKeep **Markdown** source")), textMode: .markdown)
        _ = try store.upsert(content: .text(NSAttributedString(string: "Unrelated")))
        search("RELEASE")
        XCTAssertEqual(panel.records.map(\.id), [id])
        try select(id)
        XCTAssertFalse(panel.detailScrollView.isHidden)
        XCTAssertTrue(panel.detailTextView.string.contains("Release notes"))
        XCTAssertFalse(panel.detailTextView.string.contains("**Markdown**"))
        let generalRevision = NSPasteboard.general.changeCount
        try click("Copy")
        XCTAssertEqual(buttons(panel.view).first { $0.identifier?.rawValue == "Copy" }?.state, .off,
                       "Only navigation icons keep a selected state after an action")
        XCTAssertEqual(pasteboard.string(forType: .string), "# Release notes\nKeep **Markdown** source")
        XCTAssertEqual(NSPasteboard.general.changeCount, generalRevision)
        try click("Pin Again")
        XCTAssertEqual(manager.count, 1)
        XCTAssertEqual((manager.pins.first?.contentView as? TextPinView)?.textMode, .markdown)
        XCTAssertNotEqual(manager.pins.first?.historyRecordID, id)
        try click("Back")
        XCTAssertNil(model.selection)
        XCTAssertEqual(panel.searchField.stringValue, "RELEASE")
        XCTAssertEqual(panel.records.count, 2)
        var returned = false
        panel.onBack = { returned = true }
        try click("Pins")
        XCTAssertTrue(returned)
    }

    func testLiveUpdatesDeleteAndStaleSelectionNeverActOnAnotherRecord() throws {
        let pin = manager.createPin(content: .text(NSAttributedString(string: "First")))
        let id = try XCTUnwrap(pin.historyRecordID)
        try select(id)
        try store.upsert(id: id, content: .text(NSAttributedString(string: "Updated")))
        XCTAssertEqual(panel.detailTextView.string, "Updated")
        try click("Delete")
        XCTAssertNil(store.record(id: id))
        XCTAssertNil(pin.historyRecordID)
        XCTAssertTrue(pin.isPinVisible)
        XCTAssertNil(model.selection)
        XCTAssertTrue(panel.records.isEmpty)
        let other = try store.upsert(content: .text(NSAttributedString(string: "Keep")))
        model.selection = id
        panel.reloadHistory()
        XCTAssertNil(model.selection)
        XCTAssertTrue(panel.detailScrollView.isHidden)
        model.copy(id)
        model.pinAgain(id)
        model.delete(id)
        XCTAssertNotNil(store.record(id: other))
        XCTAssertEqual(manager.count, 1)
    }

    func testClearRequiresConfirmationAndProtectsLiveRecords() throws {
        let closed = try store.upsert(content: .text(NSAttributedString(string: "Closed")))
        let pin = manager.createPin(content: .text(NSAttributedString(string: "Open")))
        let live = try XCTUnwrap(pin.historyRecordID)
        try click("Clear History")
        XCTAssertTrue(panel.isConfirmingClear)
        XCTAssertEqual(store.records.count, 2)
        try click("Cancel")
        XCTAssertFalse(panel.isConfirmingClear)
        XCTAssertNotNil(store.record(id: closed))
        try click("Clear History")
        try click("Confirm Clear")
        XCTAssertFalse(panel.isConfirmingClear)
        XCTAssertEqual(store.records.map(\.id), [live])
        XCTAssertTrue(pin.isPinVisible)
        XCTAssertEqual(pin.historyRecordID, live)
    }

    func testEmptySearchAndExternalRemovalReturnToList() throws {
        XCTAssertEqual(panel.tableView.numberOfRows, 0)
        let id = try store.upsert(content: .text(NSAttributedString(string: "Long 中文 👩🏽‍💻")))
        XCTAssertEqual(panel.tableView.numberOfRows, 1)
        search("absent")
        XCTAssertTrue(panel.records.isEmpty)
        XCTAssertTrue(panel.scrollView.isHidden)
        search("中文")
        try select(id)
        try store.delete(id: id)
        XCTAssertNil(model.selection)
        XCTAssertTrue(panel.detailScrollView.isHidden)
        XCTAssertEqual(panel.searchField.stringValue, "中文")
    }

    func testAnnotatedImagePreviewAndCopyIncludeCropWithoutChangingHistory() throws {
        let view = ImagePinView(image: TestImage.make(width: 400, height: 200, color: .white))
        view.annotationStore.add(Annotation(tool: .highlight,
            points: [CGPoint(x: 100, y: 50), CGPoint(x: 300, y: 150)],
            style: AnnotationStyle(colorHex: "#FF0000", lineWidth: 3, fontSize: 18)))
        view.annotationStore.setCrop(CGRect(x: 100, y: 50, width: 200, height: 100))
        let state = view.captureState()
        let id = try store.upsert(content: state.content, annotationData: state.annotationData)
        let before = store.records
        try select(id)
        let image = try XCTUnwrap(panel.detailImageView.image)
        XCTAssertEqual(image.size.width / image.size.height, 2, accuracy: 0.02)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.pngData())))
        let pixel = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(pixel.redComponent, pixel.greenComponent + 0.2)
        try click("Copy")
        let copied = try XCTUnwrap(NSImage(pasteboard: pasteboard))
        XCTAssertEqual(copied.pixelSize, CGSize(width: 200, height: 100))
        XCTAssertEqual(store.records, before)
        XCTAssertEqual(manager.count, 0)
    }

    func testCorruptAnnotationsDoNotPreviewOrCopyAnUnannotatedImage() throws {
        let id = try store.upsert(content: .image(TestImage.make(width: 20, height: 20, color: .red)),
                                  annotationData: Data("invalid".utf8))
        pasteboard.setString("keep", forType: .string)
        try select(id)
        XCTAssertTrue(panel.detailScrollView.isHidden)
        var errors = 0
        manager.onHistoryError = { _ in errors += 1 }
        try click("Copy")
        XCTAssertEqual(errors, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep")
        XCTAssertNotNil(store.record(id: id))
    }

    func testLongTextDetailExtendsBeyondViewportForScrollingAndPlainTextUsesDynamicLabelColor() throws {
        let longText = (1...30).map { "Line \($0): searchable history detail content that wraps across multiple lines." }.joined(separator: "\n")
        // Simulate a plain-text record whose RTF payload was saved with a static black color.
        let staticBlack = NSAttributedString(string: longText, attributes: [
            .font: TextDefaults.font,
            .foregroundColor: NSColor.black
        ])
        let id = try store.upsert(content: .text(staticBlack), textMode: .plainText)
        try select(id)

        XCTAssertEqual(panel.detailScrollView.frame.height, 224)
        XCTAssertGreaterThan(panel.detailTextView.frame.height, panel.detailScrollView.contentSize.height + 100,
                             "long text must size taller than the 224pt scroll viewport so it can scroll")
        let color = panel.detailTextView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, .labelColor, "plain text preview must use dynamic labelColor rather than static RTF colors")
    }

    func testDetailPreviewRefreshesWhenPanelAppearanceChanges() throws {
        let id = try store.upsert(content: .image(TestImage.make(width: 120, height: 80, color: .init(srgbRed: 1, green: 0, blue: 0, alpha: 0.4))))
        try select(id)
        panel.view.appearance = NSAppearance(named: .aqua)
        (panel.view as? MenuBarPanelRootView)?.viewDidChangeEffectiveAppearance()
        let light = try XCTUnwrap(panel.detailImageView.image?.pngData())

        panel.view.appearance = NSAppearance(named: .darkAqua)
        (panel.view as? MenuBarPanelRootView)?.viewDidChangeEffectiveAppearance()
        let dark = try XCTUnwrap(panel.detailImageView.image?.pngData())
        XCTAssertNotEqual(light, dark, "appearance changes must re-render the history detail preview")
    }

    func testMissingOrCorruptImagePayloadReportsHistoryError() throws {
        let id = try store.upsert(content: .image(TestImage.make(width: 20, height: 20, color: .blue)))
        let imageURL = directory.appendingPathComponent(id.uuidString).appendingPathComponent("image.png")
        try Data("not-a-png".utf8).write(to: imageURL)

        var errors = 0
        manager.onHistoryError = { _ in errors += 1 }
        try select(id)
        XCTAssertTrue(panel.detailScrollView.isHidden)
        XCTAssertEqual(errors, 1)

        try click("Copy")
        XCTAssertEqual(errors, 2)
        XCTAssertNil(manager.repin(recordID: id))
        XCTAssertEqual(errors, 3)
    }
}
