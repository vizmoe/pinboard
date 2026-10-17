import AppKit

/// Bitmap with exact pixel dimensions. `NSImage.lockFocus` would capture at
/// the screen's backing scale, which makes size assertions ambiguous.
enum TestImage {
    static func make(width: Int, height: Int, color: NSColor = .systemOrange) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = CGSize(width: width, height: height)
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: max(width / 4, 1), height: max(height / 4, 1)).fill()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
