import AppKit

/// Content view of a pin panel: paints the window body, owns the hover chrome
/// and turns mouse activity in the border ring into resize gestures.
final class PinRootView: NSView {
    /// Thickness of the edge hot zone; corners use a larger square so they are
    /// comfortable to grab. Cursor feedback uses exactly the same zones.
    static let resizeMargin: CGFloat = 7
    static let cornerMargin: CGFloat = 14

    weak var pinController: PinWindowController?
    var cornerRadius: CGFloat = 12 { didSet { needsDisplay = true } }
    var drawsBackground = true { didSet { needsDisplay = true } }
    var drawsBorder = true { didSet { needsDisplay = true } }

    /// Paper supplied by the content — a Markdown theme paints its own. nil
    /// keeps the standard text background.
    var themedBackground: NSColor? { didSet { needsDisplay = true } }

    /// Transparent pins paint a barely visible wash while the pointer is over
    /// them or they are being edited, so the window bounds stay discoverable.
    var usesHoverBackground = false { didSet { needsDisplay = true } }
    var isEditingContent = false {
        didSet {
            if isPointerInside {
                chrome.setVisible(!isEditingContent, animated: true)
            } else if isEditingContent {
                chrome.setVisible(false, animated: false)
            }
            needsDisplay = true
        }
    }

    /// Explicit presentation state of the top-center zoom badge so hover,
    /// non-hover transient scroll/pinch feedback, and 100% reset never desync.
    enum ZoomBadgeState: Equatable {
        case hidden
        case visibleWhileHovered
        case transientFeedback(DispatchWorkItem)

        static func == (lhs: ZoomBadgeState, rhs: ZoomBadgeState) -> Bool {
            switch (lhs, rhs) {
            case (.hidden, .hidden), (.visibleWhileHovered, .visibleWhileHovered):
                return true
            case let (.transientFeedback(a), .transientFeedback(b)):
                return a === b
            default:
                return false
            }
        }
    }

    let closeChrome = PinCornerButtonView(symbol: "xmark", tooltip: "Close Pin")
    let zoomBadge = PinZoomBadgeView()
    let hideChrome = PinCornerButtonView(symbol: "eye.slash", tooltip: "Hide Pin")
    let editChrome = PinCornerButtonView(symbol: "pencil", tooltip: "Edit")
    let saveChrome = PinCornerButtonView(symbol: "square.and.arrow.down", tooltip: "Save")
    let chrome = PinChromeView()
    var supportsZoom = true {
        didSet {
            zoomBadge.isHidden = !supportsZoom
            if !supportsZoom {
                cancelZoomBadgeFeedback()
                zoomBadgeState = .hidden
                zoomBadge.setVisible(false, animated: false)
            }
        }
    }
    private var hasEditChromeItem = false
    private var hasSaveChromeItem = false
    private var trackingArea: NSTrackingArea?
    private(set) var isPointerInside = false
    private(set) var zoomBadgeState: ZoomBadgeState = .hidden

    private func cancelZoomBadgeFeedback() {
        if case .transientFeedback(let work) = zoomBadgeState {
            work.cancel()
        }
    }

    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous

