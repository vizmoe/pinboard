import AppKit

enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 21), flipped: true) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }

            let transform = NSAffineTransform()
            transform.translateX(by: 10, yBy: 10)
            transform.rotate(byDegrees: -8)
            transform.translateX(by: -12, yBy: -12)
            transform.concat()
            NSColor.black.set()

            let note = NSBezierPath()
            note.lineWidth = 1.65
            note.lineCapStyle = .round
            note.lineJoinStyle = .round
            note.move(to: NSPoint(x: 8.5, y: 6))
            note.line(to: NSPoint(x: 6.7, y: 6))
            note.appendArc(withCenter: NSPoint(x: 6.7, y: 7.7), radius: 1.7,
                           startAngle: 270, endAngle: 180, clockwise: true)
            note.line(to: NSPoint(x: 5, y: 18.3))
            note.appendArc(withCenter: NSPoint(x: 6.7, y: 18.3), radius: 1.7,
                           startAngle: 180, endAngle: 90, clockwise: true)
            note.line(to: NSPoint(x: 17.3, y: 20))
            note.appendArc(withCenter: NSPoint(x: 17.3, y: 18.3), radius: 1.7,
                           startAngle: 90, endAngle: 0, clockwise: true)
            note.line(to: NSPoint(x: 19, y: 7.7))
            note.appendArc(withCenter: NSPoint(x: 17.3, y: 7.7), radius: 1.7,
                           startAngle: 0, endAngle: -90, clockwise: true)
            note.line(to: NSPoint(x: 15.5, y: 6))
            note.move(to: NSPoint(x: 8.5, y: 12))
            note.line(to: NSPoint(x: 15.5, y: 12))
            note.move(to: NSPoint(x: 8.5, y: 15.5))
            note.line(to: NSPoint(x: 13, y: 15.5))
            note.stroke()

            NSBezierPath(ovalIn: NSRect(x: 10.3, y: 3.2, width: 3.4, height: 3.4)).fill()
            let stem = NSBezierPath()
            stem.lineWidth = 1.4
            stem.lineCapStyle = .round
            stem.move(to: NSPoint(x: 12, y: 6.1))
            stem.line(to: NSPoint(x: 12, y: 8.1))
            stem.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Pinboard"
        return image
    }()
}
