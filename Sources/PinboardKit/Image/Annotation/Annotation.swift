import AppKit

enum AnnotationTool: String, Codable, CaseIterable {
    case select
    case rectangle
    case ellipse
    case arrow
    case line
    case freehand
    case text
    case highlight
    case blur
    case mosaic
    case crop

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .freehand: return "scribble"
        case .text: return "textformat"
        case .highlight: return "highlighter"
        case .blur: return "drop.circle"
        case .mosaic: return "squareshape.split.3x3"
        case .crop: return "crop"
        }
    }

    var localizedName: String {
        switch self {
        case .select: return "Select"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .freehand: return "Pen"
        case .text: return "Text"
        case .highlight: return "Highlight"
        case .blur: return "Blur"
        case .mosaic: return "Mosaic"
        case .crop: return "Crop"
        }
    }

    /// Tools whose geometry is a drag rectangle.
    var isRectangular: Bool {
        switch self {
        case .rectangle, .ellipse, .highlight, .blur, .mosaic, .crop: return true
        default: return false
        }
    }
}

struct AnnotationStyle: Codable, Equatable {
    var colorHex: String
    var lineWidth: CGFloat
    var fontSize: CGFloat
    /// Font family for text annotations; nil falls back to the system font.
    /// Optional so payloads written before font support still decode.
    var fontName: String?

    var color: NSColor { NSColor(hex: colorHex) ?? .systemRed }

    /// Resolves the annotation font: chosen family, or the system font.
    func font(pointSize: CGFloat) -> NSFont {
        let size = max(pointSize, 1)
        if let fontName,
           let font = NSFontManager.shared.font(withFamily: fontName, traits: [], weight: 5, size: size) {
            return font
        }
        return .systemFont(ofSize: size, weight: .medium)
    }

    static func current() -> AnnotationStyle {
        let preferences = Preferences.shared
        return AnnotationStyle(
            colorHex: preferences.annotationColorHex,
            lineWidth: CGFloat(preferences.annotationLineWidth),
            fontSize: CGFloat(preferences.annotationFontSize),
            fontName: nil
        )
    }
}

/// One annotation, stored in image pixel coordinates (bottom-left origin) so
/// the data is independent of the window size and exports at full resolution.
struct Annotation: Codable, Identifiable, Equatable {
    var id = UUID()
    var tool: AnnotationTool
    var points: [CGPoint]
    var style: AnnotationStyle
    var text: String?

    var rect: CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { partial, point in
            partial.union(CGRect(origin: point, size: .zero))
        }
    }

    /// Area used for hit testing and selection handles.
    func boundingBox(textSizer: (Annotation) -> CGSize) -> CGRect {
        switch tool {
        case .text:
            let origin = points.first ?? .zero
            let size = textSizer(self)
            return CGRect(x: origin.x, y: origin.y - size.height, width: size.width, height: size.height)
        default:
            return rect.insetBy(dx: -style.lineWidth, dy: -style.lineWidth)
        }
    }

    func hitTest(_ point: CGPoint, textSizer: (Annotation) -> CGSize) -> Bool {
        switch tool {
        case .freehand:
            let tolerance = max(style.lineWidth, 6)
            return points.contains { hypot($0.x - point.x, $0.y - point.y) <= tolerance * 1.5 }
        case .line, .arrow:
            guard points.count >= 2 else { return false }
            return Annotation.distance(from: point, toSegment: points[0], points[1]) <= max(style.lineWidth, 8)
        default:
            return boundingBox(textSizer: textSizer).contains(point)
        }
    }

    mutating func translate(by offset: CGVector) {
        points = points.map { CGPoint(x: $0.x + offset.dx, y: $0.y + offset.dy) }
    }

    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
        t = min(max(t, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}
