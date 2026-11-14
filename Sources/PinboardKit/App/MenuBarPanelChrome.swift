import AppKit

/// Shared actions in the menu bar panel's fixed top strip.
enum MenuBarUtilityAction {
    case paste, history, settings, quit
}

extension NSView {
    var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

// MARK: - Borderless Floating Glass Panel

private final class FloatingMenuBarWindow: NSPanel {
    var onCancel: (() -> Void)?
    var isPresentingAttachedMenu = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Light, even tint over the blurred material. It only steadies contrast; the
/// desktop must still read through so the panel feels like a native menu.
private final class GlassSheenView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let tint = isDarkAppearance
            ? NSColor(srgbRed: 0.11, green: 0.115, blue: 0.125, alpha: 0.52)
            : NSColor(calibratedWhite: 0.985, alpha: 0.50)
        tint.setFill()
        bounds.fill()
    }
}

/// Non-interactive continuous hairline border that gives the floating panel
/// a crisp native-menu rim in both light and dark appearances.
private final class GlassRimView: NSView {
    static let cornerRadius: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = isDarkAppearance
        layer?.borderWidth = 0.5
        layer?.borderColor = (dark
            ? NSColor.white.withAlphaComponent(0.20)
            : NSColor.black.withAlphaComponent(0.16)).cgColor
    }
}

private final class GlassPanelSurfaceView: NSVisualEffectView {
    let sheenView = GlassSheenView()
    let pageContainer = NSView()
    let rimView = GlassRimView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        maskImage = Self.makeRoundedMask(radius: GlassRimView.cornerRadius)
        wantsLayer = true
        layer?.cornerRadius = GlassRimView.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        addSubview(sheenView)
        addSubview(pageContainer)
        addSubview(rimView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        sheenView.frame = bounds
        pageContainer.frame = bounds
        rimView.frame = bounds
    }

