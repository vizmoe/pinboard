import AppKit

struct ChromeItem {
    let symbol: String
    let tooltip: String
    let action: () -> Void
    var isToggled: Bool = false
}

/// Controls in pin windows must react to the very first click: the panels are
/// non-activating, so they are usually not the key window when clicked.
class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FirstMouseSlider: NSSlider {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ChromeButton: FirstMouseButton {
    var handler: (() -> Void)?

    init(item: ChromeItem) {
        super.init(frame: .zero)
        handler = item.action
        bezelStyle = .regularSquare
        isBordered = false
        imagePosition = .imageOnly
        toolTip = item.tooltip
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.tooltip)?
            .withSymbolConfiguration(config)
        contentTintColor = item.isToggled ? .controlAccentColor : .secondaryLabelColor
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func fire() { handler?() }
}

/// Floating control strip shown on hover in the top-right corner of a pin.
final class PinChromeView: NSVisualEffectView {
    private let stack = NSStackView()

    override var isFlipped: Bool { false }

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        alphaValue = 0

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setItems(_ items: [ChromeItem]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        items.forEach { stack.addArrangedSubview(ChromeButton(item: $0)) }
    }

    func setVisible(_ visible: Bool, animated: Bool = true) {
        let target: CGFloat = visible ? 1 : 0
        guard abs(alphaValue - target) > 0.01 else { return }
        guard animated else { alphaValue = target; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = target
        }
    }
}
