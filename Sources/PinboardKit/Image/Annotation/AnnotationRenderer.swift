import AppKit

/// Draws annotations in image pixel coordinates. The canvas applies a scale
/// transform before calling in, the exporter draws 1:1, so what you see on
/// screen is exactly what gets copied or saved.
enum AnnotationRenderer {
    static func textPadding(for annotation: Annotation) -> CGSize {
        switch annotation.effectiveTextStyle {
        case .standard:
            return .zero
        case .box, .outline:
            let fontSize = annotation.style.fontSize
            return CGSize(width: max(round(fontSize * 0.45), 6), height: max(round(fontSize * 0.22), 3))
        }
    }

    static func contrastingTextColor(for background: NSColor) -> NSColor {
        let rgb = background.usingColorSpace(.sRGB) ?? background
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.65 ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1) : .white
    }

    static func attributedText(for annotation: Annotation) -> NSAttributedString {
        let foreground: NSColor = annotation.effectiveTextStyle == .box
            ? contrastingTextColor(for: annotation.style.color)
            : annotation.style.color
        return NSAttributedString(string: annotation.text ?? "", attributes: [
            .font: annotation.style.font(pointSize: annotation.style.fontSize),
            .foregroundColor: foreground
        ])
    }

    static func textSize(for annotation: Annotation) -> CGSize {
        let text = attributedText(for: annotation)
        let padding = textPadding(for: annotation)
        guard text.length > 0 else {
            return CGSize(
                width: annotation.style.fontSize + padding.width * 2,
                height: annotation.style.fontSize * 1.3 + padding.height * 2
            )
        }
        var size = text.size()
        size.width = ceil(size.width) + 4 + padding.width * 2
        size.height = ceil(size.height) + 2 + padding.height * 2
        return size
    }

    static func draw(
        _ annotations: [Annotation],
        imageSize: CGSize,
        effects: ImageEffects?,
        in context: NSGraphicsContext
    ) {
        let spotlights = annotations.filter {
            $0.tool == .spotlight && $0.rect.width > 1 && $0.rect.height > 1
        }
        if !spotlights.isEmpty {
            drawSpotlights(spotlights, imageSize: imageSize, in: context)
        }
        for annotation in annotations where annotation.tool != .spotlight {
            context.saveGraphicsState()
            draw(annotation, imageSize: imageSize, effects: effects, in: context)
            context.restoreGraphicsState()
        }
    }

    static func drawSpotlights(
        _ spotlights: [Annotation],
        imageSize: CGSize,
        in context: NSGraphicsContext
    ) {
        guard !spotlights.isEmpty else { return }
        let lineWidth = spotlights.last?.style.lineWidth ?? 3
        let alpha = min(max(0.35 + (lineWidth - 1) / 15 * 0.50, 0.20), 0.88)
        let fullRect = CGRect(origin: .zero, size: imageSize)

        context.saveGraphicsState()
        for spotlight in spotlights {
            let maskPath = CGMutablePath()
            maskPath.addRect(fullRect)
            let hole = spotlight.rect
            if spotlight.effectiveSpotlightShape == .ellipse {
                maskPath.addEllipse(in: hole)
            } else {
                let corner = min(6, hole.width / 4, hole.height / 4)
                maskPath.addRoundedRect(in: hole, cornerWidth: corner, cornerHeight: corner)
            }
            context.cgContext.addPath(maskPath)
            context.cgContext.clip(using: .evenOdd)
        }
        NSColor.black.withAlphaComponent(alpha).setFill()
        NSBezierPath(rect: fullRect).fill()
        context.restoreGraphicsState()

        context.saveGraphicsState()
        NSColor.white.withAlphaComponent(0.3).setStroke()
        for spotlight in spotlights {
            let hole = spotlight.rect
            let border: NSBezierPath
            if spotlight.effectiveSpotlightShape == .ellipse {
                border = NSBezierPath(ovalIn: hole)
            } else {
                let corner = min(6, hole.width / 4, hole.height / 4)
                border = NSBezierPath(roundedRect: hole, xRadius: corner, yRadius: corner)
            }
            border.lineWidth = 1.5
            border.stroke()
        }
        context.restoreGraphicsState()
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
            arrowPath(points: annotation.points, width: width).fill()

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
            if annotation.effectiveHighlightMode == .freehand {
                guard annotation.points.count >= 2 else { return }
                color.withAlphaComponent(0.35).setStroke()
                let path = smoothPath(through: annotation.points)
                path.lineWidth = max(width * 4, 14)
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            } else {
                color.withAlphaComponent(0.35).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            }

        case .text:
            let text = attributedText(for: annotation)
            let size = textSize(for: annotation)
            let padding = textPadding(for: annotation)
            let origin = annotation.points.first ?? .zero
            let boxRect = CGRect(x: origin.x, y: origin.y - size.height, width: size.width, height: size.height)
            let corner = max(annotation.style.fontSize * 0.28, 5)

            switch annotation.effectiveTextStyle {
            case .standard:
                break
            case .box:
                color.withAlphaComponent(1).setFill()
                NSBezierPath(roundedRect: boxRect, xRadius: corner, yRadius: corner).fill()
            case .outline:
                let rgb = color.usingColorSpace(.sRGB) ?? color
                let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
                let backing = luminance > 0.75
                    ? NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 0.92)
                    : NSColor.white.withAlphaComponent(0.92)
                let strokeWidth = max(annotation.style.fontSize * 0.08, 1.5)
                let path = NSBezierPath(
                    roundedRect: boxRect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2),
                    xRadius: corner,
                    yRadius: corner
                )
                backing.setFill()
                path.fill()
                color.withAlphaComponent(1).setStroke()
                path.lineWidth = strokeWidth
                path.stroke()
            }
            text.draw(in: boxRect.insetBy(dx: padding.width, dy: padding.height))

        case .counter:
            let badge = annotation.boundingBox(textSizer: textSize)
            let borderWidth = max(badge.width * 0.08, 2)
            let oval = NSBezierPath(ovalIn: badge.insetBy(dx: borderWidth / 2, dy: borderWidth / 2))
            context.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowBlurRadius = 3
            shadow.set()
            color.withAlphaComponent(1).setFill()
            oval.fill()
            context.restoreGraphicsState()
            NSColor.white.setStroke()
            oval.lineWidth = borderWidth
            oval.stroke()
            let label = NSAttributedString(string: annotation.text ?? "1", attributes: [
                .font: NSFont.systemFont(ofSize: annotation.style.fontSize, weight: .bold),
                .foregroundColor: NSColor.white
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))

        case .blur, .mosaic:
            let baseBlock = max(12, Int(min(imageSize.width, imageSize.height) / 32))
            let scale = max(10, min(64, Int((CGFloat(baseBlock) * max(style.lineWidth, 1) / 3).rounded())))
            switch annotation.effectiveRedactionStyle {
            case .solid:
                color.withAlphaComponent(1).setFill()
                NSBezierPath(rect: rect).fill()
            case .mosaic:
                guard let filtered = effects?.mosaic(blockSize: scale) else {
                    color.withAlphaComponent(1).setFill()
                    NSBezierPath(rect: rect).fill()
                    return
                }
                let clip = NSBezierPath(rect: rect)
                clip.addClip()
                context.cgContext.draw(filtered, in: CGRect(origin: .zero, size: imageSize))
            case .blur:
                guard let filtered = effects?.secureBlur(radius: scale) else {
                    color.withAlphaComponent(1).setFill()
                    NSBezierPath(rect: rect).fill()
                    return
                }
                let clip = NSBezierPath(rect: rect)
                clip.addClip()
                context.cgContext.draw(filtered, in: CGRect(origin: .zero, size: imageSize))
            }

        case .spotlight:
            drawSpotlights([annotation], imageSize: imageSize, in: context)

        case .select, .crop:
            break
        }
    }

    static func arrowPath(from start: CGPoint, to end: CGPoint, width: CGFloat) -> NSBezierPath {
        arrowPath(points: [start, end], width: width)
    }

    /// CleanShot X-style Fancy Arrow: a tapered wedge shaft from a narrow tail
    /// to a wider neck, meeting a swept-back chevron arrowhead, optionally bent
    /// along a quadratic Bézier curve through `points[2]`.
    static func arrowPath(points: [CGPoint], width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        guard points.count >= 2 else { return path }
        let start = points[0]
        let end = points[1]
        let mid = points.count >= 3
            ? points[2]
            : CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let control = CGPoint(
            x: 2 * mid.x - 0.5 * (start.x + end.x),
            y: 2 * mid.y - 0.5 * (start.y + end.y)
        )

        let totalSteps = 24
        var spine: [CGPoint] = []
        spine.reserveCapacity(totalSteps + 1)
        var arcLengths: [CGFloat] = [0]
        arcLengths.reserveCapacity(totalSteps + 1)
        for index in 0...totalSteps {
            let t = CGFloat(index) / CGFloat(totalSteps)
            let u = 1 - t
            let pt = CGPoint(
                x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
            )
            if let prev = spine.last {
                arcLengths.append(arcLengths.last! + hypot(pt.x - prev.x, pt.y - prev.y))
            }
            spine.append(pt)
        }

        let totalLength = arcLengths.last ?? 0
        guard totalLength > 0.5 else { return path }

        let headLength = min(max(width * 4.8, 14), max(totalLength * 0.45, 2))
        let headWidth = headLength * 0.9
        let neckDistFromTip = headLength * 0.78
        let tailHalfWidth = max(width * 0.22, 0.8)
        let neckHalfWidth = max(width * 0.92, 2.2)

        let neckTargetArc = max(totalLength - neckDistFromTip, 0)
        let tNeck = min(max(neckTargetArc / totalLength, 0.05), 0.95)

        func pointAndNormal(at t: CGFloat) -> (point: CGPoint, tangent: CGPoint, normal: CGPoint) {
            let u = 1 - t
            let pt = CGPoint(
                x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
            )
            var dx = 2 * u * (control.x - start.x) + 2 * t * (end.x - control.x)
            var dy = 2 * u * (control.y - start.y) + 2 * t * (end.y - control.y)
            let len = hypot(dx, dy)
            if len > 0.0001 {
                dx /= len
                dy /= len
            } else {
                let fallbackLen = max(hypot(end.x - start.x, end.y - start.y), 0.0001)
                dx = (end.x - start.x) / fallbackLen
                dy = (end.y - start.y) / fallbackLen
            }
            return (pt, CGPoint(x: dx, y: dy), CGPoint(x: -dy, y: dx))
        }

        let shaftSteps = points.count >= 3 ? 16 : 2
        var leftEdge: [CGPoint] = []
        var rightEdge: [CGPoint] = []
        leftEdge.reserveCapacity(shaftSteps + 1)
        rightEdge.reserveCapacity(shaftSteps + 1)

        for step in 0...shaftSteps {
            let progress = CGFloat(step) / CGFloat(shaftSteps)
            let t = progress * tNeck
            let sample = pointAndNormal(at: t)
            let halfWidth = tailHalfWidth + (neckHalfWidth - tailHalfWidth) * progress
            leftEdge.append(CGPoint(
                x: sample.point.x + sample.normal.x * halfWidth,
                y: sample.point.y + sample.normal.y * halfWidth
            ))
            rightEdge.append(CGPoint(
                x: sample.point.x - sample.normal.x * halfWidth,
                y: sample.point.y - sample.normal.y * halfWidth
            ))
        }

        let neckSample = pointAndNormal(at: tNeck)
        var headDir = CGPoint(x: end.x - neckSample.point.x, y: end.y - neckSample.point.y)
        let headDirLen = hypot(headDir.x, headDir.y)
        if headDirLen > 0.0001 {
            headDir.x /= headDirLen
            headDir.y /= headDirLen
        } else {
            headDir = neckSample.tangent
        }
        let headNormal = CGPoint(x: -headDir.y, y: headDir.x)
        let barbBase = CGPoint(x: end.x - headDir.x * headLength, y: end.y - headDir.y * headLength)
        let leftBarb = CGPoint(x: barbBase.x + headNormal.x * headWidth / 2, y: barbBase.y + headNormal.y * headWidth / 2)
        let rightBarb = CGPoint(x: barbBase.x - headNormal.x * headWidth / 2, y: barbBase.y - headNormal.y * headWidth / 2)

        guard let firstLeft = leftEdge.first else { return path }
        path.move(to: firstLeft)
        for point in leftEdge.dropFirst() {
            path.line(to: point)
        }
        path.line(to: leftBarb)
        path.line(to: end)
        path.line(to: rightBarb)
        for point in rightEdge.reversed() {
            path.line(to: point)
        }
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
