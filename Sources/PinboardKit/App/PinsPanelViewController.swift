import AppKit

/// A scrollable card stream with fixed bulk controls and utility actions. Rows are
/// reused by UUID so updates preserve scrolling and keyboard focus.
final class PinsPanelViewController: NSViewController {
    typealias UtilityAction = MenuBarUtilityAction
    enum PinAction { case show, toggleVisibility, close }

    private let manager: PinWindowManager
    var onUtilityAction: ((MenuBarUtilityAction) -> Void)?
    var onDismiss: (() -> Void)?
    private(set) var rows: [PinRowView] = []
    let scrollView = NSScrollView()
    let toolbar = MenuBarPanelToolbar(showingHistory: false)
    let footer = MenuBarPanelFooter()
    let emptyStateView = PanelEmptyStateView()
    private let document = FlippedView()
    private var listHeight: CGFloat = 0
    private(set) var toggleVisibilityButton: PanelIconButton!
    private(set) var closeAllButton: PanelIconButton!
    private var scrollBoundsObserver: NSObjectProtocol?
    private static let width: CGFloat = 320
    private static let rowHeight: CGFloat = 52
    private static let rowSpacing: CGFloat = 2
    /// Header controls (28) + gap + hairline; content begins just below it.
    static let headerHeight: CGFloat = 38
    private static let listTop: CGFloat = 52

    init(manager: PinWindowManager) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    deinit {
        if let scrollBoundsObserver {
            NotificationCenter.default.removeObserver(scrollBoundsObserver)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let root = MenuBarPanelRootView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 48))
        root.wantsLayer = true
        root.onLayout = { [weak self] in self?.layoutContent() }
        root.onDismiss = { [weak self] in self?.onDismiss?() }
        root.onPointerExit = { [weak self] in self?.clearHoverState() }
        view = root

        toolbar.onPins = { [weak self] in self?.reloadPins() }
        toolbar.onHistory = { [weak self] in self?.onUtilityAction?(.history) }
        toolbar.onPaste = { [weak self] in self?.onUtilityAction?(.paste) }
        toolbar.onSettings = { [weak self] in self?.onUtilityAction?(.settings) }
        toolbar.onQuit = { [weak self] in self?.onUtilityAction?(.quit) }

