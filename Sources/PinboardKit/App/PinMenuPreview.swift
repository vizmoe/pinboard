import AppKit

/// Eager, bounded bitmaps: opening a menu never exports a full-size image or
/// retains a live pin through an NSImage drawing closure.
enum PinMenuPreview {
    static func image(size: CGSize, draw: (NSGraphicsContext, CGRect) -> Void) -> NSImage? {
        guard size.width > 0, size.height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * 2)),
                pixelsHigh: Int(ceil(size.height * 2)), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        draw(context, CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = size
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }
}
