import AppKit

/// Draws annotations in image pixel coordinates. The canvas applies a scale
/// transform before calling in, the exporter draws 1:1, so what you see on
/// screen is exactly what gets copied or saved.
enum AnnotationRenderer {
    static func attributedText(for annotation: Annotation) -> NSAttributedString {
        NSAttributedString(string: annotation.text ?? "", attributes: [
            .font: annotation.style.font(pointSize: annotation.style.fontSize),
            .foregroundColor: annotation.style.color
        ])
    }

    static func textSize(for annotation: Annotation) -> CGSize {
        let text = attributedText(for: annotation)
        guard text.length > 0 else { return CGSize(width: annotation.style.fontSize, height: annotation.style.fontSize * 1.3) }
        var size = text.size()
        size.width = ceil(size.width) + 4
        size.height = ceil(size.height) + 2
        return size
    }

    static func draw(
        _ annotations: [Annotation],
        imageSize: CGSize,
        effects: ImageEffects?,
        in context: NSGraphicsContext
    ) {
        for annotation in annotations {
            context.saveGraphicsState()
            draw(annotation, imageSize: imageSize, effects: effects, in: context)
            context.restoreGraphicsState()
        }
    }

    static func draw(
        _ annotation: Annotation,
        imageSize: CGSize,
        effects: ImageEffects?,
        in context: NSGraphicsContext
    ) {
        let style = annotation.style
        let color = style.color
        let width = max(style.lineWidth, 0.5)
        let rect = annotation.rect

        switch annotation.tool {
        case .rectangle:
            color.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: width / 2, dy: width / 2))
            path.lineWidth = width
            path.lineJoinStyle = .round
            path.stroke()

        case .ellipse:
            color.setStroke()
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: width / 2, dy: width / 2))
            path.lineWidth = width
            path.stroke()

        case .line:
            guard annotation.points.count >= 2 else { return }
            color.setStroke()
            let path = NSBezierPath()
            path.move(to: annotation.points[0])
            path.line(to: annotation.points[1])
            path.lineWidth = width
            path.lineCapStyle = .round
            path.stroke()

        case .arrow:
            guard annotation.points.count >= 2 else { return }
            color.setFill()
            arrowPath(from: annotation.points[0], to: annotation.points[1], width: width).fill()

        case .freehand:
            guard annotation.points.count >= 2 else { return }
            color.setStroke()
            let path = smoothPath(through: annotation.points)
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()

        case .highlight:
            context.compositingOperation = .multiply
            color.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()

        case .text:
            let text = attributedText(for: annotation)
            let size = textSize(for: annotation)
            let origin = annotation.points.first ?? .zero
            text.draw(in: CGRect(x: origin.x, y: origin.y - size.height, width: size.width, height: size.height))

        case .counter:
            let badge = annotation.boundingBox(textSizer: textSize)
            color.setFill()
            NSBezierPath(ovalIn: badge).fill()
            let label = NSAttributedString(string: annotation.text ?? "1", attributes: [
                .font: NSFont.systemFont(ofSize: annotation.style.fontSize, weight: .bold),
                .foregroundColor: NSColor.white
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))

        case .blur:
            color.withAlphaComponent(1).setFill()
            NSBezierPath(rect: rect).fill()

        case .mosaic:
            let baseBlock = max(12, Int(min(imageSize.width, imageSize.height) / 32))
            let blockSize = max(10, min(64, Int((CGFloat(baseBlock) * max(style.lineWidth, 1) / 3).rounded())))
            guard let filtered = effects?.mosaic(blockSize: blockSize) else {
                color.withAlphaComponent(1).setFill()
                NSBezierPath(rect: rect).fill()
                return
            }
            let clip = NSBezierPath(rect: rect)
            clip.addClip()
            context.cgContext.draw(filtered, in: CGRect(origin: .zero, size: imageSize))

        case .select, .crop:
            break
        }
    }

    static func arrowPath(from start: CGPoint, to end: CGPoint, width: CGFloat) -> NSBezierPath {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = hypot(end.x - start.x, end.y - start.y)
        let headLength = min(max(width * 4.5, 12), max(length * 0.5, 1))
        let headWidth = headLength * 0.8
        let shaftWidth = max(width, 1)

        let path = NSBezierPath()
        let tip = end
        let neck = CGPoint(x: end.x - cos(angle) * headLength, y: end.y - sin(angle) * headLength)
        let normal = CGPoint(x: -sin(angle), y: cos(angle))

        path.move(to: CGPoint(x: start.x + normal.x * shaftWidth / 2, y: start.y + normal.y * shaftWidth / 2))
        path.line(to: CGPoint(x: neck.x + normal.x * shaftWidth / 2, y: neck.y + normal.y * shaftWidth / 2))
        path.line(to: CGPoint(x: neck.x + normal.x * headWidth / 2, y: neck.y + normal.y * headWidth / 2))
        path.line(to: tip)
        path.line(to: CGPoint(x: neck.x - normal.x * headWidth / 2, y: neck.y - normal.y * headWidth / 2))
        path.line(to: CGPoint(x: neck.x - normal.x * shaftWidth / 2, y: neck.y - normal.y * shaftWidth / 2))
        path.line(to: CGPoint(x: start.x - normal.x * shaftWidth / 2, y: start.y - normal.y * shaftWidth / 2))
        path.close()
        return path
    }

    static func smoothPath(through points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.line(to: $0) }
            return path
        }
        for index in 1..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            let mid = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            path.curve(to: mid, controlPoint1: current, controlPoint2: current)
        }
        path.line(to: points[points.count - 1])
        return path
    }
}
