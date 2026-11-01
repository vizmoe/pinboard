import AppKit
import XCTest
@testable import PinboardKit

final class PinInteractionTests: XCTestCase {
    private var manager: PinWindowManager { .shared }
    override func tearDown() {
        manager.closeAll()
        super.tearDown()
    }

    func testCopyAndCloseWritesCanonicalSourceAndClosesOnlyThatPin() throws {
        let source = "# Title\n\n- [x] task"
        let pin = manager.createPin(content: .text(NSAttributedString(string: source)), textMode: .markdown)
        let other = manager.createPin(content: .text(NSAttributedString(string: "keep")))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pin.copyAndClose(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), source)
        XCTAssertNil(manager.pin(with: pin.id))
        XCTAssertTrue(manager.pin(with: other.id) === other)
    }

    func testCopyAndCloseCommitsActiveTextEdits() throws {
        let pin = manager.createPin(content: .text(NSAttributedString(string: "old")), textMode: .plainText)
        let view = try XCTUnwrap(pin.contentView as? TextPinView)
        view.beginEditing(at: nil)
        view.editableTextView.insertText("new", replacementRange: NSRange(location: 0, length: 3))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pin.copyAndClose(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "new")
    }

    func testRepeatedPinsAnchorAtTheSamePointerWithoutCascade() throws {
        let previous = Preferences.shared.placeNewWindowAtMouse
        Preferences.shared.placeNewWindowAtMouse = true
        defer { Preferences.shared.placeNewWindowAtMouse = previous }
        let content = PinContent.text(NSAttributedString(string: "anchor"))
        let screen = try XCTUnwrap(NSScreen.main)
        let anchor = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        let first = manager.createPin(content: content, at: anchor)
        let second = manager.createPin(content: content, at: anchor)
        XCTAssertEqual(first.panel.frame, second.panel.frame)
        let expected = first.idealFrame(anchoredAt: anchor, on: screen)
        XCTAssertEqual(first.panel.frame.minX, expected.minX, accuracy: 1)
        XCTAssertEqual(first.panel.frame.maxY, expected.maxY, accuracy: 1)
    }

    func testDoubleClickEventsCopyAndCloseIdleTextAndImage() throws {
        // Preserve the real clipboard because this tests the actual event path.
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            let restored = saved.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(restored)
        }
        let text = manager.createPin(content: .text(NSAttributedString(string: "double click")), textMode: .plainText)
        let textView = try XCTUnwrap(text.contentView as? TextPinView)
        let image = manager.createPin(content: .image(TestImage.make(width: 100, height: 80)))
        for (pin, view) in [(text, textView.editableTextView as NSView), (image, image.contentView as NSView)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 30, y: 30),
                modifierFlags: [], timestamp: 0, windowNumber: pin.panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
            view.mouseDown(with: event)
            XCTAssertNil(manager.pin(with: pin.id))
            if pin.kind == .text { XCTAssertEqual(pasteboard.string(forType: .string), "double click") }
            else { XCTAssertTrue(pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)) }
        }
    }

    func testPanelListsHiddenPinsAndClosesTheChosenPin() throws {
        let first = manager.createPin(content: .text(NSAttributedString(string: "first")))
        let second = manager.createPin(content: .text(NSAttributedString(string: "second")))
        second.hidePin()
        let controller = MenuBarController(manager: manager, onOpenSettings: {})
        let panel = controller.pinsViewController
        panel.reloadPins()
        XCTAssertEqual(panel.rows.count, 2)
        XCTAssertEqual(panel.rows[0].visibilityLabel.stringValue, "Visible")
        XCTAssertEqual(panel.rows[1].visibilityLabel.stringValue, "Hidden")
        panel.rows[1].closeButton.performClick(nil)
        XCTAssertTrue(manager.pin(with: first.id) === first)
        XCTAssertNil(manager.pin(with: second.id))
    }
}
