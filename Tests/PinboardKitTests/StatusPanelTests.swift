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

    func testPopoverShrinksWhenReturningFromHistory() throws {
        anchor.performClick(nil)
        try assertPopoverFitsActivePage("initial-pins")
        try clickVisible("History")
        try assertPopoverFitsActivePage("history")
        try clickVisible("Pins")
        try assertPopoverFitsActivePage("returned-pins")
    }

    func testPopoverFitsRepeatedNavigationReopeningAndLiveListChanges() throws {
        anchor.performClick(nil)
        for cycle in 0..<3 {
            for index in 0..<8 {
                _ = manager.createPin(content: .text(NSAttributedString(string: "Pin \(index)")), textMode: .plainText)
            }
            try assertPopoverFitsActivePage("grown-pins-\(cycle)")
            try clickVisible("History")
            try assertPopoverFitsActivePage("shorter-history-\(cycle)")
            manager.closeAll()
            try assertPopoverFitsActivePage("history-after-inactive-pins-change-\(cycle)")
            try clickVisible("Pins")
            try assertPopoverFitsActivePage("empty-pins-\(cycle)")
            anchor.performClick(nil)
            anchor.performClick(nil)
            try assertPopoverFitsActivePage("reopened-pins-\(cycle)")
            for index in 0..<4 {
                _ = manager.createPin(content: .text(NSAttributedString(string: "Pin \(index)")), textMode: .plainText)
            }
            try assertPopoverFitsActivePage("regrown-pins-\(cycle)")
            try clickVisible("Close All")
            try assertPopoverFitsActivePage("closed-all-pins-\(cycle)")
        }
    }

    private func assertPopoverFitsActivePage(_ name: String,
                                            file: StaticString = #filePath, line: UInt = #line) throws {
        flushUpdates()
        let page = try XCTUnwrap(controller.popover.contentViewController, file: file, line: line)
        let window = try XCTUnwrap(page.view.window, file: file, line: line)
        window.contentView?.layoutSubtreeIfNeeded()
        let expected = page.preferredContentSize
        let pageInWindow = page.view.convert(page.view.bounds, to: nil)
        let topInset = window.frame.height - pageInWindow.maxY
        if let path = ProcessInfo.processInfo.environment["PINBOARD_TEST_ARTIFACTS"],
           let frameView = window.contentView?.superview {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let rep = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("popover-\(name).png"))
        }
        XCTAssertEqual(controller.popover.contentSize.height, expected.height, accuracy: 1,
                       "\(name): the outer popover must fit the active page", file: file, line: line)
        XCTAssertEqual(page.view.bounds.size, expected,
                       "\(name): the active page must not be stretched or clipped", file: file, line: line)
        XCTAssertLessThanOrEqual(window.frame.height - expected.height, 40,
                                 "\(name): only native border/arrow space may surround the page", file: file, line: line)
        XCTAssertLessThanOrEqual(topInset, 32,
                                 "\(name): unexpected blank space above the page (\(topInset) pt)", file: file, line: line)
    }

    func testPanelUsesCompactIconControlsWithAccessibleHelp() throws {
        controller.pinsViewController.reloadPins()
        let view = controller.pinsViewController.view
        view.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(view.frame.width, 400)
        for button in buttons(in: view) {
            XCTAssertTrue(button.title.isEmpty, "Actions should use icons: \(button.title)")
            XCTAssertNotNil(button.image)
            XCTAssertEqual(button.imagePosition, .imageOnly)
            XCTAssertFalse(button.toolTip?.isEmpty ?? true)
            XCTAssertFalse(button.accessibilityLabel()?.isEmpty ?? true)
            XCTAssertGreaterThanOrEqual(button.frame.width, 28)
            XCTAssertGreaterThanOrEqual(button.frame.height, 28)
        }
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
        try XCTUnwrap(buttons(in: controller.pinsViewController.view).first { $0.identifier?.rawValue == "History" }).performClick(nil)
        XCTAssertTrue(controller.popover.isShown)
        let history = try XCTUnwrap(controller.popover.contentViewController)
        XCTAssertFalse(history === controller.pinsViewController)
        XCTAssertTrue(history.view.window === window)
        try XCTUnwrap(buttons(in: history.view).first { $0.identifier?.rawValue == "Settings" }).performClick(nil)
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

    func testEscapeFromHistorySearchDismissesThePopover() throws {
        anchor.performClick(nil)
        try clickVisible("History")
        let history = try XCTUnwrap(controller.historyViewController)
        let window = try XCTUnwrap(history.view.window)
        window.makeFirstResponder(history.searchField)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.sendEvent(escape)
        XCTAssertFalse(controller.popover.isShown)
    }

    func testPinPreviewsRefreshWhenPanelAppearanceChanges() throws {
        _ = manager.createPin(content: .text(NSAttributedString(string: "Appearance preview")), textMode: .plainText)
        anchor.performClick(nil)
        let pins = controller.pinsViewController
        pins.view.appearance = NSAppearance(named: .aqua)
        flushUpdates()
        let light = try XCTUnwrap(pins.rows.first?.previewView.image?.pngData())
        pins.view.appearance = NSAppearance(named: .darkAqua)
        flushUpdates()
        XCTAssertNotEqual(light, pins.rows.first?.previewView.image?.pngData())
        XCTAssertEqual(manager.count, 1)
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
        try XCTUnwrap(buttons(in: controller.pinsViewController.view).first { $0.identifier?.rawValue == "History" }).performClick(nil)
        let history = try XCTUnwrap(controller.historyViewController)
        history.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(history.model?.selection, id)
        try XCTUnwrap(buttons(in: history.view).first { $0.identifier?.rawValue == "Copy" }).performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "Saved note")
        try XCTUnwrap(buttons(in: history.view).first { $0.identifier?.rawValue == "Pin Again" }).performClick(nil)
        flushUpdates()
        XCTAssertTrue(controller.popover.isShown)
        XCTAssertTrue(history.view.window === window)
        XCTAssertEqual(manager.count, 1)
        try XCTUnwrap(buttons(in: history.view).first { $0.identifier?.rawValue == "Back" }).performClick(nil)
        try XCTUnwrap(buttons(in: history.view).first { $0.identifier?.rawValue == "Pins" }).performClick(nil)
        XCTAssertTrue(controller.popover.contentViewController === controller.pinsViewController)
        XCTAssertEqual(controller.pinsViewController.rows.count, 1)
        XCTAssertTrue(controller.popover.isShown)
    }

    func testMenuBarStatesRenderInLightAndDarkAppearance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let originalAppearance = NSApp.appearance
        defer {
            controller.popover.close()
            manager.closeAll()
            manager.historyStore = nil
            NSApp.appearance = originalAppearance
            try? FileManager.default.removeItem(at: directory)
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            controller.popover.close()
            manager.closeAll()
            NSApp.appearance = NSAppearance(named: appearance)
            let store = HistoryStore(directory: directory.appendingPathComponent(name))
            manager.historyStore = store
            controller = MenuBarController(manager: manager, onOpenSettings: {})
            anchor.target = controller
            anchor.performClick(nil)
            try capture("empty-pins-\(name)")
            try clickVisible("History")
            let history = try XCTUnwrap(controller.historyViewController)
            try capture("empty-history-\(name)")
            let textID = try store.upsert(content: .text(NSAttributedString(string:
                "# Release checklist\n\n- Verify the menu bar\n- Preview saved content\n\n**Ready to ship.**")), textMode: .markdown)
            let picture = ImagePinView(image: TestImage.make(width: 400, height: 240, color: .systemTeal))
            picture.annotationStore.add(Annotation(tool: .arrow,
                points: [CGPoint(x: 60, y: 60), CGPoint(x: 310, y: 175)],
                style: AnnotationStyle(colorHex: "#FFFFFF", lineWidth: 6, fontSize: 18)))
            let state = picture.captureState()
            let imageID = try store.upsert(content: state.content, annotationData: state.annotationData)
            _ = try store.upsert(content: .text(NSAttributedString(string: String(repeating: "设计笔记 👩🏽‍💻 A long title ", count: 8))))
            try capture("history-\(name)")
            history.searchField.stringValue = "checklist"
            history.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: history.searchField))
            XCTAssertEqual(history.records.map(\.id), [textID])
            try capture("search-\(name)")
            history.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            try capture("text-detail-\(name)")
            try clickVisible("Back")
            history.searchField.stringValue = "no-match"
            history.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: history.searchField))
            try capture("empty-search-\(name)")
            history.searchField.stringValue = ""
            history.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: history.searchField))
            history.tableView.selectRowIndexes(IndexSet(integer: try XCTUnwrap(history.records.firstIndex { $0.id == imageID })), byExtendingSelection: false)
            try capture("image-detail-\(name)")
            try clickVisible("Back")
            try clickVisible("Clear History")
            try capture("clear-confirmation-\(name)")
            try clickVisible("Cancel")
            try clickVisible("Pins")
            _ = manager.createPin(content: .text(NSAttributedString(string: "Meeting notes\nShip the menu bar update")), textMode: .plainText)
            let imagePin = manager.createPin(content: .image(TestImage.make(width: 400, height: 240, color: .systemTeal)))
            imagePin.hidePin()
            flushUpdates()
            try capture("pins-\(name)")
            for index in 0..<12 {
                _ = manager.createPin(content: .text(NSAttributedString(string: "\(index) · " + String(repeating: "Long title 中文 👩🏽‍💻 ", count: 12))), textMode: .plainText)
            }
            flushUpdates()
            let pins = controller.pinsViewController
            pins.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 180))
            try capture("long-pins-\(name)")
            XCTAssertLessThanOrEqual(pins.view.bounds.height, 560)
            try clickVisible("History")
            history.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
            try capture("long-history-\(name)")
            let origin = history.scrollView.contentView.bounds.origin.y
            try store.upsert(id: textID, content: .text(NSAttributedString(string: "Updated while open")))
            XCTAssertEqual(history.scrollView.contentView.bounds.origin.y, origin, accuracy: 1)
        }
    }

    private func clickVisible(_ identifier: String) throws {
        let root = try XCTUnwrap(controller.popover.contentViewController?.view)
        try XCTUnwrap(buttons(in: root).first { $0.identifier?.rawValue == identifier && !$0.isHiddenOrHasHiddenAncestor }).performClick(nil)
    }

    private func capture(_ name: String) throws {
        flushUpdates()
        XCTAssertTrue(controller.popover.isShown)
        let view = try XCTUnwrap(controller.popover.contentViewController?.view)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        // NSSearchField owns native search/cancel buttons with internal cell
        // titles. The app's navigation and action controls are PanelIconButton.
        let actions = buttons(in: view).compactMap { $0 as? PanelIconButton }
        XCTAssertGreaterThanOrEqual(actions.count, 5)
        for button in actions where !button.isHiddenOrHasHiddenAncestor {
            XCTAssertTrue(button.title.isEmpty, "\(name): \(type(of: button)), title=\(button.title)")
            XCTAssertNotNil(button.image)
            XCTAssertFalse(button.toolTip?.isEmpty ?? true, "\(name): \(type(of: button)), title=\(button.title)")
            XCTAssertFalse(button.accessibilityLabel()?.isEmpty ?? true)
            if button.enclosingScrollView == nil {
                XCTAssertTrue(view.bounds.contains(button.convert(button.bounds, to: view)), "\(name): \(button.identifier?.rawValue ?? "")")
            }
        }
        let navigation = buttons(in: view).filter { ["Pins", "History"].contains($0.identifier?.rawValue ?? "") }
        XCTAssertEqual(navigation.filter { $0.state == .on }.count, 1)
        if let path = ProcessInfo.processInfo.environment["PINBOARD_TEST_ARTIFACTS"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(name).png"))
        }
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
