import AppKit
import XCTest
@testable import PinboardKit

/// Renders real pin windows to PNGs so the drawn result can be inspected, not
/// just the geometry.
final class TextRenderSnapshotTests: XCTestCase {
    private var manager: PinWindowManager { PinWindowManager.shared }

    override func tearDown() {
        manager.closeAll()
        super.tearDown()
    }

    private func snapshot(_ pin: PinWindowController, to path: String) throws {
        let view = try XCTUnwrap(pin.panel.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        // Composite over white so transparent text pins are readable.
        let canvas = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: canvas))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: canvas.pixelsWide, height: canvas.pixelsHigh).fill()
        rep.draw(in: NSRect(x: 0, y: 0, width: canvas.pixelsWide, height: canvas.pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()

        try XCTUnwrap(canvas.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path))
    }

    func testWrapRenderingAtTwoWidths() throws {
        let html = "<p style=\"font-family:Helvetica;font-size:15px\">Pinboard keeps clipboard text floating above every window, and the text must re-wrap to whatever width the user drags the pin to.</p>"
        let text = try XCTUnwrap(NSAttributedString(
            data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ))
        let pin = manager.createPin(content: .text(text))
        let view = try XCTUnwrap(pin.contentView as? TextPinView)

        pin.setFrame(NSRect(x: 60, y: 60, width: 560, height: 160))
        try snapshot(pin, to: "/tmp/pinboard-wrap-wide.png")
        let wideWrap = view.textWrapWidth

        // Edit once, as a user would, before resizing.
        view.beginEditing(at: nil)
        pin.setFrame(NSRect(x: 60, y: 60, width: 240, height: 320))
        try snapshot(pin, to: "/tmp/pinboard-wrap-narrow.png")

        XCTAssertLessThan(view.textWrapWidth, wideWrap)
    }

    /// Red text on a yellow text background must draw both colours: the layout
    /// manager paints the run background first, then the glyphs on top. If a
    /// background pick ever stomped the foreground (or vice versa) one of the
    /// two colours would vanish from the pixels.
    func testForegroundDrawsOverTextBackground() throws {
        let text = NSAttributedString(string: "BgTest", attributes: [
            .font: NSFont.systemFont(ofSize: 28, weight: .bold),
            .foregroundColor: NSColor.systemRed,
            .backgroundColor: NSColor.systemYellow
        ])
        let pin = manager.createPin(content: .text(text))
        let view = try XCTUnwrap(pin.panel.contentView)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/pinboard-fg-bg.png"))

        var yellowPixels = 0
        var redPixels = 0
        for x in 0 ..< rep.pixelsWide {
            for y in 0 ..< rep.pixelsHigh {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if pixel.redComponent > 0.8, pixel.greenComponent > 0.7, pixel.blueComponent < 0.5 {
                    yellowPixels += 1
                } else if pixel.redComponent > 0.7, pixel.redComponent - pixel.greenComponent > 0.2 {
                    redPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(yellowPixels, 200, "the text background colour must paint under the run")
        XCTAssertGreaterThan(redPixels, 100, "glyphs must stay visible on top of the background")
    }
}
