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
    private(set) var isToggledItem: Bool = false
    private let symbolPointSize: CGFloat
    private let symbolWeight: NSFont.Weight
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { updateAppearance() }
    }

    init(
        item: ChromeItem,
        size: NSSize = NSSize(width: 38, height: 38),
        symbolPointSize: CGFloat = 16,
        symbolWeight: NSFont.Weight = .semibold,
        hoverCornerRadius: CGFloat = 19
    ) {
        self.symbolPointSize = symbolPointSize
        self.symbolWeight = symbolWeight
        super.init(frame: NSRect(origin: .zero, size: size))
        bezelStyle = .regularSquare
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = hoverCornerRadius
        layer?.cornerCurve = .continuous
        imagePosition = .imageOnly
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height)
        ])
        configure(with: item)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(with item: ChromeItem) {
        handler = item.action
        isToggledItem = item.isToggled
        toolTip = item.tooltip
        setAccessibilityLabel(item.tooltip)
        let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: symbolWeight)
        image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.tooltip)?
            .withSymbolConfiguration(config)
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        contentTintColor = isToggledItem ? .controlAccentColor : .labelColor
        if isToggledItem {
            let alpha: CGFloat = isHovered ? 0.28 : 0.20
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(alpha).cgColor
        } else if isHovered {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
        } else {
            layer?.backgroundColor = nil
        }
    }

    @objc private func fire() { handler?() }
}

/// Circular HUD button used for corner controls (Close, Hide, Annotate/Edit)
/// and center action buttons (Copy, Save).
final class PinCornerButtonView: NSVisualEffectView {
    private let button: ChromeButton
    static let diameter: CGFloat = 28

    override var isFlipped: Bool { false }

    init(
        symbol: String,
        tooltip: String,
        diameter: CGFloat = PinCornerButtonView.diameter,
        symbolPointSize: CGFloat = 12.5,
        symbolWeight: NSFont.Weight = .bold
    ) {
        button = ChromeButton(
            item: ChromeItem(symbol: symbol, tooltip: tooltip, action: {}),
            size: NSSize(width: diameter, height: diameter),
            symbolPointSize: symbolPointSize,
            symbolWeight: symbolWeight,
            hoverCornerRadius: diameter / 2
        )
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        alphaValue = 0

        translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
    }

    var onAction: (() -> Void)? {
        get { button.handler }
        set { button.handler = newValue }
    }

    func configure(with item: ChromeItem) {
        button.configure(with: item)
    }

    func setVisible(_ visible: Bool, animated: Bool = true) {
        let target: CGFloat = visible ? 1 : 0
        guard abs(alphaValue - target) > 0.01 else { return }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = target
        }
    }
}

/// Top-center pill badge showing the pin's live zoom percentage when scaled
/// away from 100%. Clicking the badge resets the pin back to its 100% size.
final class PinZoomBadgeView: NSVisualEffectView {
    private let button = FirstMouseButton()
    var onResetZoom: (() -> Void)?
    private(set) var percentage: Int = 100
    var isZoomed: Bool { percentage != 100 }

    override var isFlipped: Bool { false }

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        alphaValue = 0

        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = .labelColor
        button.toolTip = "Reset Zoom (100%)"
        button.setAccessibilityLabel("Zoom 100 percent")
        button.target = self
        button.action = #selector(resetClicked)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            button.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setPercentage(100)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
    }

    func setPercentage(_ value: Int) {
        percentage = max(1, value)
        let title = "\(percentage)%"
        button.title = title
        button.setAccessibilityLabel("Zoom \(percentage) percent")
    }

    func setVisible(_ visible: Bool, animated: Bool = true) {
        let target: CGFloat = visible ? 1 : 0
        guard abs(alphaValue - target) > 0.01 else { return }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = target
        }
    }

    @objc private func resetClicked() {
        onResetZoom?()
    }
}

/// Center-aligned row of side-by-side circular HUD icon buttons (Copy, Save)
/// shown on hover in the middle of a pin.
final class PinChromeView: NSView {
    static let buttonDiameter: CGFloat = 38
    static let symbolPointSize: CGFloat = 16
    private let stack = NSStackView()

    override var isFlipped: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        alphaValue = 0

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
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
        for item in items {
            let buttonView = PinCornerButtonView(
                symbol: item.symbol,
                tooltip: item.tooltip,
                diameter: Self.buttonDiameter,
                symbolPointSize: Self.symbolPointSize,
                symbolWeight: .semibold
            )
            buttonView.configure(with: item)
            buttonView.setVisible(true, animated: false)
            stack.addArrangedSubview(buttonView)
        }
    }

    func setVisible(_ visible: Bool, animated: Bool = true) {
        let target: CGFloat = visible ? 1 : 0
        guard abs(alphaValue - target) > 0.01 else { return }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = target
        }
    }
}
