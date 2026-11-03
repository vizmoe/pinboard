import AppKit

enum AnnotationTool: String, Codable, CaseIterable {
    case select
    case rectangle
    case ellipse
    case arrow
    case line
    case freehand
    case text
    case counter
    case highlight
    case blur
    case mosaic
    case spotlight
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
        case .counter: return "number.circle"
        case .highlight: return "highlighter"
        case .blur: return "rectangle.fill"
        case .mosaic: return "squareshape.split.3x3"
        case .spotlight: return "light.max"
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
        case .counter: return "Counter"
        case .highlight: return "Highlight"
        case .blur: return "Solid Fill"
        case .mosaic: return "Mosaic"
        case .spotlight: return "Spotlight"
        case .crop: return "Crop"
        }
    }

    /// Single-key tools, matching familiar screenshot editors.
    var shortcut: String {
        switch self {
        case .select: return "v"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .arrow: return "a"
        case .line: return "l"
        case .freehand: return "p"
        case .text: return "t"
        case .counter: return "n"
        case .highlight: return "h"
        case .blur: return "b"
        case .mosaic: return "m"
        case .spotlight: return "s"
        case .crop: return "c"
        }
    }

    /// Shift constrains squares/circles and snaps lines to 45-degree angles.
    func constrainedEndpoint(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        switch self {
        case .rectangle, .ellipse, .spotlight:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        case .arrow, .line:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        default: return end
        }
    }

    /// Tools whose geometry is a drag rectangle.
    var isRectangular: Bool {
        switch self {
        case .rectangle, .ellipse, .highlight, .blur, .mosaic, .spotlight, .crop: return true
        default: return false
        }
    }

    /// True for redaction tools (Mosaic, Secure Blur, and Solid Fill), which
    /// share a single toolbar entry and switch modes in the contextual strip.
    var isRedaction: Bool {
        self == .mosaic || self == .blur
    }
}

/// Redaction styles offered by the unified 3-in-1 Redact tool.
enum AnnotationRedactionStyle: String, Codable, CaseIterable {
    case mosaic
    case blur
    case solid
}

/// Visual presentation for text annotations, inspired by CleanShot X.
enum AnnotationTextStyle: String, Codable, CaseIterable {
    case standard
    case box
    case outline
}

/// Cutout geometry for Spotlight annotations.
enum AnnotationSpotlightShape: String, Codable, CaseIterable {
    case rectangle
    case ellipse
}

/// Input mode for Highlighter annotations.
enum AnnotationHighlightMode: String, Codable, CaseIterable {
    case rectangle
    case freehand
}

struct AnnotationStyle: Codable, Equatable {
    var colorHex: String
    var lineWidth: CGFloat
    var fontSize: CGFloat
    /// Font family for text annotations; nil falls back to the system font.
    /// Optional so payloads written before font support still decode.
    var fontName: String?
    var redactionStyle: AnnotationRedactionStyle?
    var textStyle: AnnotationTextStyle?
    var spotlightShape: AnnotationSpotlightShape?
    var highlightMode: AnnotationHighlightMode?

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

    var effectiveRedactionStyle: AnnotationRedactionStyle {
        if let redactionStyle = style.redactionStyle { return redactionStyle }
        return tool == .blur ? .solid : .mosaic
    }

    var effectiveTextStyle: AnnotationTextStyle {
        style.textStyle ?? .standard
    }

    var effectiveSpotlightShape: AnnotationSpotlightShape {
        style.spotlightShape ?? .rectangle
    }

    var effectiveHighlightMode: AnnotationHighlightMode {
        style.highlightMode ?? (points.count > 2 ? .freehand : .rectangle)
    }

    var rect: CGRect {
        let samples = (tool == .arrow && points.count >= 3) ? arrowCurveSamples() : points
        guard let first = samples.first else { return .zero }
        return samples.dropFirst().reduce(CGRect(origin: first, size: .zero)) { partial, point in
            partial.union(CGRect(origin: point, size: .zero))
        }
    }

    /// Area used for hit testing and selection handles.
    func boundingBox(textSizer: (Annotation) -> CGSize) -> CGRect {
        switch tool {
        case .counter:
            let origin = points.first ?? .zero
            let diameter = max(style.fontSize * 1.8, 24)
            return CGRect(x: origin.x - diameter / 2, y: origin.y - diameter / 2,
                          width: diameter, height: diameter)
        case .text:
            let origin = points.first ?? .zero
            let size = textSizer(self)
            return CGRect(x: origin.x, y: origin.y - size.height, width: size.width, height: size.height)
        case .highlight where effectiveHighlightMode == .freehand:
            let pad = max(style.lineWidth * 2, 8)
            return rect.insetBy(dx: -pad, dy: -pad)
        default:
            return rect.insetBy(dx: -style.lineWidth, dy: -style.lineWidth)
        }
    }

    func hitTest(_ point: CGPoint, textSizer: (Annotation) -> CGSize) -> Bool {
        switch tool {
        case .freehand:
            let tolerance = max(style.lineWidth, 6)
            return zip(points, points.dropFirst()).contains {
                Self.distance(from: point, toSegment: $0, $1) <= tolerance * 1.5
            }
        case .highlight where effectiveHighlightMode == .freehand:
            let tolerance = max(style.lineWidth * 2, 10)
            return zip(points, points.dropFirst()).contains {
                Self.distance(from: point, toSegment: $0, $1) <= tolerance
            }
        case .arrow:
            guard points.count >= 2 else { return false }
            let samples = points.count >= 3 ? arrowCurveSamples() : Array(points.prefix(2))
            let tolerance = max(style.lineWidth * 1.2, 8)
            return zip(samples, samples.dropFirst()).contains {
                Self.distance(from: point, toSegment: $0, $1) <= tolerance
            }
        case .line:
            guard points.count >= 2 else { return false }
            return Annotation.distance(from: point, toSegment: points[0], points[1]) <= max(style.lineWidth, 8)
        default:
            return boundingBox(textSizer: textSizer).contains(point)
        }
    }

    func arrowCurveSamples(steps: Int = 16) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        let start = points[0]
        let end = points[1]
        guard points.count >= 3 else { return [start, end] }
        let mid = points[2]
        return (0...max(steps, 2)).map { step in
            let t = CGFloat(step) / CGFloat(max(steps, 2))
            return Self.quadraticBezierPoint(start: start, passThrough: mid, end: end, t: t)
        }
    }

    static func quadraticBezierPoint(start: CGPoint, passThrough mid: CGPoint, end: CGPoint, t: CGFloat) -> CGPoint {
        let control = CGPoint(
            x: 2 * mid.x - 0.5 * (start.x + end.x),
            y: 2 * mid.y - 0.5 * (start.y + end.y)
        )
        let u = 1 - t
        return CGPoint(
            x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
        )
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