        toggleVisibilityButton = button("Toggle Visibility", symbol: "eye.slash", action: #selector(toggleAllVisibility))
        closeAllButton = button("Close All", symbol: "xmark", action: #selector(closeAll))
        closeAllButton.highlightsDestructiveOnHover = true
        footer.setActions([toggleVisibilityButton, closeAllButton])

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.documentView = document
        scrollView.setAccessibilityLabel("Current pins")
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.syncHoveredRowWithPointer()
        }

        [toolbar, scrollView, emptyStateView, footer].forEach { root.addSubview($0) }
        root.onAppearanceChange = { [weak self] in self?.reloadPins() }
        root.onKeyEquivalent = { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
                self?.onUtilityAction?(.history)
                return true
            }
            return false
        }
    }

    private func layoutContent() {
        let width = view.bounds.width
        let height = view.bounds.height
        let hasPins = !rows.isEmpty
        toolbar.showsBottomSeparator = true
        toolbar.frame = NSRect(x: 10, y: 10, width: width - 20, height: Self.headerHeight)
        scrollView.frame = NSRect(x: 6, y: Self.listTop, width: width - 12, height: listHeight)
        emptyStateView.frame = NSRect(x: 0, y: 48, width: width, height: PanelEmptyStateView.preferredHeight)
        footer.frame = NSRect(
            x: 0,
            y: height - MenuBarPanelFooter.barHeight,
            width: width,
            height: MenuBarPanelFooter.barHeight
        )

        let contentHeight = CGFloat(rows.count) * (Self.rowHeight + Self.rowSpacing) - (hasPins ? Self.rowSpacing : 0)
        document.setFrameSize(NSSize(width: scrollView.contentSize.width, height: max(contentHeight, listHeight)))
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(
                x: 0,
                y: CGFloat(index) * (Self.rowHeight + Self.rowSpacing),
                width: document.bounds.width,
                height: Self.rowHeight
            )
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadPins()
    }

    func clearHoverState() {
        for row in rows {
            row.isHovered = false
        }
        toolbar.clearHoverStates()
        footer.clearHoverStates()
    }

    private func clearHoverExcept(_ activeRow: PinRowView) {
        for row in rows where row !== activeRow {
            row.isHovered = false
        }
    }

    private func syncHoveredRowWithPointer() {
        guard let window = view.window, window.isVisible else { return }
        let pointInWindow = window.mouseLocationOutsideOfEventStream
        let pointInScroll = scrollView.convert(pointInWindow, from: nil)
        guard scrollView.bounds.contains(pointInScroll) else {
            for row in rows { row.isHovered = false }
            return
        }
        for row in rows {
            let pointInRow = row.convert(pointInWindow, from: nil)
            row.isHovered = row.bounds.contains(pointInRow)
        }
    }

    func reloadPins() {
        _ = view // Load on macOS 13 as well as newer releases.
        let previousOrigin = scrollView.contentView.bounds.origin
        let previous = Dictionary(uniqueKeysWithValues: rows.map { ($0.pinID, $0) })
        let ids = Set(manager.pins.map(\.id))
        let focused = view.window?.firstResponder as? NSView
        let removedFocusedRow = rows.contains { row in
            !ids.contains(row.pinID) && focused.map { $0.isDescendant(of: row) } == true
        }
        for row in rows where !ids.contains(row.pinID) { row.removeFromSuperview() }
        rows = manager.pins.map { pin in
            let row = previous[pin.id] ?? PinRowView(pinID: pin.id) { [weak self] action, id in
                self?.perform(action, for: id)
            }
            row.onHoverEntered = { [weak self] entered in
                self?.clearHoverExcept(entered)
            }
            if row.superview == nil { document.addSubview(row) }
            view.effectiveAppearance.performAsCurrentDrawingAppearance { row.update(from: pin) }
            return row
        }
        let count = manager.count
        let visibleCount = manager.visibleCount
        view.setAccessibilityLabel("Pins: \(count) total, \(visibleCount) visible")
        if visibleCount > 0 {
            toggleVisibilityButton.setSymbol("eye.slash", toolTip: "Hide All", accessibilityLabel: "Hide All")
        } else {
            toggleVisibilityButton.setSymbol("eye", toolTip: "Show All", accessibilityLabel: "Show All")
        }
        toggleVisibilityButton.isEnabled = count > 0
        closeAllButton.isEnabled = count > 0
        toolbar.pinCount = count
        toolbar.refreshShortcutHint()
        let hidden = count - visibleCount
        footer.setStatus(count == 0 ? nil
            : "\(count) \(count == 1 ? "pin" : "pins")" + (hidden > 0 ? " · \(hidden) hidden" : ""))
        scrollView.isHidden = count == 0
        footer.isHidden = count == 0
        emptyStateView.isHidden = count > 0
        if count == 0 {
            let shortcut = MenuBarPanelToolbar.shortcutDisplay.map { " or press \($0)" } ?? ""
            emptyStateView.configure(symbol: "pin", title: "No Pins",
                                     message: "Copy something, then click Pin\(shortcut).")
        }

        let contentHeight = CGFloat(count) * (Self.rowHeight + Self.rowSpacing) - (count > 0 ? Self.rowSpacing : 0)
        listHeight = min(contentHeight, 324)
        let totalHeight: CGFloat = count > 0
            ? (Self.listTop + listHeight + 6 + MenuBarPanelFooter.barHeight)
            : 48 + PanelEmptyStateView.preferredHeight
        let size = NSSize(width: Self.width, height: totalHeight)
        preferredContentSize = size
        if view.superview == nil { view.setFrameSize(size) }
        layoutContent()
        view.layoutSubtreeIfNeeded()
        let y = min(previousOrigin.y, max(0, document.bounds.height - scrollView.contentSize.height))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if removedFocusedRow || (focused != nil && (focused?.window == nil || focused?.isHiddenOrHasHiddenAncestor == true)) {
            view.window?.makeFirstResponder(rows.first?.visibilityButton ?? view)
        }
    }

    private func perform(_ action: PinAction, for id: UUID) {
        guard let pin = manager.pin(with: id) else { return }
        switch action {
        case .show:
            pin.present()
        case .toggleVisibility:
            if pin.isPinVisible {
                pin.hidePin()
            } else {
                pin.present()
            }
        case .close:
            pin.closePin()
        }
        reloadPins()
    }

    private func button(_ title: String, symbol: String, action: Selector) -> PanelIconButton {
        PanelIconButton(title, symbol: symbol, target: self, action: action)
    }

    @objc private func toggleAllVisibility() { manager.toggleAll(); reloadPins() }
    @objc private func closeAll() { manager.closeAll(); reloadPins() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One pin in the list: a flat row on the glass with a real thumbnail, the pin's
/// own text, and per-pin actions that appear on hover or keyboard focus.
final class PinRowView: NSView {
    let pinID: UUID
    let previewView = PanelThumbnailView()
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let visibilityButton = PanelIconButton("Toggle Pin Visibility", symbol: "eye.slash")
    let closeButton = PanelIconButton("Close", symbol: "xmark")
    var onHoverEntered: ((PinRowView) -> Void)?

    private let emptyNoteGlyph = NSImageView()
    private let hiddenGlyph = NSImageView()
    private let actionPill = HoverActionPillView()
    private let onAction: (PinsPanelViewController.PinAction, UUID) -> Void

    private var isImagePin = false
    private var isPinVisibleState = true
    private var hovered = false
    private var hoverTracking: NSTrackingArea?
    private var presentedMouseDownEventNumber: Int?

    private static let thumbHeight: CGFloat = 40
    private static let inset: CGFloat = 6
    private static let actionsWidth: CGFloat = 56

    var isHovered: Bool {
        get { hovered }
        set {
            guard hovered != newValue else { return }
            hovered = newValue
            if !newValue {
                visibilityButton.clearHover()
                closeButton.clearHover()
            }
            syncHoverPresentation(animated: false)
            needsLayout = true
            needsDisplay = true
        }
    }

    init(pinID: UUID, onAction: @escaping (PinsPanelViewController.PinAction, UUID) -> Void) {
        self.pinID = pinID
        self.onAction = onAction
        super.init(frame: NSRect(x: 0, y: 0, width: 308, height: 52))
        wantsLayer = true
        layer?.cornerRadius = PanelRowStyle.cornerRadius
        layer?.cornerCurve = .continuous

        previewView.cornerRadius = 6

        emptyNoteGlyph.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        emptyNoteGlyph.contentTintColor = .tertiaryLabelColor
        emptyNoteGlyph.isHidden = true

        titleLabel.font = PanelRowStyle.titleFont
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.cell?.truncatesLastVisibleLine = true

        hiddenGlyph.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        hiddenGlyph.contentTintColor = .tertiaryLabelColor
        hiddenGlyph.isHidden = true

        closeButton.highlightsDestructiveOnHover = true
        for (button, selector) in [
            (visibilityButton, #selector(toggleVisibility)),
            (closeButton, #selector(close))
        ] {
            button.target = self
            button.action = selector
            actionPill.addSubview(button)
        }
        actionPill.alphaValue = 0

        [previewView, emptyNoteGlyph, titleLabel, hiddenGlyph, actionPill].forEach { addSubview($0) }
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        onHoverEntered?(self)
        guard !hovered else { return }
        hovered = true
        syncHoverPresentation(animated: true)
        needsLayout = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered else { return }
        hovered = false
        visibilityButton.clearHover()
        closeButton.clearHover()
        syncHoverPresentation(animated: true)
        needsLayout = true
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hitActionPill = actionPill.alphaValue >= 0.05 && actionPill.frame.contains(point)
        if !hitActionPill {
            presentedMouseDownEventNumber = event.eventNumber
            onAction(.show, pinID)
        } else {
            presentedMouseDownEventNumber = nil
            super.mouseDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if presentedMouseDownEventNumber == event.eventNumber {
            presentedMouseDownEventNumber = nil
            return
        }
        presentedMouseDownEventNumber = nil
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if actionPill.alphaValue >= 0.05, actionPill.frame.contains(point) { return }
        onAction(.show, pinID)
    }

    private var hasKeyboardFocusInside: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: actionPill)
    }

    private var controlsVisible: Bool {
        hovered || hasKeyboardFocusInside
    }

    private func syncHoverPresentation(animated: Bool) {
        let targetAlpha: CGFloat = controlsVisible ? 1 : 0
        hiddenGlyph.isHidden = isPinVisibleState || controlsVisible
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                actionPill.animator().alphaValue = targetAlpha
            }
        } else {
            actionPill.alphaValue = targetAlpha
        }
    }

    override func updateLayer() {
        layer?.backgroundColor = hovered
            ? PanelRowStyle.hoverFill(dark: isDarkAppearance).cgColor
            : NSColor.clear.cgColor
    }

    override func layout() {
        super.layout()
        let inset = Self.inset
        let thumbHeight = Self.thumbHeight
        let thumbY = ((bounds.height - thumbHeight) / 2).rounded()

        actionPill.frame = NSRect(
            x: bounds.width - Self.actionsWidth - inset,
            y: ((bounds.height - 26) / 2).rounded(),
            width: Self.actionsWidth,
            height: 26
        )
        visibilityButton.frame = NSRect(x: 0, y: 0, width: 26, height: 26)
        closeButton.frame = NSRect(x: 30, y: 0, width: 26, height: 26)
        hiddenGlyph.frame = NSRect(x: bounds.width - 30, y: ((bounds.height - 16) / 2).rounded(), width: 18, height: 16)

        if isImagePin {
            // Image pins are their picture: a real thumbnail, never a letterboxed well.
            let maxWidth = bounds.width - inset * 2 - Self.actionsWidth - 8
            let width = PanelThumbnailView.fittedWidth(for: previewView.image, height: thumbHeight, maxWidth: maxWidth)
            previewView.frame = NSRect(x: inset + 2, y: thumbY, width: width, height: thumbHeight)
        } else {
            let thumb = NSRect(x: inset + 2, y: thumbY, width: thumbHeight, height: thumbHeight)
            previewView.frame = thumb
            emptyNoteGlyph.frame = NSRect(x: thumb.midX - 8, y: thumb.midY - 8, width: 16, height: 16)

            let labelX = thumb.maxX + 10
            let trailing: CGFloat = controlsVisible ? Self.actionsWidth + inset + 6 : (isPinVisibleState ? 10 : 34)
            let labelWidth = max(40, bounds.width - labelX - trailing)
            let measured = titleLabel.cell?.cellSize(
                forBounds: NSRect(x: 0, y: 0, width: labelWidth, height: 36)
            ).height ?? 16
            let height = min(36, ceil(measured))
            titleLabel.frame = NSRect(
                x: labelX, y: ((bounds.height - height) / 2).rounded(), width: labelWidth, height: height
            )
        }
    }

    func update(from pin: PinWindowController) {
        let title = pin.contentView.previewTitle
        let text = pin.contentView.menuPreviewText
        isImagePin = pin.kind == .image
        isPinVisibleState = pin.isPinVisible

        titleLabel.stringValue = text ?? ""
        titleLabel.toolTip = text
        titleLabel.isHidden = isImagePin || text == nil
        emptyNoteGlyph.isHidden = isImagePin || text != nil

        let visibility = pin.isPinVisible ? "Visible" : "Hidden"
        setAccessibilityLabel("\(title), \(visibility)")
        toolTip = "\(title) · \(visibility)"

        // Hidden pins recede but stay legible.
        previewView.alphaValue = pin.isPinVisible ? 1.0 : 0.45
        emptyNoteGlyph.alphaValue = previewView.alphaValue
        titleLabel.textColor = pin.isPinVisible ? .labelColor : .secondaryLabelColor

        let previewFitting = isImagePin
            ? CGSize(width: 280, height: 176)
            : CGSize(width: 144, height: 132)
        previewView.image = pin.contentView.menuPreview(fitting: previewFitting)
        previewView.setAccessibilityLabel("Preview of \(title)")

        if pin.isPinVisible {
            visibilityButton.setSymbol("eye.slash", toolTip: "Hide Pin", accessibilityLabel: "Hide Pin: \(title)")
        } else {
            visibilityButton.setSymbol("eye", toolTip: "Show Pin", accessibilityLabel: "Show Pin: \(title)")
        }
        closeButton.setAccessibilityLabel("Close Pin: \(title)")
        closeButton.toolTip = "Close Pin"

        syncHoverPresentation(animated: false)
        needsLayout = true
        needsDisplay = true
    }

    @objc private func toggleVisibility() { onAction(.toggleVisibility, pinID) }
    @objc private func close() { onAction(.close, pinID) }
}
