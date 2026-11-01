import AppKit
import XCTest
@testable import PinboardKit

final class URLCommandRouterTests: XCTestCase {
    func testParsesHostAndPathForms() {
        XCTAssertEqual(PinboardCommand(rawValue: "paste"), .paste)
        XCTAssertFalse(URLCommandRouter.handle(URL(string: "pinboard://unknown")!))
        XCTAssertFalse(URLCommandRouter.handle(URL(string: "other://paste")!))
    }
}

final class PinWindowManagerTests: XCTestCase {
    private var manager: PinWindowManager { PinWindowManager.shared }

    override func tearDown() {
        manager.closeAll()
        super.tearDown()
    }

    private func textContent(_ string: String = "pin") -> PinContent {
        .text(NSAttributedString(string: string, attributes: ClipboardReader.defaultTextAttributes()))
    }

    func testCreateHideShowKeepsWindowsAlive() {
        let first = manager.createPin(content: textContent("第一个"))
        let second = manager.createPin(content: textContent("第二个"))
        XCTAssertEqual(manager.count, 2)
        XCTAssertEqual(manager.visibleCount, 2)

        let frame = first.panel.frame
        manager.hideAll()
        XCTAssertEqual(manager.count, 2, "hiding must not destroy pins")
        XCTAssertEqual(manager.visibleCount, 0)

        manager.showAll()
        XCTAssertEqual(manager.visibleCount, 2)
        XCTAssertEqual(first.panel.frame, frame, "frames survive hide/show")
        XCTAssertEqual(second.contentView.currentContent().kind, .text)
    }

    func testToggleSemantics() {
        manager.closeAll()
        manager.toggleAll()
        XCTAssertEqual(manager.count, 0, "toggle with no pins must not create one")

        manager.createPin(content: textContent())
        manager.toggleAll()
        XCTAssertEqual(manager.visibleCount, 0)
        manager.toggleAll()
        XCTAssertEqual(manager.visibleCount, 1)

        manager.hideAll()
        manager.hideAll()
        XCTAssertEqual(manager.visibleCount, 0, "repeated hide is stable")
        manager.showAll()
        manager.showAll()
        XCTAssertEqual(manager.visibleCount, 1, "repeated show is stable")
    }

    func testPinsAreIndependent() {
        let first = manager.createPin(content: textContent("A"))
        let second = manager.createPin(content: textContent("B"))
        first.hidePin()
        XCTAssertFalse(first.isPinVisible)
        XCTAssertTrue(second.isPinVisible)
        XCTAssertNotEqual(first.id, second.id)
        second.setFrame(NSRect(x: first.panel.frame.minX + 30, y: first.panel.frame.minY,
                               width: second.panel.frame.width, height: second.panel.frame.height))
        XCTAssertNotEqual(first.panel.frame.origin, second.panel.frame.origin, "pins move independently")

        first.closePin()
        XCTAssertEqual(manager.count, 1)
        XCTAssertTrue(second.isPinVisible)
    }

    func testTextPinIsTransparentByDefault() throws {
        let pin = manager.createPin(content: textContent("透明"))
        let view = try XCTUnwrap(pin.contentView as? TextPinView)
        XCTAssertFalse(pin.panel.isOpaque)
        XCTAssertEqual(pin.panel.backgroundColor, NSColor.clear)
        XCTAssertFalse(pin.rootView.drawsBackground)
        XCTAssertFalse(pin.rootView.drawsBorder)
        XCTAssertFalse(pin.panel.hasShadow, "a shadow would trace the glyphs")
        XCTAssertTrue(view.isFullyTransparent)

        pin.setBackgroundVisible(true)
        XCTAssertTrue(pin.rootView.drawsBackground)
        XCTAssertEqual(pin.panel.hasShadow, Preferences.shared.showShadow)
    }

    func testImagePinKeepsItsShadow() {
        let pin = manager.createPin(content: .image(TestImage.make(width: 100, height: 80)))
        XCTAssertEqual(pin.panel.hasShadow, Preferences.shared.showShadow)
    }

