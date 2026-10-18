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

/// Only the preview uses a custom view; actions remain ordinary menu items
/// with native mouse, keyboard and accessibility behavior.
final class PinMenuPreviewView: NSView {
    init(image: NSImage, title: String, isVisible: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 344, height: 218))
        let picture = NSImageView(frame: NSRect(x: 12, y: 30, width: 320, height: 180))
        picture.image = image
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 4
        picture.layer?.masksToBounds = true
        picture.setAccessibilityLabel("Preview of \(title)")
        addSubview(picture)

        let status = NSTextField(labelWithString: isVisible ? "Visible" : "Hidden")
        status.font = .menuFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 12, y: 8, width: 320, height: 16)
        addSubview(status)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title), \(status.stringValue)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
