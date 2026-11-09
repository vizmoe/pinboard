import AppKit

/// A scrollable list with fixed bulk controls and utility actions. Rows are
/// reused by UUID so updates preserve scrolling and keyboard focus.
final class PinsPanelViewController: NSViewController {
    typealias UtilityAction = MenuBarUtilityAction
    enum PinAction { case show, hide, close }

    private let manager: PinWindowManager
    var onUtilityAction: ((MenuBarUtilityAction) -> Void)?
    var onDismiss: (() -> Void)?
    private(set) var rows: [PinRowView] = []
    let scrollView = NSScrollView()
    private let document = FlippedView()
    private let toolbar = MenuBarPanelToolbar(showingHistory: false)
    private var listHeight: CGFloat = 0
    private var showAllButton: NSButton!
    private var hideAllButton: NSButton!
    private var closeAllButton: NSButton!
    private static let width: CGFloat = 320
    private static let rowHeight: CGFloat = 60
    private static let rowSpacing: CGFloat = 4

    init(manager: PinWindowManager) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let root = MenuBarPanelRootView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 46))
        root.wantsLayer = true
        root.onLayout = { [weak self] in self?.layoutContent() }
        root.onDismiss = { [weak self] in self?.onDismiss?() }
        view = root
        toolbar.onPins = { [weak self] in self?.reloadPins() }
        toolbar.onHistory = { [weak self] in self?.onUtilityAction?(.history) }
        toolbar.onPaste = { [weak self] in self?.onUtilityAction?(.paste) }
        toolbar.onSettings = { [weak self] in self?.onUtilityAction?(.settings) }
        toolbar.onQuit = { [weak self] in self?.onUtilityAction?(.quit) }

        showAllButton = button("Show All", symbol: "eye", action: #selector(showAll))
        hideAllButton = button("Hide All", symbol: "eye.slash", action: #selector(hideAll))
        closeAllButton = button("Close All", symbol: "xmark", action: #selector(closeAll))
        toolbar.setActions([showAllButton, hideAllButton, closeAllButton])

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.documentView = document
        scrollView.setAccessibilityLabel("Current pins")

        [toolbar, scrollView].forEach { root.addSubview($0) }
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
        toolbar.frame = NSRect(x: 10, y: 10, width: width - 20, height: 26)
        scrollView.frame = NSRect(x: 8, y: 46, width: width - 16, height: listHeight)
        let height = CGFloat(rows.count) * (Self.rowHeight + Self.rowSpacing) - (rows.isEmpty ? 0 : Self.rowSpacing)
        document.setFrameSize(NSSize(width: scrollView.contentSize.width, height: max(height, listHeight)))
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * (Self.rowHeight + Self.rowSpacing),
                               width: document.bounds.width, height: Self.rowHeight)
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadPins()
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
            if row.superview == nil { document.addSubview(row) }
            view.effectiveAppearance.performAsCurrentDrawingAppearance { row.update(from: pin) }
            return row
        }
        let count = manager.count
        view.setAccessibilityLabel("Pins: \(count) total, \(manager.visibleCount) visible")
        showAllButton.isEnabled = count > 0
        hideAllButton.isEnabled = manager.visibleCount > 0
        closeAllButton.isEnabled = count > 0
        scrollView.isHidden = count == 0

        let height = CGFloat(count) * (Self.rowHeight + Self.rowSpacing) - (count > 0 ? Self.rowSpacing : 0)
        listHeight = min(height, 316)
        let size = NSSize(width: Self.width, height: 46 + listHeight + (count > 0 ? 8 : 0))
        preferredContentSize = size
        // AppKit sizes an attached page from preferredContentSize. Setting its
        // frame here turns the old height difference into an autoresizing margin
        // and prevents the surrounding popover from shrinking.
        if view.superview == nil { view.setFrameSize(size) }
        layoutContent()
        view.layoutSubtreeIfNeeded()
        let y = min(previousOrigin.y, max(0, document.bounds.height - scrollView.contentSize.height))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if removedFocusedRow { view.window?.makeFirstResponder(rows.first?.showButton ?? view) }
    }

    private func perform(_ action: PinAction, for id: UUID) {
        guard let pin = manager.pin(with: id) else { return }
        switch action {
        case .show: pin.present()
        case .hide: pin.hidePin()
        case .close: pin.closePin()
        }
        reloadPins()
    }

    private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
        PanelIconButton(title, symbol: symbol, target: self, action: action)
    }

    @objc private func showAll() { manager.showAll(); reloadPins() }
    @objc private func hideAll() { manager.hideAll(); reloadPins() }
    @objc private func closeAll() { manager.closeAll(); reloadPins() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class PinRowView: NSView {
    let pinID: UUID
    let previewView = NSImageView()
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let showButton = PanelIconButton("Show", symbol: "eye")
    let hideButton = PanelIconButton("Hide", symbol: "eye.slash")
    let closeButton = PanelIconButton("Close", symbol: "xmark")
    private let onAction: (PinsPanelViewController.PinAction, UUID) -> Void

    init(pinID: UUID, onAction: @escaping (PinsPanelViewController.PinAction, UUID) -> Void) {
        self.pinID = pinID
        self.onAction = onAction
        super.init(frame: NSRect(x: 0, y: 0, width: 304, height: 60))
        wantsLayer = true
        layer?.cornerRadius = 6
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.wantsLayer = true
        previewView.layer?.cornerRadius = 3
        previewView.layer?.masksToBounds = true
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        for (button, selector) in [(showButton, #selector(show)), (hideButton, #selector(hide)), (closeButton, #selector(close))] {
            button.target = self
            button.action = selector
        }
        [previewView, titleLabel, showButton, hideButton, closeButton].forEach { addSubview($0) }
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor }

    override func layout() {
        super.layout()
        let actionsX = bounds.width - 86
        previewView.frame = NSRect(x: 8, y: 8, width: titleLabel.isHidden ? actionsX - 16 : 52, height: 44)
        titleLabel.frame = NSRect(x: 68, y: 12, width: max(0, actionsX - 76), height: 36)
        for (index, button) in [showButton, hideButton, closeButton].enumerated() {
            button.frame = NSRect(x: actionsX + CGFloat(index) * 26, y: 17, width: 26, height: 26)
        }
    }

    func update(from pin: PinWindowController) {
        let title = pin.contentView.previewTitle
        let text = pin.contentView.menuPreviewText
        titleLabel.stringValue = text ?? ""
        titleLabel.toolTip = text
        titleLabel.isHidden = text == nil
        let visibility = pin.isPinVisible ? "Visible" : "Hidden"
        setAccessibilityLabel("\(title), \(visibility)")
        toolTip = "\(title) · \(visibility)"
        hideButton.isEnabled = pin.isPinVisible
        previewView.alphaValue = pin.isPinVisible ? 1 : 0.5
        titleLabel.alphaValue = previewView.alphaValue
        previewView.image = pin.contentView.menuPreview(fitting: CGSize(width: 248, height: 176))
        previewView.setAccessibilityLabel("Preview of \(title)")
        for button in [showButton, hideButton, closeButton] {
            button.setAccessibilityLabel("\(button.actionName) Pin: \(title)")
            button.toolTip = "\(button.actionName) Pin"
        }
        needsLayout = true
    }

    @objc private func show() { onAction(.show, pinID) }
    @objc private func hide() { onAction(.hide, pinID) }
    @objc private func close() { onAction(.close, pinID) }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let hitButton = [showButton, hideButton, closeButton].contains { $0.frame.contains(local) }
        if !hitButton {
            onAction(.show, pinID)
        } else {
            super.mouseDown(with: event)
        }
    }
}
