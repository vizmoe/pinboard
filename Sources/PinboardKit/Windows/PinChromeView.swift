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

    init(item: ChromeItem, size: NSSize = NSSize(width: 24, height: 22)) {
        super.init(frame: NSRect(origin: .zero, size: size))
        handler = item.action
        bezelStyle = .regularSquare
        isBordered = false
        imagePosition = .imageOnly
        toolTip = item.tooltip
        setAccessibilityLabel(item.tooltip)
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.tooltip)?
            .withSymbolConfiguration(config)
        contentTintColor = item.isToggled ? .controlAccentColor : .labelColor
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func fire() { handler?() }
}

/// Circular corner control (top-left Close, top-right Hide) matching CleanShot X's
/// floating pin overlay aesthetic.
final class PinCornerButtonView: NSVisualEffectView {
    private let button: ChromeButton
    private static let diameter: CGFloat = 24

    override var isFlipped: Bool { false }

    init(symbol: String, tooltip: String) {
        button = ChromeButton(
            item: ChromeItem(symbol: symbol, tooltip: tooltip, action: {}),
            size: NSSize(width: Self.diameter, height: Self.diameter)
        )
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = Self.diameter / 2
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        alphaValue = 0

        translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter),
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var onAction: (() -> Void)? {
        get { button.handler }
        set { button.handler = newValue }
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

/// Top-center pill badge showing the pin's live zoom percentage (e.g. `100%`).
/// Clicking the badge resets the pin back to its 100% default size.
final class PinZoomBadgeView: NSVisualEffectView {
    private let button = FirstMouseButton()
    var onResetZoom: (() -> Void)?
    private(set) var percentage: Int = 100

    override var isFlipped: Bool { false }

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        alphaValue = 0

        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        button.contentTintColor = .labelColor
        button.toolTip = "Reset Zoom (100%)"
        button.setAccessibilityLabel("Zoom 100 percent")
        button.target = self
        button.action = #selector(resetClicked)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            button.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setPercentage(100)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setPercentage(_ value: Int) {
        percentage = max(1, value)
        let title = "\(percentage)%"
        button.title = title
        button.setAccessibilityLabel("Zoom \(percentage) percent")
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

    @objc private func resetClicked() {
        onResetZoom?()
    }
}

/// Floating pill strip shown on hover at the bottom-center of a pin for
/// content actions (Edit/Annotate, Copy, Save).
final class PinChromeView: NSVisualEffectView {
    private let stack = NSStackView()

    override var isFlipped: Bool { false }

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        alphaValue = 0

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 1, left: 4, bottom: 1, right: 4)
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
        for (index, item) in items.enumerated() {
            if index > 0 {
                let divider = NSView()
                divider.wantsLayer = true
                divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
                divider.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    divider.widthAnchor.constraint(equalToConstant: 1),
                    divider.heightAnchor.constraint(equalToConstant: 12)
                ])
                stack.addArrangedSubview(divider)
            }
            stack.addArrangedSubview(ChromeButton(item: item))
        }
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
