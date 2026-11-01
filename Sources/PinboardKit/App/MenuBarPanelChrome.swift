import AppKit

/// Icon actions keep a stable identifier, spoken name, tooltip and keyboard focus
/// even though the visible label is omitted.
final class PanelIconButton: NSButton {
    let actionName: String
    private let keepsSelection: Bool
    var isProminent = false { didSet { needsDisplay = true } }
    var isDestructive = false { didSet { needsDisplay = true } }
    private var hovered = false
    private var hoverTracking: NSTrackingArea?

    init(_ name: String, symbol: String, keepsSelection: Bool = false,
         target: AnyObject? = nil, action: Selector? = nil) {
        actionName = name
        self.keepsSelection = keepsSelection
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        title = ""
        identifier = NSUserInterfaceItemIdentifier(name)
        toolTip = name
        setAccessibilityLabel(name)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(keepsSelection ? .pushOnPushOff : .momentaryPushIn)
        focusRingType = .exterior
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 26) }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        let sent = super.sendAction(action, to: target)
        // AppKit's momentary cell can retain an on state after performClick.
        // Only navigation uses that state in our custom drawing.
        if !keepsSelection { state = .off }
        return sent
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let selected = keepsSelection && state == .on
        if isProminent || selected || (hovered && isEnabled) || isHighlighted {
            let color: NSColor = isProminent ? .controlAccentColor
                : selected ? .controlAccentColor.withAlphaComponent(0.14)
                : .labelColor.withAlphaComponent(isHighlighted ? 0.12 : 0.07)
            color.withAlphaComponent(isEnabled ? color.alphaComponent : 0.25).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        contentTintColor = isProminent ? .white : isDestructive ? .systemRed
            : selected ? .controlAccentColor : .secondaryLabelColor
        super.draw(dirtyRect)
    }
}

/// One fixed strip for navigation, contextual actions and app utilities.
final class MenuBarPanelToolbar: NSView {
    let pinsButton = PanelIconButton("Pins", symbol: "pin.fill", keepsSelection: true)
    let historyButton = PanelIconButton("History", symbol: "clock.arrow.circlepath", keepsSelection: true)
    let pasteButton = PanelIconButton("Pin Clipboard", symbol: "plus")
    let settingsButton = PanelIconButton("Settings", symbol: "gearshape")
    let quitButton = PanelIconButton("Quit", symbol: "power")
    private var actions: [NSButton] = []
    var onPins: (() -> Void)?
    var onHistory: (() -> Void)?
    var onPaste: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    init(showingHistory: Bool) {
        super.init(frame: .zero)
        pinsButton.state = showingHistory ? .off : .on
        historyButton.state = showingHistory ? .on : .off
        pasteButton.isProminent = true
        for (button, action) in [(pinsButton, #selector(pins)), (historyButton, #selector(history)),
                                  (pasteButton, #selector(paste)), (settingsButton, #selector(settings)),
                                  (quitButton, #selector(quit))] {
            button.target = self
            button.action = action
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }

    func setActions(_ buttons: [NSButton]) {
        guard actions != buttons else { return }
        actions.forEach { $0.removeFromSuperview() }
        actions = buttons
        buttons.forEach { addSubview($0) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        pinsButton.frame = NSRect(x: 0, y: 0, width: 26, height: 26)
        historyButton.frame = NSRect(x: 28, y: 0, width: 26, height: 26)
        pasteButton.frame = NSRect(x: 64, y: 0, width: 26, height: 26)
        for (index, button) in actions.enumerated() {
            button.frame = NSRect(x: 108 + CGFloat(index) * 28, y: 0, width: 26, height: 26)
        }
        settingsButton.frame = NSRect(x: bounds.width - 56, y: 0, width: 26, height: 26)
        quitButton.frame = NSRect(x: bounds.width - 26, y: 0, width: 26, height: 26)
    }

    @objc private func pins() { pinsButton.state = .on; onPins?() }
    @objc private func history() { historyButton.state = .on; onHistory?() }
    @objc private func paste() { onPaste?() }
    @objc private func settings() { onSettings?() }
    @objc private func quit() { onQuit?() }
}

final class MenuBarPanelRootView: NSView {
    var onLayout: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }
    override func layout() { super.layout(); onLayout?() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        onAppearanceChange?()
    }
}