    private static func makeRoundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 2
        let size = NSSize(width: edge, height: edge)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let path = CGPath(
                roundedRect: rect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Outer transparent host so WindowServer and offscreen snapshot caches preserve
/// crisp transparent corners outside the 15pt continuous squircle.
private final class GlassWindowHostView: NSView {
    let surfaceView: GlassPanelSurfaceView

    init(frame: NSRect, surfaceView: GlassPanelSurfaceView) {
        self.surfaceView = surfaceView
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        surfaceView.frame = bounds
        surfaceView.autoresizingMask = [.width, .height]
        addSubview(surfaceView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isOpaque: Bool { false }
}

/// Arrowless floating glass panel anchored cleanly below the status bar item,
/// styled after macOS Control Center and CleanShot X.
final class MenuBarFloatingPanel: NSObject {
    let window: NSPanel
    private let surfaceView: GlassPanelSurfaceView
    private weak var anchorView: NSView?
    private var anchorRect: NSRect = .zero
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var appResignObserver: NSObjectProtocol?

    var onDidShow: (() -> Void)?
    var onDidClose: (() -> Void)?

    var contentViewController: NSViewController? {
        didSet {
            guard contentViewController !== oldValue else { return }
            oldValue?.view.removeFromSuperview()
            guard let page = contentViewController else { return }
            let targetSize = page.preferredContentSize.width > 0
                ? page.preferredContentSize
                : page.view.frame.size
            if targetSize.width > 0, targetSize.height > 0 {
                setContentSize(targetSize)
            }
            page.view.frame = surfaceView.pageContainer.bounds
            page.view.autoresizingMask = [.width, .height]
            surfaceView.pageContainer.addSubview(page.view)
            surfaceView.layoutSubtreeIfNeeded()
        }
    }

    var contentSize: NSSize {
        get { surfaceView.frame.size }
        set { setContentSize(newValue) }
    }

    var isShown: Bool { window.isVisible }

    override init() {
        let initial = NSRect(x: 0, y: 0, width: 320, height: 48)
        let panel = FloatingMenuBarWindow(
            contentRect: initial,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false

        let surface = GlassPanelSurfaceView(frame: initial)
        surfaceView = surface
        panel.contentView = GlassWindowHostView(frame: initial, surfaceView: surface)
        window = panel
        super.init()

        panel.onCancel = { [weak self] in self?.performClose(nil) }
    }

    deinit {
        removeTransientMonitors()
        window.orderOut(nil)
    }

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge = .minY) {
        anchorView = positioningView
        anchorRect = positioningRect

        if let page = contentViewController {
            let size = page.preferredContentSize.width > 0 ? page.preferredContentSize : page.view.frame.size
            updateWindowFrame(size: size, repositionToAnchor: true)
            page.view.frame = surfaceView.pageContainer.bounds
            page.view.layoutSubtreeIfNeeded()
        }

        window.orderFrontRegardless()
        window.invalidateShadow()
        installTransientMonitors()
        onDidShow?()
    }

    func performClose(_ sender: Any?) {
        close()
    }

    func close() {
        let wasShown = window.isVisible
        removeTransientMonitors()
        window.orderOut(nil)
        if wasShown {
            onDidClose?()
        }
    }

    private func setContentSize(_ size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        updateWindowFrame(size: size, repositionToAnchor: window.isVisible && anchorView?.window != nil)
        contentViewController?.view.frame = surfaceView.pageContainer.bounds
        surfaceView.layoutSubtreeIfNeeded()
        if window.isVisible {
            window.invalidateShadow()
        }
    }

    private func updateWindowFrame(size: NSSize, repositionToAnchor: Bool) {
        if repositionToAnchor,
           let anchorView,
           let anchorWindow = anchorView.window {
            let rectInWindow = anchorView.convert(anchorRect, to: nil)
            let screenRect = anchorWindow.convertToScreen(rectInWindow)
            let screen = anchorWindow.screen ?? NSScreen.main
            let bounds = screen?.visibleFrame ?? screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let fullFrame = screen?.frame ?? bounds

            var x = (screenRect.midX - size.width / 2).rounded()
            x = min(max(x, fullFrame.minX + 8), fullFrame.maxX - size.width - 8)

            let gap: CGFloat = 6
            var y = (screenRect.minY - gap - size.height).rounded()
            y = max(bounds.minY + 8, y)

            window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: window.isVisible)
        } else {
            let current = window.frame
            let topY = current.maxY
            let origin = NSPoint(x: current.origin.x, y: topY - size.height)
            window.setFrame(NSRect(origin: origin, size: size), display: window.isVisible)
        }
    }

    private func installTransientMonitors() {
        removeTransientMonitors()

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, self.isShown else { return event }
            if (self.window as? FloatingMenuBarWindow)?.isPresentingAttachedMenu == true {
                return event
            }
            if let eventWindow = event.window {
                if eventWindow === self.window || eventWindow.parent === self.window {
                    return event
                }
                if let anchorWindow = self.anchorView?.window, eventWindow === anchorWindow {
                    return event
                }
            }
            self.close()
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard (self?.window as? FloatingMenuBarWindow)?.isPresentingAttachedMenu != true else { return }
            self?.close()
        }

        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            guard (self?.window as? FloatingMenuBarWindow)?.isPresentingAttachedMenu != true else { return }
            self?.close()
        }
    }

    private func removeTransientMonitors() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
    }
}

// MARK: - Tactile Controls & Capsules

/// Icon actions keep a stable identifier, spoken name, tooltip and keyboard focus
/// even though the visible label is omitted.
final class PanelIconButton: FirstMouseButton {
    let actionName: String
    private let keepsSelection: Bool
    var isProminent = false { didSet { updateSymbolConfiguration(); needsDisplay = true } }
    var isDestructive = false { didSet { needsDisplay = true } }
    var highlightsDestructiveOnHover = false { didSet { needsDisplay = true } }
    var onHoverStateChange: ((Bool) -> Void)?
    private var hovered = false
    private var hoverTracking: NSTrackingArea?
    private(set) var symbolName: String