        chrome.translatesAutoresizingMaskIntoConstraints = false
        for overlay in [closeChrome, zoomBadge, hideChrome, editChrome, saveChrome, chrome] {
            addSubview(overlay)
        }
        NSLayoutConstraint.activate([
            closeChrome.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            closeChrome.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            zoomBadge.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            zoomBadge.centerXAnchor.constraint(equalTo: centerXAnchor),
            hideChrome.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            hideChrome.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            editChrome.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            editChrome.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            saveChrome.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            saveChrome.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chrome.centerXAnchor.constraint(equalTo: centerXAnchor),
            chrome.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func install(contentView: NSView) {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView, positioned: .below, relativeTo: closeChrome)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func setEditChromeItem(_ item: ChromeItem?) {
        hasEditChromeItem = item != nil
        if let item {
            editChrome.configure(with: item)
        }
        editChrome.isHidden = item == nil
    }

    func setSaveChromeItem(_ item: ChromeItem?) {
        hasSaveChromeItem = item != nil
        if let item {
            saveChrome.configure(with: item)
        }
        saveChrome.isHidden = item == nil
    }

    func setChromeItems(_ items: [ChromeItem]) {
        chrome.setItems(items)
    }

    func setChromeVisible(_ visible: Bool, animated: Bool = true) {
        cancelZoomBadgeFeedback()
        let showZoom = visible && supportsZoom && zoomBadge.isZoomed
        zoomBadgeState = showZoom ? .visibleWhileHovered : .hidden
        closeChrome.setVisible(visible, animated: animated)
        zoomBadge.setVisible(showZoom, animated: animated)
        hideChrome.setVisible(visible, animated: animated)
        editChrome.setVisible(visible && hasEditChromeItem, animated: animated)
        saveChrome.setVisible(visible && hasSaveChromeItem, animated: animated)
        chrome.setVisible(visible && !isEditingContent, animated: animated)
    }

    func updateZoomPercentage(_ percent: Int, animated: Bool = false) {
        guard supportsZoom else {
            cancelZoomBadgeFeedback()
            zoomBadgeState = .hidden
            zoomBadge.setVisible(false, animated: false)
            return
        }
        zoomBadge.setPercentage(percent)
        if !zoomBadge.isZoomed {
            cancelZoomBadgeFeedback()
            zoomBadgeState = .hidden
            zoomBadge.setVisible(false, animated: animated)
        } else if isPointerInside {
            cancelZoomBadgeFeedback()
            zoomBadgeState = .visibleWhileHovered
            zoomBadge.setVisible(true, animated: animated)
        } else if case .transientFeedback = zoomBadgeState {
            // Preserve the active transient feedback timer so a mid-gesture
            // chrome refresh never strands the zoom badge on screen.
            zoomBadge.setVisible(true, animated: false)
        } else {
            zoomBadgeState = .hidden
            zoomBadge.setVisible(false, animated: animated)
        }
    }

    func showZoomFeedback(percent: Int) {
        guard supportsZoom else { return }
        zoomBadge.setPercentage(percent)
        cancelZoomBadgeFeedback()
        guard zoomBadge.isZoomed else {
            zoomBadgeState = .hidden
            zoomBadge.setVisible(false, animated: true)
            return
        }
        if isPointerInside {
            zoomBadgeState = .visibleWhileHovered
            zoomBadge.setVisible(true, animated: false)
            return
        }
        zoomBadge.setVisible(true, animated: false)
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPointerInside else { return }
            self.zoomBadgeState = .hidden
            self.zoomBadge.setVisible(false, animated: true)
        }
        zoomBadgeState = .transientFeedback(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    // MARK: - Appearance

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.backgroundColor = effectiveBackgroundColor.cgColor
        layer.borderWidth = drawsBorder ? 1 : 0
        layer.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
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
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
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
        WindowInteraction.applyCursor(.arrow)
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(for: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(for: event)
    }

    func refreshCursorAtCurrentMouseLocation() {
        guard let window else { return }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = convert(pointInWindow, from: nil)
        if bounds.contains(local) {
            WindowInteraction.applyCursor(cursor(at: local))
        } else {
            WindowInteraction.applyCursor(.arrow)
        }
    }

    func resetPointerState() {
        guard isPointerInside else { return }
        isPointerInside = false
        setChromeVisible(false, animated: false)
        needsDisplay = true
        WindowInteraction.applyCursor(.arrow)
    }

    private func updateCursor(for event: NSEvent) {
        WindowInteraction.applyCursor(cursor(at: convert(event.locationInWindow, from: nil)))
    }

    /// Single source of truth for pointer feedback: every region reports the
    /// cursor for the gesture it actually performs.
    func cursor(at point: NSPoint) -> NSCursor {
        let edge = resizeEdge(at: point)
        if !edge.isEmpty { return edge.cursor }
        for overlay in [closeChrome, zoomBadge, hideChrome, editChrome, saveChrome, chrome] where overlay.alphaValue > 0.01 {
            if overlay.frame.insetBy(dx: -2, dy: -2).contains(point) { return .arrow }
        }
        return pinController?.contentView.cursor(at: point) ?? .arrow
    }

    // MARK: - Trackpad zoom

    override func magnify(with event: NSEvent) {
        pinController?.handleMagnify(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        pinController?.handleScrollWheel(with: event)
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
        if event.clickCount == 2, !isEditingContent {
            pinController?.copyAndClose()
            return
        }
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
