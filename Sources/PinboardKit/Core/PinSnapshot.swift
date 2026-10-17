import AppKit

/// Serializable description of a pin. Not restored on launch yet, but every
/// field needed for that lives here so persistence can be switched on later.
struct PinSnapshot: Codable {
    struct Rect: Codable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ rect: NSRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.width
            height = rect.height
        }

        var nsRect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
    }

    var id: UUID
    var kind: PinKind
    var rtfData: Data?
    var plainText: String?
    var imageData: Data?
    var annotationData: Data?
    var frame: Rect
    var isHidden: Bool
    var opacity: Double

    init(id: UUID, content: PinContent, frame: NSRect, isHidden: Bool, annotationData: Data? = nil, opacity: Double = 1.0) {
        self.id = id
        self.kind = content.kind
        self.frame = Rect(frame)
        self.isHidden = isHidden
        self.annotationData = annotationData
        self.opacity = opacity
        switch content {
        case .text(let attributed):
            rtfData = attributed.rtfdRepresentation() ?? attributed.rtfRepresentation()
            plainText = attributed.string
        case .image(let image):
            imageData = image.pngData()
        }
    }

    func makeContent() -> PinContent? {
        switch kind {
        case .text:
            if let rtfData {
                if let text = NSAttributedString(rtfd: rtfData, documentAttributes: nil) { return .text(text) }
                if let text = NSAttributedString(rtf: rtfData, documentAttributes: nil) { return .text(text) }
            }
            if let plainText {
                return .text(NSAttributedString(string: plainText, attributes: ClipboardReader.defaultTextAttributes()))
            }
            return nil
        case .image:
            guard let imageData, let image = NSImage(data: imageData) else { return nil }
            return .image(image)
        }
    }
}

extension NSImage {
    /// Pixel dimensions of the best representation, independent of point size.
    var pixelSize: CGSize {
        let reps = representations.compactMap { $0 as? NSBitmapImageRep }
        if let best = reps.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
            return CGSize(width: best.pixelsWide, height: best.pixelsHigh)
        }
        if let rep = representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return size
    }

    func pngData() -> Data? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size
        return rep.representation(using: .png, properties: [:])
    }
}