    init(_ name: String, symbol: String, keepsSelection: Bool = false,
         target: AnyObject? = nil, action: Selector? = nil) {
        actionName = name
        symbolName = symbol
        self.keepsSelection = keepsSelection
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        title = ""
        identifier = NSUserInterfaceItemIdentifier(name)
        toolTip = name
        setAccessibilityLabel(name)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(keepsSelection ? .pushOnPushOff : .momentaryPushIn)
        focusRingType = .exterior
        self.target = target
        self.action = action
        updateSymbolConfiguration()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 26) }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    func setSymbol(_ symbol: String, toolTip: String? = nil, accessibilityLabel: String? = nil) {
        if symbolName != symbol {
            symbolName = symbol
            updateSymbolConfiguration()
        }
        if let toolTip {
            self.toolTip = toolTip
        }
        if let accessibilityLabel {
            setAccessibilityLabel(accessibilityLabel)
        }
        needsDisplay = true
    }

    func clearHover() {
        guard hovered else { return }
        hovered = false
        onHoverStateChange?(false)
        needsDisplay = true
    }

    private func updateSymbolConfiguration() {
        let weight: NSFont.Weight = isProminent ? .semibold : .regular
        let pointSize: CGFloat = 13
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
    }

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
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        onHoverStateChange?(true)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        onHoverStateChange?(false)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = isDarkAppearance
        let selected = keepsSelection && state == .on
        let activeHover = hovered && isEnabled
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

        if isProminent {
            if isHighlighted {
                NSColor.black.withAlphaComponent(0.14).setFill()
                path.fill()
            } else if activeHover {
                NSColor.white.withAlphaComponent(0.14).setFill()
                path.fill()
            }
            contentTintColor = isEnabled ? .white : .white.withAlphaComponent(0.5)
        } else if selected {
            // Segmented-control thumb: a raised chip on the recessed track.
            if !dark {
                NSColor.black.withAlphaComponent(0.10).setFill()
                NSBezierPath(roundedRect: rect.offsetBy(dx: 0, dy: -0.5), xRadius: 6, yRadius: 6).fill()
            }
            let chip = dark
                ? NSColor.white.withAlphaComponent(isHighlighted ? 0.26 : 0.20)
                : NSColor.white.withAlphaComponent(isHighlighted ? 0.90 : 1.0)
            chip.setFill()
            path.fill()
            contentTintColor = .labelColor
        } else if activeHover || isHighlighted {
            let destructiveTint = isDestructive || highlightsDestructiveOnHover
            let fill: NSColor
            if destructiveTint {
                fill = NSColor.systemRed.withAlphaComponent(isHighlighted ? 0.24 : 0.14)
            } else {
                fill = (dark ? NSColor.white : NSColor.black)
                    .withAlphaComponent(isHighlighted ? (dark ? 0.18 : 0.12) : (dark ? 0.11 : 0.07))
            }
            fill.setFill()
            path.fill()
            contentTintColor = destructiveTint ? .systemRed : .labelColor
        } else {
            if isDestructive {
                contentTintColor = isEnabled ? .systemRed : .systemRed.withAlphaComponent(0.38)
            } else {
                contentTintColor = isEnabled
                    ? .secondaryLabelColor
                    : NSColor.labelColor.withAlphaComponent(dark ? 0.24 : 0.22)
            }
        }

        super.draw(dirtyRect)
    }
}

/// Sculpted recessed, accent, or danger-tinted capsule that visually groups toolbar icons.
final class PanelCapsuleView: NSView {
    enum Style {
        case recessed
        case accent
        case danger
    }

    var style: Style = .recessed {
        didSet {
            guard style != oldValue else { return }
            needsDisplay = true
        }
    }

    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let dark = isDarkAppearance
        let strokeRect = bounds.insetBy(dx: 0.25, dy: 0.25)
        let borderPath = NSBezierPath(roundedRect: strokeRect, xRadius: 8, yRadius: 8)
        borderPath.lineWidth = 0.5

        switch style {
        case .recessed:
            // A soft track, never a dark hole: lighter than the panel in dark mode.
            let fill = dark
                ? NSColor.white.withAlphaComponent(0.07)
                : NSColor.black.withAlphaComponent(0.085)
            fill.setFill()
            bounds.fill()

        case .accent:
            let base = NSColor.controlAccentColor
            let top = base.blended(withFraction: isHovered ? 0.22 : 0.14, of: .white) ?? base
            let bottom = base.blended(withFraction: isHovered ? 0.04 : 0.0, of: .white) ?? base
            NSGradient(starting: top, ending: bottom)?.draw(in: bounds, angle: 90)
            NSColor.white.withAlphaComponent(0.28).setStroke()
            borderPath.stroke()

        case .danger:
            let fill = NSColor.systemRed.withAlphaComponent(dark ? 0.18 : 0.11)
            fill.setFill()
            bounds.fill()
            NSColor.systemRed.withAlphaComponent(dark ? 0.38 : 0.26).setStroke()
            borderPath.stroke()
        }
    }
}