    func testExplicitTextBackgroundAttributesSurvive() throws {
        let highlighted = NSAttributedString(string: "高亮文字", attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .backgroundColor: NSColor.systemYellow
        ])
        let pin = manager.createPin(content: .text(highlighted))
        guard case .text(let stored) = pin.contentView.currentContent() else {
            return XCTFail("expected text content")
        }
        let background = stored.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(background, "window transparency must not strip text attributes")
    }

    func testOpacityIsPerPinAndSnapshotted() throws {
        let first = manager.createPin(content: textContent("one"))
        let second = manager.createPin(content: textContent("two"))
        XCTAssertEqual(first.panel.alphaValue, 1.0, accuracy: 0.001, "new pins start fully opaque")

        first.opacity = 0.4
        XCTAssertEqual(first.panel.alphaValue, 0.4, accuracy: 0.001)
        XCTAssertEqual(second.panel.alphaValue, 1.0, accuracy: 0.001,
                       "one pin's opacity must not affect another")

        let snapshot = first.snapshot()
        XCTAssertEqual(snapshot.opacity, 0.4, accuracy: 0.001)

        // Preference changes must not stomp the per-pin value.
        first.applyPreferences()
        XCTAssertEqual(first.panel.alphaValue, 0.4, accuracy: 0.001)
    }

    func testTextPinKeepsRichTextThroughSnapshot() throws {
        let attributed = NSMutableAttributedString(string: "粗体", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 22),
            .foregroundColor: NSColor.systemGreen
        ])
        attributed.append(NSAttributedString(string: "普通", attributes: [.font: NSFont.systemFont(ofSize: 12)]))

        let pin = manager.createPin(content: .text(attributed))
        let snapshot = pin.snapshot()
        XCTAssertEqual(snapshot.kind, .text)
        XCTAssertNotNil(snapshot.rtfData)

        guard case .text(let restored)? = snapshot.makeContent() else {
            return XCTFail("snapshot must restore rich text")
        }
        XCTAssertEqual(restored.string, "粗体普通")
        let font = restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, 22)
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func testImagePinSizesForRetinaAndExportsFullResolution() throws {
        let pixels = CGSize(width: 1200, height: 800)
        let data = try XCTUnwrap(TestImage.make(width: 1200, height: 800).pngData())
        let fromPasteboard = try XCTUnwrap(NSImage(data: data))
        XCTAssertEqual(fromPasteboard.pixelSize.width, pixels.width, accuracy: 0.5)

        let pin = manager.createPin(content: .image(fromPasteboard))
        let view = try XCTUnwrap(pin.contentView as? ImagePinView)
        let scale = (pin.panel.screen ?? NSScreen.underMouse)?.backingScaleFactor ?? 2
        XCTAssertEqual(view.naturalPointSize.width, pixels.width / scale, accuracy: 1)

        pin.setFrame(NSRect(x: 100, y: 100, width: 320, height: 90))
        let exported = view.renderedImage()
        XCTAssertEqual(exported.pixelSize.width, pixels.width, accuracy: 1, "export keeps original pixels")
        XCTAssertEqual(exported.pixelSize.height, pixels.height, accuracy: 1)
    }

    func testFreeResizeIsNotConstrainedByImageRatio() throws {
        let pin = manager.createPin(content: .image(TestImage.make(width: 400, height: 400)))
        XCTAssertFalse(pin.isAspectLocked, "aspect lock is opt-in")
        pin.setFrame(NSRect(x: 0, y: 0, width: 500, height: 120))
        XCTAssertEqual(pin.panel.frame.width, 500)
        XCTAssertEqual(pin.panel.frame.height, 120)
    }

    func testZoomScalesUniformlyAroundCentre() {
        let pin = manager.createPin(content: textContent("zoom"))
        pin.setFrame(NSRect(x: 200, y: 200, width: 300, height: 200))
        let centre = CGPoint(x: pin.panel.frame.midX, y: pin.panel.frame.midY)
        pin.zoom(by: 1.5)
        XCTAssertEqual(pin.panel.frame.width / pin.panel.frame.height, 1.5, accuracy: 0.02)
        XCTAssertEqual(pin.panel.frame.midX, centre.x, accuracy: 1)
        XCTAssertEqual(pin.panel.frame.midY, centre.y, accuracy: 1)

        pin.zoom(by: 0.0001)
        XCTAssertGreaterThanOrEqual(pin.panel.frame.width, pin.contentView.minimumPinSize.width - 1)
    }
}

final class PinRootViewTests: XCTestCase {
    func testResizeHotZonesMatchCursorFeedback() {
        let view = PinRootView()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)

        XCTAssertEqual(view.resizeEdge(at: NSPoint(x: 150, y: 100)), [])
        XCTAssertEqual(view.resizeEdge(at: NSPoint(x: 1, y: 100)), [.left])
        XCTAssertEqual(view.resizeEdge(at: NSPoint(x: 299, y: 100)), [.right])
        XCTAssertEqual(view.resizeEdge(at: NSPoint(x: 150, y: 1)), [.bottom])
        XCTAssertEqual(view.resizeEdge(at: NSPoint(x: 150, y: 199)), [.top])
        XCTAssertEqual(view.resizeEdge(at: NSPoint(x: 2, y: 2)), [.left, .bottom])
        XCTAssertEqual(view.resizeEdge(at: NSPoint(x: 298, y: 198)), [.right, .top])

        // Body reports the drag cursor, edges report resize cursors.
        XCTAssertEqual(view.cursor(at: NSPoint(x: 150, y: 100)), NSCursor.arrow)
        XCTAssertEqual(view.cursor(at: NSPoint(x: 1, y: 100)), ResizeEdge.left.cursor)
    }
}
