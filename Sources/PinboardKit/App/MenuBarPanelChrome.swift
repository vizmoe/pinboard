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
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        title = ""
        identifier = NSUserInterfaceItemIdentifier(name)
        toolTip = name
        setAccessibilityLabel(name)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
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
    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }
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
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        contentTintColor = isProminent ? .white : isDestructive ? .systemRed
            : selected ? .controlAccentColor : .secondaryLabelColor
        super.draw(dirtyRect)
    }
}

final class MenuBarPanelHeader: NSView {
    let titleLabel: NSTextField
    let pinsButton = PanelIconButton("Pins", symbol: "pin.fill", keepsSelection: true)
    let historyButton = PanelIconButton("History", symbol: "clock.arrow.circlepath", keepsSelection: true)
    let pasteButton = PanelIconButton("Pin Clipboard", symbol: "plus")
    var onPins: (() -> Void)?
    var onHistory: (() -> Void)?
    var onPaste: (() -> Void)?

    init(title: String, showingHistory: Bool) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        pinsButton.state = showingHistory ? .off : .on
        historyButton.state = showingHistory ? .on : .off
        pasteButton.isProminent = true
        for (button, action) in [(pinsButton, #selector(pins)), (historyButton, #selector(history)), (pasteButton, #selector(paste))] {
            button.target = self
            button.action = action
        }
        [titleLabel, pinsButton, historyButton, pasteButton].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 0, y: 5, width: max(0, bounds.width - 140), height: 24)
        pinsButton.frame = NSRect(x: bounds.width - 116, y: 0, width: 32, height: 32)
        historyButton.frame = NSRect(x: bounds.width - 80, y: 0, width: 32, height: 32)
        pasteButton.frame = NSRect(x: bounds.width - 32, y: 0, width: 32, height: 32)
    }
    @objc private func pins() { pinsButton.state = .on; onPins?() }
    @objc private func history() { historyButton.state = .on; onHistory?() }
    @objc private func paste() { onPaste?() }
}

final class MenuBarPanelFooter: NSView {
    private let label = NSTextField(labelWithString: "Pinboard")
    let settingsButton = PanelIconButton("Settings", symbol: "gearshape")
    let quitButton = PanelIconButton("Quit", symbol: "power")
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .tertiaryLabelColor
        settingsButton.target = self
        settingsButton.action = #selector(settings)
        quitButton.target = self
        quitButton.action = #selector(quit)
        [label, settingsButton, quitButton].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 9, width: 100, height: 16)
        settingsButton.frame = NSRect(x: bounds.width - 72, y: 0, width: 32, height: 32)
        quitButton.frame = NSRect(x: bounds.width - 32, y: 0, width: 32, height: 32)
    }
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