/// Text segment for the page switcher. Words beat glyphs here: a pin and a clock
/// are ambiguous, "Pins" and "History" are not. An optional count badge shows
/// how many pins are open without opening the page.
final class PanelTabButton: FirstMouseButton {
    let actionName: String
    var badge: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private var hovered = false
    private var hoverTracking: NSTrackingArea?

    private static let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    private static let selectedFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)

    init(_ name: String) {
        actionName = name
        super.init(frame: NSRect(x: 0, y: 0, width: 60, height: 24))
        title = name
        identifier = NSUserInterfaceItemIdentifier(name)
        toolTip = name
        setAccessibilityLabel(name)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.pushOnPushOff)
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    // Opaque chrome: vibrancy would blend the white chip into the gray track.
    override var allowsVibrancy: Bool { false }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize {
        let text = (actionName as NSString).size(withAttributes: [.font: Self.selectedFont]).width
        var width = ceil(text) + 24
        if let badge { width += badgeSize(badge).width + 5 }
        return NSSize(width: width, height: 24)
    }

    private func badgeSize(_ badge: String) -> NSSize {
        let text = (badge as NSString).size(withAttributes: [.font: Self.badgeFont])
        return NSSize(width: max(16, ceil(text.width) + 9), height: 15)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    func clearHover() { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let dark = isDarkAppearance
        let selected = state == .on
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        if selected {
            if !dark {
                NSColor.black.withAlphaComponent(0.10).setFill()
                NSBezierPath(roundedRect: bounds.offsetBy(dx: 0, dy: -0.5), xRadius: 6, yRadius: 6).fill()
            }
            (dark ? NSColor.white.withAlphaComponent(isHighlighted ? 0.26 : 0.19)
                  : NSColor.white.withAlphaComponent(isHighlighted ? 0.9 : 1)).setFill()
            path.fill()
            if !dark {
                let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 6, yRadius: 6)
                edge.lineWidth = 0.5
                NSColor.black.withAlphaComponent(0.12).setStroke()
                edge.stroke()
            }
        } else if hovered || isHighlighted {
            (dark ? NSColor.white : NSColor.black).withAlphaComponent(isHighlighted ? 0.10 : 0.05).setFill()
            path.fill()
        }

        let font = selected ? Self.selectedFont : Self.font
        let color: NSColor = selected ? .labelColor : .secondaryLabelColor
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textSize = (actionName as NSString).size(withAttributes: attributes)
        let badgeWidth = badge.map { badgeSize($0).width + 5 } ?? 0
        var x = ((bounds.width - textSize.width - badgeWidth) / 2).rounded()
        let textY = ((bounds.height - textSize.height) / 2).rounded()
        (actionName as NSString).draw(at: NSPoint(x: x, y: textY), withAttributes: attributes)
        x += ceil(textSize.width) + 5

        if let badge {
            let size = badgeSize(badge)
            let rect = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
            let fill: NSColor = selected ? .controlAccentColor : NSColor.labelColor.withAlphaComponent(dark ? 0.16 : 0.10)
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: size.height / 2, yRadius: size.height / 2).fill()
            let badgeAttributes: [NSAttributedString.Key: Any] = [
                .font: Self.badgeFont,
                .foregroundColor: selected ? NSColor.white : NSColor.secondaryLabelColor
            ]
            let badgeText = (badge as NSString).size(withAttributes: badgeAttributes)
            (badge as NSString).draw(
                at: NSPoint(x: rect.midX - badgeText.width / 2, y: rect.midY - badgeText.height / 2),
                withAttributes: badgeAttributes
            )
        }
    }
}

/// The one primary action of the panel: an accent, labelled "Pin" button that
/// reads as the thing to press, instead of a faint plus in a corner.
final class PanelPrimaryButton: FirstMouseButton {
    let actionName: String
    private let label: String
    private let symbol: String
    private var hovered = false
    private var hoverTracking: NSTrackingArea?

