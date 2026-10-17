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
        background.layer?.cornerRadius = 9
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
        let frame = NSRect(x: mouse.x - size.width / 2, y: mouse.y + 18, width: size.width, height: size.height)

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
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            window.animator().alphaValue = 1
        }
        panel = window

        let work = DispatchWorkItem {
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
}
