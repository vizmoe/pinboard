import AppKit

struct ResizeEdge: OptionSet {
    let rawValue: Int

    static let left = ResizeEdge(rawValue: 1 << 0)
    static let right = ResizeEdge(rawValue: 1 << 1)
    static let top = ResizeEdge(rawValue: 1 << 2)
    static let bottom = ResizeEdge(rawValue: 1 << 3)

    var isHorizontal: Bool { contains(.left) || contains(.right) }
    var isVertical: Bool { contains(.top) || contains(.bottom) }
    var isCorner: Bool { isHorizontal && isVertical }

    @available(macOS 15.0, *)
    private var framePosition: NSCursor.FrameResizePosition? {
        switch (contains(.left), contains(.right), contains(.top), contains(.bottom)) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return nil
        }
    }

    var cursor: NSCursor {
        if #available(macOS 15.0, *), let framePosition {
            return NSCursor.frameResize(position: framePosition, directions: .all)
        }
        if isCorner { return NSCursor.crosshair }
        if isHorizontal { return NSCursor.resizeLeftRight }
        if isVertical { return NSCursor.resizeUpDown }
        return NSCursor.arrow
    }
}

extension NSScreen {
    static var underMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }
}

/// Mouse tracking loops used by the borderless pin windows. Both helpers run a
/// local event loop and return once the mouse is released.
enum WindowInteraction {
    static let clickSlop: CGFloat = 3

    /// Drags the window. If the pointer never moves past `clickSlop` the
    /// gesture is treated as a plain click and `onClick` is invoked instead.
    static func move(
        window: NSWindow,
        dragCursor: NSCursor? = nil,
        endCursor: NSCursor? = nil,
        onClick: (() -> Void)? = nil
    ) {
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        var didDrag = false

        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { break }
            let current = NSEvent.mouseLocation
            let dx = current.x - startMouse.x
            let dy = current.y - startMouse.y
            if !didDrag && hypot(dx, dy) < clickSlop { continue }
            didDrag = true
            dragCursor?.set()
            window.setFrameOrigin(CGPoint(x: (startOrigin.x + dx).rounded(), y: (startOrigin.y + dy).rounded()))
        }

        endCursor?.set()
        if !didDrag { onClick?() }
    }

    static func resize(window: NSWindow, edge: ResizeEdge, minSize: CGSize, aspectRatio: CGSize?) {
        guard !edge.isEmpty else { return }
        let startMouse = NSEvent.mouseLocation
        let startFrame = window.frame
        let ratio: CGFloat? = {
            guard let aspectRatio, aspectRatio.width > 0, aspectRatio.height > 0 else { return nil }
            return aspectRatio.height / aspectRatio.width
        }()

        let cursor = edge.cursor
        cursor.set()
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { break }
            // Re-assert on every step: AppKit resets the cursor while the
            // window geometry changes, which otherwise looks like flicker.
            cursor.set()
            let current = NSEvent.mouseLocation
            let dx = current.x - startMouse.x
            let dy = current.y - startMouse.y

            var width = startFrame.width
            var height = startFrame.height
            if edge.contains(.left) { width = startFrame.width - dx }
            if edge.contains(.right) { width = startFrame.width + dx }
            if edge.contains(.bottom) { height = startFrame.height - dy }
            if edge.contains(.top) { height = startFrame.height + dy }

            if let ratio {
                if edge.isCorner {
                    height = width * ratio
                } else if edge.isHorizontal {
                    height = width * ratio
                } else {
                    width = height / ratio
                }
                if width < minSize.width { width = minSize.width; height = width * ratio }
                if height < minSize.height { height = minSize.height; width = height / ratio }
            } else {
                width = max(width, minSize.width)
                height = max(height, minSize.height)
            }

            var frame = NSRect(origin: startFrame.origin, size: CGSize(width: width.rounded(), height: height.rounded()))
            if edge.contains(.left) { frame.origin.x = startFrame.maxX - frame.width }
            if edge.contains(.bottom) { frame.origin.y = startFrame.maxY - frame.height }
            window.setFrame(frame, display: true)
        }
        window.invalidateShadow()
    }
}