    private static let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)

    init(_ name: String, label: String, symbol: String) {
        actionName = name
        self.label = label
        self.symbol = symbol
        super.init(frame: NSRect(x: 0, y: 0, width: 60, height: 26))
        title = label
        identifier = NSUserInterfaceItemIdentifier(name)
        toolTip = name
        setAccessibilityLabel(name)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var allowsVibrancy: Bool { false }

    override var intrinsicContentSize: NSSize {
        let text = (label as NSString).size(withAttributes: [.font: Self.font]).width
        return NSSize(width: ceil(text) + 39, height: 26)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    func clearHover() { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let base = NSColor.controlAccentColor
        let fill = isHighlighted
            ? (base.blended(withFraction: 0.18, of: .black) ?? base)
            : hovered ? (base.blended(withFraction: 0.12, of: .white) ?? base) : base
        fill.withAlphaComponent(isEnabled ? 1 : 0.45).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()

        let white = NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.7)
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: white]
        let textSize = (label as NSString).size(withAttributes: attributes)
        let iconSize: CGFloat = 11
        let gap: CGFloat = 5
        var x = ((bounds.width - iconSize - gap - textSize.width) / 2).rounded()
        if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold)
                .applying(.init(paletteColors: [white]))) {
            let size = icon.size
            icon.draw(in: NSRect(x: x + (iconSize - size.width) / 2, y: (bounds.height - size.height) / 2,
                                 width: size.width, height: size.height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        x += iconSize + gap
        (label as NSString).draw(at: NSPoint(x: x, y: ((bounds.height - textSize.height) / 2).rounded()),
                                 withAttributes: attributes)
    }
}

/// Header: `[Pins 3 | History]  ·····  [＋ Pin] [⚙︎]`.
/// Navigation sits on the left like a title; actions sit on the right, with the
/// primary one visually dominant. Never shifts across pages.
final class MenuBarPanelToolbar: NSView {
    static let barHeight: CGFloat = 28

    let pinsButton = PanelTabButton("Pins")
    let historyButton = PanelTabButton("History")
    let pasteButton = PanelPrimaryButton("Pin Clipboard", label: "Pin", symbol: "plus")
    let menuButton = PanelIconButton("App Menu", symbol: "gearshape")
    let appMenu = NSMenu(title: "Pinboard")
    let navCapsule = PanelCapsuleView()

    private let bottomHairline = NSView()
    private let showingHistory: Bool

    var showsBottomSeparator = false {
        didSet { bottomHairline.isHidden = !showsBottomSeparator }
    }

    /// Open pin count shown as a badge on the Pins tab (hidden at zero).
    var pinCount = 0 {
        didSet {
            guard pinCount != oldValue else { return }
            pinsButton.badge = pinCount > 0 ? "\(pinCount)" : nil
            pinsButton.setAccessibilityLabel(pinCount > 0 ? "Pins, \(pinCount) open" : "Pins")
            needsLayout = true
        }
    }

    var onPins: (() -> Void)?
    var onHistory: (() -> Void)?
    var onPaste: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    init(showingHistory: Bool) {
        self.showingHistory = showingHistory
        super.init(frame: .zero)
        syncNavigationState()

        menuButton.toolTip = "Settings & Quit"
        menuButton.setAccessibilityLabel("Settings and Quit")
        refreshShortcutHint()

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(settings), keyEquivalent: ",")
        settingsItem.identifier = NSUserInterfaceItemIdentifier("Settings")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Pinboard", action: #selector(quit), keyEquivalent: "q")
        quitItem.identifier = NSUserInterfaceItemIdentifier("Quit")
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        appMenu.addItem(quitItem)

        bottomHairline.wantsLayer = true
        bottomHairline.isHidden = true

        [navCapsule, pasteButton, menuButton, bottomHairline].forEach { addSubview($0) }
        for (button, action) in [(pinsButton, #selector(pins)), (historyButton, #selector(history))] {
            button.target = self
            button.action = action
            navCapsule.addSubview(button)
        }
        pasteButton.target = self
        pasteButton.action = #selector(paste)
        menuButton.target = self
        menuButton.action = #selector(openAppMenu(_:))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }

    /// The tooltip teaches the global shortcut without spending header space on it.
    func refreshShortcutHint() {
        let hint = MenuBarPanelToolbar.shortcutDisplay.map { "Pin Clipboard (\($0))" } ?? "Pin Clipboard"
        pasteButton.toolTip = hint
    }

    static var shortcutDisplay: String? {
        let preferences = Preferences.shared
        guard preferences.hotkeyEnabled else { return nil }
        return HotKeyManager.Shortcut(keyCode: preferences.hotkeyKeyCode,
                                      carbonModifiers: preferences.hotkeyModifiers).displayString
    }

    private func syncNavigationState() {
        pinsButton.state = showingHistory ? .off : .on
        historyButton.state = showingHistory ? .on : .off
    }

    func clearHoverStates() {
        pinsButton.clearHover()
        historyButton.clearHover()
        pasteButton.clearHover()
        menuButton.clearHover()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        navCapsule.needsDisplay = true
    }

    override func layout() {
        super.layout()
        bottomHairline.layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(isDarkAppearance ? 0.12 : 0.09).cgColor

        let height = Self.barHeight
        let pinsWidth = pinsButton.intrinsicContentSize.width
        let historyWidth = historyButton.intrinsicContentSize.width
        navCapsule.frame = NSRect(x: 0, y: 0, width: pinsWidth + historyWidth + 4, height: height)
        pinsButton.frame = NSRect(x: 2, y: 2, width: pinsWidth, height: height - 4)
        historyButton.frame = NSRect(x: 2 + pinsWidth, y: 2, width: historyWidth, height: height - 4)

        menuButton.frame = NSRect(x: bounds.width - 26, y: 1, width: 26, height: 26)
        let primaryWidth = pasteButton.intrinsicContentSize.width
        pasteButton.frame = NSRect(x: menuButton.frame.minX - 6 - primaryWidth, y: 1, width: primaryWidth, height: 26)
        bottomHairline.frame = NSRect(x: -10, y: bounds.height - 0.5, width: bounds.width + 20, height: 0.5)
    }

    @objc private func pins() { syncNavigationState(); onPins?() }
    @objc private func history() { syncNavigationState(); onHistory?() }
    @objc private func paste() { onPaste?() }
    @objc private func settings() { onSettings?() }
    @objc private func quit() { onQuit?() }

    @objc private func openAppMenu(_ sender: NSButton) {
        let floatingWindow = window as? FloatingMenuBarWindow
        floatingWindow?.isPresentingAttachedMenu = true
        defer {
            floatingWindow?.isPresentingAttachedMenu = false
            menuButton.clearHover()
        }
        appMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
}

/// Bottom action bar: a plain-language status on the left, the actions that
/// apply to it on the right (Raycast-style). Turns red for destructive confirms.
final class MenuBarPanelFooter: NSView {
    static let barHeight: CGFloat = 38

    private var actions: [NSButton] = []
    let statusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    var leadingView: NSView? {
        didSet {
            guard leadingView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let view = leadingView { addSubview(view) }
            needsLayout = true
        }
    }

    var isDangerConfirmation = false {
        didSet {
            guard isDangerConfirmation != oldValue else { return }
            statusLabel.textColor = isDangerConfirmation ? .systemRed : .secondaryLabelColor
            needsDisplay = true
        }
    }

    /// Shows `text` as the leading status (replacing any leading view).
    func setStatus(_ text: String?) {
        if let text {
            statusLabel.stringValue = text
            statusLabel.setAccessibilityLabel(text)
            leadingView = statusLabel
        } else if leadingView === statusLabel {
            leadingView = nil
        }
        needsLayout = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }

    func setActions(_ buttons: [NSButton]) {
        if actions != buttons {
            actions.forEach { $0.removeFromSuperview() }
            actions = buttons
            buttons.forEach { addSubview($0) }
        }
        needsLayout = true
        needsDisplay = true
    }

    func clearHoverStates() {
        actions.compactMap { $0 as? PanelIconButton }.forEach { $0.clearHover() }
        (leadingView as? PanelIconButton)?.clearHover()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = isDarkAppearance
        if isDangerConfirmation {
            NSColor.systemRed.withAlphaComponent(dark ? 0.16 : 0.09).setFill()
            bounds.fill()
            NSColor.systemRed.withAlphaComponent(dark ? 0.36 : 0.24).setFill()
        } else {
            NSColor.labelColor.withAlphaComponent(dark ? 0.035 : 0.025).setFill()
            bounds.fill()
            NSColor.labelColor.withAlphaComponent(dark ? 0.12 : 0.09).setFill()
        }
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
    }

    override func layout() {
        super.layout()
        let verticalY = ((bounds.height - 26) / 2).rounded()

        var rightX = bounds.width - 8
        for (index, button) in actions.enumerated().reversed() {
            rightX -= 26
            button.frame = NSRect(x: rightX, y: verticalY, width: 26, height: 26)
            if index > 0 { rightX -= 2 }
        }

        if let leading = leadingView {
            if let label = leading as? NSTextField {
                let size = label.cell?.cellSize ?? label.intrinsicContentSize
                let maxWidth = max(0, rightX - 14 - 8)
                label.frame = NSRect(x: 14, y: ((bounds.height - size.height) / 2).rounded(),
                                     width: min(ceil(size.width) + 2, maxWidth), height: ceil(size.height))
            } else {
                leading.frame = NSRect(x: 8, y: verticalY, width: 26, height: 26)
            }
        }
    }
}

/// Centered glyph + title + one line of guidance, so an empty page tells you
/// what to do next instead of showing a bare strip.
final class PanelEmptyStateView: NSView {
    static let preferredHeight: CGFloat = 116

    private let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let messageLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.contentTintColor = .tertiaryLabelColor
        iconView.imageScaling = .scaleProportionallyDown
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: 11.5)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 2
        [iconView, titleLabel, messageLabel].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }

    func configure(symbol: String, title: String, message: String) {
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .light))
        titleLabel.stringValue = title
        messageLabel.stringValue = message
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(title). \(message)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let top = ((bounds.height - Self.preferredHeight) / 2).rounded() + 14
        iconView.frame = NSRect(x: bounds.midX - 16, y: top, width: 32, height: 28)
        titleLabel.frame = NSRect(x: 16, y: top + 36, width: bounds.width - 32, height: 18)
        messageLabel.frame = NSRect(x: 24, y: top + 58, width: bounds.width - 48, height: 32)
    }
}

