import AppKit

/// Content view of a pin panel: paints the window body, owns the hover chrome
/// and turns mouse activity in the border ring into resize gestures.
final class PinRootView: NSView {
    /// Thickness of the edge hot zone; corners use a larger square so they are
    /// comfortable to grab. Cursor feedback uses exactly the same zones.
    static let resizeMargin: CGFloat = 7
    static let cornerMargin: CGFloat = 14

    weak var pinController: PinWindowController?
    var cornerRadius: CGFloat = 10 { didSet { needsDisplay = true } }
    var drawsBackground = true { didSet { needsDisplay = true } }
    var drawsBorder = true { didSet { needsDisplay = true } }

    /// Paper supplied by the content — a Markdown theme paints its own. nil
    /// keeps the standard text background.
    var themedBackground: NSColor? { didSet { needsDisplay = true } }

    /// Transparent pins paint a barely visible wash while the pointer is over
    /// them or they are being edited, so the window bounds stay discoverable.
    var usesHoverBackground = false { didSet { needsDisplay = true } }
    var isEditingContent = false { didSet { needsDisplay = true } }

    private let chrome = PinChromeView()
    private var trackingArea: NSTrackingArea?
    private var isPointerInside = false

    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        chrome.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chrome)
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            chrome.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func install(contentView: NSView) {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView, positioned: .below, relativeTo: chrome)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func setChromeItems(_ items: [ChromeItem]) {
        chrome.setItems(items)
    }

    func setChromeVisible(_ visible: Bool) {
        chrome.setVisible(visible)
    }

    // MARK: - Appearance

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = cornerRadius
        layer.backgroundColor = effectiveBackgroundColor.cgColor
        layer.borderWidth = drawsBorder ? 1 : 0
        layer.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
    }

    /// The colour the pin body paints right now.
    var effectiveBackgroundColor: NSColor {
        if drawsBackground { return themedBackground ?? .textBackgroundColor }
        guard usesHoverBackground, isPointerInside || isEditingContent else { return .clear }
        return NSColor.labelColor.withAlphaComponent(0.07)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        setChromeVisible(true)
        needsDisplay = true
        updateCursor(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        setChromeVisible(false)
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(for: event)
    }

    private func updateCursor(for event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    /// Single source of truth for pointer feedback: every region reports the
    /// cursor for the gesture it actually performs.
    func cursor(at point: NSPoint) -> NSCursor {
        let edge = resizeEdge(at: point)
        if !edge.isEmpty { return edge.cursor }
        if chrome.alphaValue > 0.01, chrome.frame.insetBy(dx: -2, dy: -2).contains(point) { return .arrow }
        return pinController?.contentView.cursor(at: point) ?? .arrow
    }

    // MARK: - Pinch to zoom

    override func magnify(with event: NSEvent) {
        guard event.magnification != 0 else { return }
        pinController?.zoom(by: 1 + event.magnification)
    }

    // MARK: - Hit testing & mouse

    /// The border ring wins over any content view so edges stay grabbable even
    /// when a text view or annotation canvas covers the whole window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !resizeEdge(at: local).isEmpty { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        let edge = resizeEdge(at: point)
        if !edge.isEmpty {
            pinController?.beginResize(edge: edge)
        } else {
            WindowInteraction.move(window: window, dragCursor: .closedHand, endCursor: cursor(at: point))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = pinController?.makeContextMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func resizeEdge(at point: NSPoint) -> ResizeEdge {
        let margin = min(PinRootView.resizeMargin, bounds.width / 4, bounds.height / 4)
        let corner = min(PinRootView.cornerMargin, bounds.width / 3, bounds.height / 3)

        let nearLeftCorner = point.x <= corner
        let nearRightCorner = point.x >= bounds.maxX - corner
        let nearBottomCorner = point.y <= corner
        let nearTopCorner = point.y >= bounds.maxY - corner
        switch (nearLeftCorner, nearRightCorner, nearBottomCorner, nearTopCorner) {
        case (true, _, true, _): return [.left, .bottom]
        case (true, _, _, true): return [.left, .top]
        case (_, true, true, _): return [.right, .bottom]
        case (_, true, _, true): return [.right, .top]
        default: break
        }

        var edge: ResizeEdge = []
        if point.x <= margin { edge.insert(.left) }
        if point.x >= bounds.maxX - margin { edge.insert(.right) }
        if point.y <= margin { edge.insert(.bottom) }
        if point.y >= bounds.maxY - margin { edge.insert(.top) }
        return edge
    }
}
