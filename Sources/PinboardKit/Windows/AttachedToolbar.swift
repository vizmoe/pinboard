import AppKit

final class ToolbarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Compact control strip in a child panel pinned to a pin window.
///
/// Child windows follow their parent when it moves, so the strip never covers
/// the content and survives dragging. Subclasses fill `stack` and call
/// `finalizeLayout()`.
class AttachedToolbar: NSObject {
    let panel: NSPanel
    let stack = NSStackView()

    override init() {
        panel = ToolbarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true

        stack.orientation = .horizontal
        stack.spacing = 3
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        panel.contentView = background
    }

    func finalizeLayout() {
        guard let content = panel.contentView else { return }
        panel.setContentSize(content.fittingSize)
    }

    var isAttached: Bool { panel.parent != nil }

    func show(attachedTo parent: NSWindow) {
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        reposition()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Centred under the pin, flipped above when there is no room below.
    func reposition() {
        guard let parent = panel.parent else { return }
        let parentFrame = parent.frame
        let size = panel.frame.size
        var origin = CGPoint(x: parentFrame.midX - size.width / 2, y: parentFrame.minY - size.height - 8)
        if let visible = parent.screen?.visibleFrame {
            if origin.y < visible.minY { origin.y = parentFrame.maxY + 8 }
            origin.y = min(origin.y, visible.maxY - size.height - 4)
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - Control factories

    func makeButton(symbol: String, tooltip: String, action: Selector, width: CGFloat = 24) -> NSButton {
        let button = FirstMouseButton()
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: tooltip
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        button.contentTintColor = .labelColor
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width),
            button.heightAnchor.constraint(equalToConstant: 22)
        ])
        return button
    }

    func makeSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 1),
            box.heightAnchor.constraint(equalToConstant: 16)
        ])
        return box
    }
}