// MARK: - Shared Row & Media Chrome

/// Flat list-row styling shared by Pins and History: rows sit directly on the
/// glass and only gain a soft rounded highlight while hovered.
enum PanelRowStyle {
    static let cornerRadius: CGFloat = 8

    static func hoverFill(dark: Bool) -> NSColor {
        dark ? NSColor.white.withAlphaComponent(0.085) : NSColor.black.withAlphaComponent(0.055)
    }

    static func tileFill(dark: Bool) -> NSColor {
        dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.05)
    }

    static func hairline(dark: Bool) -> NSColor {
        dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.10)
    }

    static let titleFont = NSFont.systemFont(ofSize: 12.5)
}

/// Trailing container for hover-revealed row actions. It is transparent: the
/// row's own highlight already frames the buttons.
final class HoverActionPillView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard alphaValue >= 0.05, !isHidden else { return nil }
        return super.hitTest(point)
    }
}

/// Rounded thumbnail that aspect-fills its frame (top-anchored, so screenshots
/// and documents show their header) instead of letterboxing a tiny image.
/// `image` stays the full preview so callers and tests read the real pixels.
final class PanelThumbnailView: NSImageView {
    var cornerRadius: CGFloat = 6 { didSet { needsDisplay = true } }
    var drawsBorder = true { didSet { needsDisplay = true } }

