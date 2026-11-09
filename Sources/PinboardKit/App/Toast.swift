import AppKit

/// Small transient message shown near the pointer. Used for feedback that does
/// not deserve a modal alert (empty clipboard, unsupported content, ...).
enum Toast {
    private static var panel: NSPanel?
    private static var dismissWorkItem: DispatchWorkItem?

    static func show(_ message: String, duration: TimeInterval = 1.6) {
        dismissWorkItem?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -9)
        ])

        let size = background.fittingSize
        let mouse = NSEvent.mouseLocation
        let screenFrame = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame
        let frame = clampedFrame(size: size, around: mouse, in: screenFrame)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let window = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = background
        window.alphaValue = reduceMotion ? 1 : 0
        window.orderFrontRegardless()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                window.animator().alphaValue = 1
            }
        }
        panel = window

        let work = DispatchWorkItem {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                window.orderOut(nil)
                if panel === window { panel = nil }
                return
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                window.animator().alphaValue = 0
            }, completionHandler: {
                window.orderOut(nil)
                if panel === window { panel = nil }
            })
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    static func clampedFrame(size: NSSize, around point: NSPoint, in screenFrame: NSRect?) -> NSRect {
        var frame = NSRect(x: point.x - size.width / 2, y: point.y + 18, width: size.width, height: size.height)
        guard let bounds = screenFrame?.insetBy(dx: 8, dy: 8),
              bounds.width >= size.width, bounds.height >= size.height else {
            return frame
        }
        frame.origin.x = min(max(frame.origin.x, bounds.minX), bounds.maxX - size.width)
        frame.origin.y = min(max(frame.origin.y, bounds.minY), bounds.maxY - size.height)
        return frame
    }
}
