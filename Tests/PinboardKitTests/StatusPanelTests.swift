import AppKit
import XCTest
@testable import PinboardKit

final class StatusPanelTests: XCTestCase {
    private let manager = PinWindowManager.shared
    private var controller: MenuBarController!
    private var host: NSWindow!
    private var anchor: NSButton!

    override func setUp() {
        super.setUp()
        manager.closeAll()
        controller = MenuBarController(manager: manager, onOpenSettings: {})
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        host = NSWindow(contentRect: NSRect(x: screen.midX - 50, y: screen.maxY - 120, width: 100, height: 40),
                        styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        anchor = NSButton(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        anchor.title = "Pinboard"
        anchor.target = controller.statusItem.button?.target
        anchor.action = controller.statusItem.button?.action
        host.contentView = anchor
        host.orderFrontRegardless()
    }

    override func tearDown() {
        controller.popover.close()
        manager.onChange = nil
        manager.closeAll()
        host.close()
        controller = nil
        host = nil
        anchor = nil
        super.tearDown()
    }

    private func flushUpdates() {
        let updated = expectation(description: "next main queue update")
        DispatchQueue.main.async { updated.fulfill() }
        wait(for: [updated], timeout: 2)
    }

    private func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }

    func testStatusItemOpensAPanelInsteadOfANestedMenu() throws {
        XCTAssertNil(controller.statusItem.menu)
        let statusButton = try XCTUnwrap(controller.statusItem.button)
        XCTAssertTrue(statusButton.target === controller)
        XCTAssertNotNil(statusButton.action)
        anchor.performClick(nil)
        XCTAssertTrue(controller.popover.isShown)
        anchor.performClick(nil)
        XCTAssertFalse(controller.popover.isShown)
    }

    func testOpenPanelTracksExternalChangesAndKeepsOpenAfterPinActions() throws {
        let first = manager.createPin(content: .text(NSAttributedString(string: "first")), textMode: .plainText)
        anchor.performClick(nil)
        XCTAssertTrue(controller.popover.isShown)
        let panel = controller.pinsViewController
        let second = manager.createPin(content: .text(NSAttributedString(string: "second")), textMode: .plainText)
        flushUpdates()
        XCTAssertEqual(panel.rows.map(\.pinID), [first.id, second.id])
        panel.rows[1].hideButton.performClick(nil)
        XCTAssertTrue(controller.popover.isShown)
        XCTAssertFalse(second.isPinVisible)
        panel.rows[1].showButton.performClick(nil)
        XCTAssertTrue(controller.popover.isShown)
        XCTAssertTrue(second.isPinVisible)
        panel.rows[1].closeButton.performClick(nil)
        XCTAssertTrue(controller.popover.isShown)
        XCTAssertEqual(panel.rows.map(\.pinID), [first.id])
        first.closePin()
        flushUpdates()
        XCTAssertTrue(panel.rows.isEmpty)
        XCTAssertEqual(panel.countLabel.stringValue, "0 total · 0 visible")
        XCTAssertTrue(controller.popover.isShown)
    }

    func testContentChangeRefreshesWithoutAHistoryStore() throws {
        let pin = manager.createPin(content: .text(NSAttributedString(string: "old")), textMode: .plainText)
        let text = try XCTUnwrap(pin.contentView as? TextPinView)
        text.beginEditing(at: nil)
        anchor.performClick(nil)
        // Modify storage and signal the same content notification used by edits
        // and image arrivals, without moving keyboard focus away from the panel.
        text.editableTextView.textStorage?.setAttributedString(NSAttributedString(string: "new"))
        pin.contentDidChange()
        flushUpdates()
        XCTAssertEqual(controller.pinsViewController.rows.first?.titleLabel.stringValue, "new")
    }

    func testHistoryStaysInTheSamePopoverAndSettingsDismissesIt() throws {
        controller.popover.close()
        manager.onChange = nil
        var settings = 0
        controller = MenuBarController(manager: manager, onOpenSettings: { settings += 1 })
        anchor.target = controller
        anchor.performClick(nil)
        let window = controller.pinsViewController.view.window
        try XCTUnwrap(buttons(in: controller.pinsViewController.view).first { $0.title == "History" }).performClick(nil)
        XCTAssertTrue(controller.popover.isShown)
        let history = try XCTUnwrap(controller.popover.contentViewController)
        XCTAssertFalse(history === controller.pinsViewController)
        XCTAssertTrue(history.view.window === window)
        try XCTUnwrap(buttons(in: history.view).first { $0.title == "Settings" }).performClick(nil)
        XCTAssertEqual(settings, 1)
        XCTAssertFalse(controller.popover.isShown)
    }

    func testEscapeDismissesThePanel() throws {
        anchor.performClick(nil)
        XCTAssertTrue(controller.popover.isShown)
        let window = try XCTUnwrap(controller.pinsViewController.view.window)
        window.makeKey()
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.sendEvent(escape)
        XCTAssertFalse(controller.popover.isShown)
    }

    func testHistoryActionsAndReturnUseOnePopoverWindow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer {
            manager.closeAll()
            manager.historyStore = nil
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }
        let store = HistoryStore(directory: directory)
        manager.historyStore = store
        let id = try store.upsert(content: .text(NSAttributedString(string: "Saved note")), textMode: .plainText)
        controller = MenuBarController(manager: manager, historyPasteboard: pasteboard, onOpenSettings: {})
        anchor.target = controller
        anchor.performClick(nil)
        let window = controller.pinsViewController.view.window
        try XCTUnwrap(buttons(in: controller.pinsViewController.view).first { $0.title == "History" }).performClick(nil)
        let history = try XCTUnwrap(controller.historyViewController)
        history.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(history.model?.selection, id)
        try XCTUnwrap(buttons(in: history.view).first { $0.title == "Copy" }).performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "Saved note")
        try XCTUnwrap(buttons(in: history.view).first { $0.title == "Pin Again" }).performClick(nil)
        flushUpdates()
        XCTAssertTrue(controller.popover.isShown)
        XCTAssertTrue(history.view.window === window)
        XCTAssertEqual(manager.count, 1)
        try XCTUnwrap(buttons(in: history.view).first { $0.title == "Back" }).performClick(nil)
        try XCTUnwrap(buttons(in: history.view).first { $0.title == "Pins" }).performClick(nil)
        XCTAssertTrue(controller.popover.contentViewController === controller.pinsViewController)
        XCTAssertEqual(controller.pinsViewController.rows.count, 1)
        XCTAssertTrue(controller.popover.isShown)
    }

    func testPanelSnapshotHasVisibleControlsAndPreviews() throws {
        _ = manager.createPin(content: .text(NSAttributedString(string: "Meeting notes\nShip the pins panel")), textMode: .plainText)
        let image = manager.createPin(content: .image(TestImage.make(width: 400, height: 240, color: .systemBlue)))
        image.hidePin()
        anchor.performClick(nil)
        XCTAssertTrue(controller.popover.isShown)
        let view = controller.pinsViewController.view
        flushUpdates()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        for button in buttons(in: view) {
            let frame = button.convert(button.bounds, to: view)
            XCTAssertTrue(view.bounds.contains(frame), "\(button.title) must fit inside the panel: \(frame)")
            XCTAssertGreaterThan(frame.width, 20)
        }
        if let path = ProcessInfo.processInfo.environment["PINBOARD_TEST_ARTIFACTS"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("pins-panel.png"))
        }
    }
}
