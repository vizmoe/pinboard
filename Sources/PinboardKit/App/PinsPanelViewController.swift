import AppKit

/// A scrollable list with fixed bulk controls and utility actions. Rows are
/// reused by UUID so updates preserve scrolling and keyboard focus.
final class PinsPanelViewController: NSViewController {
    enum UtilityAction { case paste, history, settings, quit }
    enum PinAction { case show, hide, close }

    private let manager: PinWindowManager
    var onUtilityAction: ((UtilityAction) -> Void)?
    var onDismiss: (() -> Void)?
    private(set) var rows: [PinRowView] = []
    let scrollView = NSScrollView()
    let countLabel = NSTextField(labelWithString: "")
    private let document = FlippedView()
    private let emptyView = NSStackView()
    private let header = MenuBarPanelHeader(title: "Pins", showingHistory: false)
    private let bulk = NSStackView()
    private let separator = NSBox()
    private let footer = MenuBarPanelFooter()
    private var listHeight: CGFloat = 136
    private var showAllButton: NSButton!
    private var hideAllButton: NSButton!
    private var closeAllButton: NSButton!
    private static let width: CGFloat = 380
    private static let rowHeight: CGFloat = 88
    private static let rowSpacing: CGFloat = 8

    init(manager: PinWindowManager) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let root = MenuBarPanelRootView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 283))
        root.wantsLayer = true
        root.onLayout = { [weak self] in self?.layoutContent() }
        root.onDismiss = { [weak self] in self?.onDismiss?() }
        view = root
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        header.onPins = { [weak self] in self?.reloadPins() }
        header.onHistory = { [weak self] in self?.onUtilityAction?(.history) }
        header.onPaste = { [weak self] in self?.onUtilityAction?(.paste) }
        footer.onSettings = { [weak self] in self?.onUtilityAction?(.settings) }
        footer.onQuit = { [weak self] in self?.onUtilityAction?(.quit) }

        showAllButton = button("Show All", symbol: "eye", action: #selector(showAll))
        hideAllButton = button("Hide All", symbol: "eye.slash", action: #selector(hideAll))
        closeAllButton = button("Close All", symbol: "xmark", action: #selector(closeAll))
        [showAllButton, hideAllButton, closeAllButton].forEach { bulk.addArrangedSubview($0!) }
        bulk.spacing = 4
        bulk.distribution = .fillEqually

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.documentView = document
        scrollView.setAccessibilityLabel("Current pins")

        emptyView.orientation = .vertical
        emptyView.spacing = 8
        let emptyIcon = NSImageView()
        emptyIcon.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .light))
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyView.addArrangedSubview(emptyIcon)
        let emptyTitle = NSTextField(labelWithString: "No Pins")
        emptyTitle.font = .systemFont(ofSize: 15, weight: .medium)
        let emptyHint = NSTextField(labelWithString: "Pin something from your clipboard.")
        emptyHint.font = .systemFont(ofSize: 12)
        emptyHint.textColor = .secondaryLabelColor
        emptyView.addArrangedSubview(emptyTitle)
        emptyView.addArrangedSubview(emptyHint)

        separator.boxType = .separator
        for child in [header, countLabel, bulk, scrollView, emptyView, separator, footer] { root.addSubview(child) }
        root.onAppearanceChange = { [weak self] in self?.reloadPins() }
    }

    private func layoutContent() {
        let width = view.bounds.width
        header.frame = NSRect(x: 16, y: 14, width: width - 32, height: 32)
        countLabel.frame = NSRect(x: 16, y: 63, width: width - 148, height: 18)
        bulk.frame = NSRect(x: width - 116, y: 54, width: 100, height: 32)
        scrollView.frame = NSRect(x: 12, y: 96, width: width - 24, height: listHeight)
        emptyView.frame = NSRect(x: 16, y: 96 + (listHeight - 92) / 2, width: width - 32, height: 92)
        separator.frame = NSRect(x: 16, y: 108 + listHeight, width: width - 32, height: 1)
        footer.frame = NSRect(x: 16, y: 117 + listHeight, width: width - 32, height: 32)
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
        header.pinsButton.state = .on
        header.historyButton.state = .off
        let count = manager.count
        countLabel.stringValue = "\(count) total · \(manager.visibleCount) visible"
        showAllButton.isEnabled = count > 0
        hideAllButton.isEnabled = manager.visibleCount > 0
        closeAllButton.isEnabled = count > 0
        emptyView.isHidden = count > 0
        scrollView.isHidden = count == 0

        let height = CGFloat(count) * (Self.rowHeight + Self.rowSpacing) - (count > 0 ? Self.rowSpacing : 0)
        listHeight = min(max(height, 144), 376)
        let size = NSSize(width: Self.width, height: listHeight + 159)
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
        manager.notifyChange()
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
    let visibilityLabel = NSTextField(labelWithString: "")
    let showButton = PanelIconButton("Show", symbol: "eye")
    let hideButton = PanelIconButton("Hide", symbol: "eye.slash")
    let closeButton = PanelIconButton("Close", symbol: "xmark")
    private let onAction: (PinsPanelViewController.PinAction, UUID) -> Void

    init(pinID: UUID, onAction: @escaping (PinsPanelViewController.PinAction, UUID) -> Void) {
        self.pinID = pinID
        self.onAction = onAction
        super.init(frame: NSRect(x: 0, y: 0, width: 356, height: 88))
        wantsLayer = true
        layer?.cornerRadius = 9
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.wantsLayer = true
        previewView.layer?.cornerRadius = 5
        previewView.layer?.masksToBounds = true
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        visibilityLabel.font = .systemFont(ofSize: 11)
        visibilityLabel.textColor = .secondaryLabelColor
        for (button, selector) in [(showButton, #selector(show)), (hideButton, #selector(hide)), (closeButton, #selector(close))] {
            button.target = self
            button.action = selector
        }
        let actions = NSStackView(views: [showButton, hideButton, closeButton])
        actions.spacing = 0
        actions.distribution = .fillEqually
        for child in [previewView, titleLabel, visibilityLabel, actions] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            previewView.centerYAnchor.constraint(equalTo: centerYAnchor),
            previewView.widthAnchor.constraint(equalToConstant: 72),
            previewView.heightAnchor.constraint(equalToConstant: 64),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: previewView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            visibilityLabel.centerYAnchor.constraint(equalTo: actions.centerYAnchor),
            visibilityLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            actions.widthAnchor.constraint(equalToConstant: 96),
            actions.heightAnchor.constraint(equalToConstant: 32),
            actions.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor }

    func update(from pin: PinWindowController) {
        let title = pin.contentView.previewTitle
        titleLabel.stringValue = title
        titleLabel.toolTip = title
        visibilityLabel.stringValue = pin.isPinVisible ? "Visible" : "Hidden"
        hideButton.isEnabled = pin.isPinVisible
        previewView.image = pin.contentView.menuPreview(fitting: CGSize(width: 248, height: 176))
        previewView.setAccessibilityLabel("Preview of \(title)")
        for button in [showButton, hideButton, closeButton] {
            button.setAccessibilityLabel("\(button.actionName) Pin: \(title)")
            button.toolTip = "\(button.actionName) Pin"
        }
    }

    @objc private func show() { onAction(.show, pinID) }
    @objc private func hide() { onAction(.hide, pinID) }
    @objc private func close() { onAction(.close, pinID) }
}