    override var image: NSImage? { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleProportionallyUpOrDown
        imageFrameStyle = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Width that shows the image at `height` without extreme slivers or strips.
    static func fittedWidth(for image: NSImage?, height: CGFloat, maxWidth: CGFloat) -> CGFloat {
        guard let image, image.size.width > 0, image.size.height > 0 else { return height }
        let natural = height * image.size.width / image.size.height
        return min(max(natural, height), maxWidth).rounded()
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = isDarkAppearance
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        PanelRowStyle.tileFill(dark: dark).setFill()
        bounds.fill()
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let x = bounds.midX - size.width / 2
            let y = isFlipped ? bounds.minY : bounds.maxY - size.height
            image.draw(in: NSRect(x: x, y: y, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }
        NSGraphicsContext.restoreGraphicsState()
        if drawsBorder {
            let stroke = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25),
                                      xRadius: cornerRadius, yRadius: cornerRadius)
            stroke.lineWidth = 0.5
            PanelRowStyle.hairline(dark: dark).setStroke()
            stroke.stroke()
        }
    }
}

/// Panoramic media frame that renders a fast downsampled ambient color wash
/// behind an uncropped aspect-accurate `NSImageView`, eliminating dead grey bars.
final class AmbientImageWellView: NSView {
    private var ambientImage: CGImage?
    var cornerRadius: CGFloat = 8 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }

    func setAmbientSource(_ image: NSImage?) {
        ambientImage = Self.makeTinyAmbientSample(from: image)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = isDarkAppearance
        let baseFill = dark
            ? NSColor.black.withAlphaComponent(0.24)
            : NSColor.black.withAlphaComponent(0.035)
        baseFill.setFill()
        bounds.fill()

        if let ambientImage, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.setAlpha(dark ? 0.34 : 0.22)

            let imgW = CGFloat(ambientImage.width)
            let imgH = CGFloat(ambientImage.height)
            if imgW > 0, imgH > 0, bounds.width > 0, bounds.height > 0 {
                let scale = max(bounds.width / imgW, bounds.height / imgH) * 1.12
                let drawW = imgW * scale
                let drawH = imgH * scale
                let drawRect = CGRect(
                    x: (bounds.width - drawW) / 2,
                    y: (bounds.height - drawH) / 2,
                    width: drawW,
                    height: drawH
                )
                ctx.translateBy(x: 0, y: bounds.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(ambientImage, in: drawRect)
            }
            ctx.restoreGState()

            let scrim = dark
                ? NSColor.black.withAlphaComponent(0.22)
                : NSColor.white.withAlphaComponent(0.24)
            scrim.setFill()
            bounds.fill(using: .sourceOver)
        }

        let border = dark
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.black.withAlphaComponent(0.065)
        border.setStroke()
        let strokePath = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        strokePath.lineWidth = 0.5
        strokePath.stroke()
    }

    private static func makeTinyAmbientSample(from image: NSImage?) -> CGImage? {
        guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
        let sampleW = 20
        let sampleH = 14
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: sampleW,
            pixelsHigh: sampleH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .medium
        image.draw(
            in: NSRect(x: 0, y: 0, width: sampleW, height: sampleH),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}

// MARK: - Sleek Recessed Glass Search Field

private final class GlassSearchFieldCell: NSSearchFieldCell {
    private func centeredTextRect(for rect: NSRect) -> NSRect {
        let searchRect = searchButtonRect(forBounds: rect)
        let cancelRect = cancelButtonRect(forBounds: rect)
        let leftX = searchRect.maxX + 6
        let rightX = stringValue.isEmpty ? (rect.maxX - 8) : (cancelRect.minX - 4)
        let lineHeight: CGFloat = 16
        let y = rect.minY + ((rect.height - lineHeight) / 2).rounded()
        return NSRect(x: leftX, y: y, width: max(0, rightX - leftX), height: lineHeight)
    }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        centeredTextRect(for: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        centeredTextRect(for: rect)
    }

    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        let base = super.searchButtonRect(forBounds: rect)
        let width = min(base.width, 20)
        return NSRect(
            x: rect.minX + 8,
            y: rect.minY + ((rect.height - base.height) / 2).rounded(),
            width: width,
            height: base.height
        )
    }

    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
        let base = super.cancelButtonRect(forBounds: rect)
        return NSRect(
            x: rect.maxX - base.width - 6,
            y: rect.minY + ((rect.height - base.height) / 2).rounded(),
            width: base.width,
            height: base.height
        )
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let dark = controlView.isDarkAppearance
        let isFocused = (controlView.window?.firstResponder as? NSTextView)?.delegate === controlView
        let rect = cellFrame.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)

        // Spotlight-style field: a quiet fill that firms up on focus; no glowing ring.
        let fill = dark
            ? NSColor.white.withAlphaComponent(isFocused ? 0.10 : 0.07)
            : NSColor.black.withAlphaComponent(isFocused ? 0.07 : 0.05)
        fill.setFill()
        path.fill()

        drawInterior(withFrame: cellFrame, in: controlView)
    }
}

final class MenuBarSearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { GlassSearchFieldCell.self }
        set {}
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        placeholderString = ""
        focusRingType = .none
        drawsBackground = false
        isBezeled = true
        controlSize = .regular
        font = .systemFont(ofSize: 12.5)
        sendsSearchStringImmediately = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        needsDisplay = true
        return became
    }
}

// MARK: - Transparent Vibrancy-Aware Page Root

final class MenuBarPanelRootView: NSView {
    var onLayout: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    var onPointerExit: (() -> Void)?
    private var rootTracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let rootTracking { removeTrackingArea(rootTracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        rootTracking = area
    }

    override func mouseExited(with event: NSEvent) {
        onPointerExit?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard window == nil else { return }
        let dark = isDarkAppearance
        let fill = dark
            ? NSColor(srgbRed: 0.12, green: 0.125, blue: 0.138, alpha: 1.0)
            : NSColor(calibratedWhite: 0.96, alpha: 1.0)
        fill.setFill()
        dirtyRect.fill()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if onKeyEquivalent?(event) == true { return }
        interpretKeyEvents([event])
    }
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
