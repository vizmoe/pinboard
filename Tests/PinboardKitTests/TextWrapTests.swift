import AppKit
import XCTest
@testable import PinboardKit

final class TextWrapTests: XCTestCase {
    private var manager: PinWindowManager { PinWindowManager.shared }

    override func tearDown() {
        manager.closeAll()
        super.tearDown()
    }

    private func makeLongTextPin() throws -> (PinWindowController, TextPinView) {
        let body = String(repeating: "Pinboard soft wrap verification sentence. ", count: 12)
        let text = NSAttributedString(string: body, attributes: ClipboardReader.defaultTextAttributes())
        let pin = manager.createPin(content: .text(text))
        return (pin, try XCTUnwrap(pin.contentView as? TextPinView))
    }

    /// Deliberately does nothing: the live resize loop calls
    /// `setFrame(_:display:)` inside a modal event loop, so the pin must
    /// re-wrap synchronously without any help from the caller.
    private func layout(_ pin: PinWindowController) {}

    func testWrapWidthFollowsWindowWidth() throws {
        let (pin, view) = try makeLongTextPin()
        let padding = CGFloat(Preferences.shared.textPadding)

        pin.setFrame(NSRect(x: 100, y: 100, width: 600, height: 240))
        layout(pin)
        let wideWrap = view.textWrapWidth
        let wideHeight = view.laidOutTextFrame.height
        XCTAssertEqual(view.laidOutTextFrame.width, 600, accuracy: 2, "text view tracks the window width")
        XCTAssertEqual(wideWrap, 600 - padding * 2, accuracy: 2, "container wraps inside the padding")

        pin.setFrame(NSRect(x: 100, y: 100, width: 240, height: 240))
        layout(pin)
        XCTAssertEqual(view.laidOutTextFrame.width, 240, accuracy: 2)
        XCTAssertEqual(view.textWrapWidth, 240 - padding * 2, accuracy: 2)
        XCTAssertLessThan(view.textWrapWidth, wideWrap, "narrowing the window must narrow the wrap width")
        XCTAssertGreaterThan(view.laidOutTextFrame.height, wideHeight, "narrower window needs more lines")

        pin.setFrame(NSRect(x: 100, y: 100, width: 600, height: 240))
        layout(pin)
        XCTAssertEqual(view.textWrapWidth, wideWrap, accuracy: 2, "widening re-wraps back")
        XCTAssertEqual(view.laidOutTextFrame.height, wideHeight, accuracy: 2)
    }

    func testTextNeverScrollsHorizontally() throws {
        let (pin, view) = try makeLongTextPin()
        pin.setFrame(NSRect(x: 0, y: 0, width: 200, height: 160))
        layout(pin)
        XCTAssertLessThanOrEqual(view.laidOutTextFrame.width, 200 + 1, "no horizontal overflow")
    }

    func testFontSizeIsUnaffectedByResizing() throws {
        let (pin, view) = try makeLongTextPin()
        let before = view.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        pin.setFrame(NSRect(x: 0, y: 0, width: 220, height: 500))
        layout(pin)
        pin.zoom(by: 1.8)
        layout(pin)
        let after = view.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(before?.pointSize, after?.pointSize, "resizing must not change the font size")
    }
}
