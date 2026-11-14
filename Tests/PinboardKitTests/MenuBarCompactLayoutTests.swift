import AppKit
import XCTest
@testable import PinboardKit

final class MenuBarCompactLayoutTests: XCTestCase {
    private let manager = PinWindowManager.shared

    override func setUp() {
        super.setUp()
        manager.closeAll()
    }

    override func tearDown() {
        manager.closeAll()
        manager.historyStore = nil
        manager.onChange = nil
        super.tearDown()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func visibleLabels(_ view: NSView) -> [String] {
        descendants(view).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap {
            guard let field = $0 as? NSTextField, !(field is NSSearchField), !field.stringValue.isEmpty else { return nil }
            return field.stringValue
        }
    }

    private func assertCompactIcons(_ view: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
        view.layoutSubtreeIfNeeded()
        let buttons = descendants(view).compactMap { $0 as? PanelIconButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertFalse(buttons.isEmpty, file: file, line: line)
        for button in buttons {
            XCTAssertTrue(button.title.isEmpty, file: file, line: line)
            XCTAssertNotNil(button.image, file: file, line: line)
            XCTAssertFalse(button.toolTip?.isEmpty ?? true, file: file, line: line)
            XCTAssertFalse(button.accessibilityLabel()?.isEmpty ?? true, file: file, line: line)
            XCTAssertTrue((24...26).contains(button.frame.width), "\(button.actionName) width", file: file, line: line)
            XCTAssertTrue((24...26).contains(button.frame.height), "\(button.actionName) height", file: file, line: line)
            XCTAssertTrue(view.bounds.contains(button.convert(button.bounds, to: view)), file: file, line: line)
        }
    }

    func testEmptyPinsShowsGuidanceUnderAStableHeader() throws {
        let panel = PinsPanelViewController(manager: manager)
        panel.reloadPins()
        XCTAssertTrue(panel.footer.isHidden)
        XCTAssertFalse(panel.emptyStateView.isHidden)
        XCTAssertTrue(visibleLabels(panel.view).contains("No Pins"))
        XCTAssertLessThanOrEqual(panel.preferredContentSize.width, 320)
        XCTAssertLessThanOrEqual(panel.preferredContentSize.height, 180)
        try assertCompactIcons(panel.view)
        let headerButtons = descendants(panel.toolbar)
            .compactMap { $0 as? NSButton }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertEqual(Set(headerButtons.compactMap { $0.identifier?.rawValue }),
                       Set(["Pins", "History", "Pin Clipboard", "App Menu"]))
        XCTAssertEqual(panel.toolbar.pinsButton.title, "Pins")
        XCTAssertEqual(panel.toolbar.historyButton.title, "History")
        XCTAssertEqual(panel.toolbar.pasteButton.title, "Pin")
        XCTAssertEqual(
            Set(panel.toolbar.appMenu.items.compactMap { $0.identifier?.rawValue }),
            Set(["Settings", "Quit"])
        )
        let headerCenters = headerButtons.map { $0.convert($0.bounds, to: panel.view).midY }
        XCTAssertEqual(try XCTUnwrap(headerCenters.max()), try XCTUnwrap(headerCenters.min()), accuracy: 1)

        // Navigation leads on the left; the primary action and menu trail on the right, with equal margins.
        let navRect = panel.toolbar.navCapsule.convert(panel.toolbar.navCapsule.bounds, to: panel.view)
        let pasteRect = panel.toolbar.pasteButton.convert(panel.toolbar.pasteButton.bounds, to: panel.view)
        let menuRect = panel.toolbar.menuButton.convert(panel.toolbar.menuButton.bounds, to: panel.view)
        XCTAssertEqual(navRect.minX, panel.view.bounds.width - menuRect.maxX, accuracy: 0.5)
        XCTAssertLessThan(navRect.maxX, pasteRect.minX)
        XCTAssertLessThan(pasteRect.maxX, menuRect.minX)

        // Adding a pin keeps the header anchored, badges the Pins tab and reveals the action footer.
        _ = manager.createPin(content: .text(NSAttributedString(string: "Note")), textMode: .plainText)
        panel.reloadPins()
        XCTAssertFalse(panel.footer.isHidden)
        XCTAssertTrue(panel.emptyStateView.isHidden)
        XCTAssertEqual(panel.toolbar.pinsButton.badge, "1")
        XCTAssertEqual(panel.footer.statusLabel.stringValue, "1 pin")
        XCTAssertEqual(
            panel.toolbar.navCapsule.convert(panel.toolbar.navCapsule.bounds, to: panel.view).origin,
            navRect.origin
        )
        let footerButtons = descendants(panel.footer)
            .compactMap { $0 as? PanelIconButton }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertEqual(Set(footerButtons.map(\.actionName)), Set(["Toggle Visibility", "Close All"]))
        let footerCenters = footerButtons.map { $0.convert($0.bounds, to: panel.view).midY }
        XCTAssertEqual(try XCTUnwrap(footerCenters.max()), try XCTUnwrap(footerCenters.min()), accuracy: 1)
    }

    func testPinRowsShowOnlyActualContentText() throws {
        _ = manager.createPin(content: .text(NSAttributedString(string: "Actual note")), textMode: .plainText)
        _ = manager.createPin(content: .text(NSAttributedString(string: " \n\t")), textMode: .plainText)
        let image = manager.createPin(content: .image(TestImage.make(width: 40, height: 30, color: .red)))
        image.hidePin()
        let panel = PinsPanelViewController(manager: manager)
        panel.reloadPins()
        XCTAssertEqual(panel.rows.flatMap { visibleLabels($0) }, ["Actual note"])
        XCTAssertEqual(panel.footer.statusLabel.stringValue, "3 pins · 1 hidden")
        XCTAssertTrue(panel.rows[2].accessibilityLabel()?.contains("Hidden") == true)
        XCTAssertTrue(panel.rows[1].visibilityButton.accessibilityLabel()?.contains("Empty Text") == true)
        XCTAssertNotNil(panel.rows[2].previewView.image)
        try assertCompactIcons(panel.view)
    }

    func testHistoryRowsShowOnlyContentAndStatesExplainThemselves() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let model = HistoryViewModel(store: store, manager: manager, pasteboard: pasteboard)
        let panel = HistoryPanelViewController(model: model)
        panel.reloadHistory()
        XCTAssertTrue(visibleLabels(panel.view).contains("No History"))
        XCTAssertTrue(panel.searchField.isHidden, "An empty history has nothing to search")
        XCTAssertEqual(panel.searchField.placeholderString, "Search History")
        XCTAssertEqual(panel.searchField.accessibilityLabel(), "Search history")
        XCTAssertLessThanOrEqual(panel.preferredContentSize.height, 180)
        try assertCompactIcons(panel.view)

        let textID = try store.upsert(content: .text(NSAttributedString(string: "Saved note")))
        let imageID = try store.upsert(content: .image(TestImage.make(width: 40, height: 30, color: .blue)))
        XCTAssertFalse(panel.searchField.isHidden)
        XCTAssertEqual(panel.footer.statusLabel.stringValue, "2 items")
        for (index, record) in panel.records.enumerated() {
            let row = try XCTUnwrap(panel.tableView(panel.tableView, viewFor: panel.tableView.tableColumns.first, row: index))
            XCTAssertEqual(visibleLabels(row), record.id == textID ? ["Saved note"] : [])
            XCTAssertFalse(row.accessibilityLabel()?.isEmpty ?? true)
        }
        model.selection = textID
        panel.reloadHistory()
        XCTAssertTrue(visibleLabels(panel.view).isEmpty)
        XCTAssertEqual(panel.detailTextView.string, "Saved note")
        XCTAssertLessThanOrEqual(panel.preferredContentSize.height, 150, "A short preview must not reserve a large empty body")
        try assertCompactIcons(panel.view)
        model.selection = nil
        panel.reloadHistory()
        let clear = try XCTUnwrap(descendants(panel.view).compactMap { $0 as? PanelIconButton }.first { $0.actionName == "Clear History" })
        clear.performClick(nil)
        XCTAssertTrue(panel.isConfirmingClear)
        XCTAssertEqual(visibleLabels(panel.footer), ["Clear all history?"])
        XCTAssertNotNil(store.record(id: imageID), "Requesting confirmation must not clear history")
        let confirm = try XCTUnwrap(descendants(panel.view).compactMap { $0 as? PanelIconButton }.first { $0.actionName == "Confirm Clear" })
        XCTAssertTrue(confirm.toolTip?.contains("permanently") == true)
        XCTAssertTrue(confirm.accessibilityLabel()?.contains("open pins") == true)
        try assertCompactIcons(panel.view)
    }
}
