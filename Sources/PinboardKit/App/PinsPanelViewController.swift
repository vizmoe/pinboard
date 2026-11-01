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
    private let header = NSStackView()
    private let bulk = NSStackView()
    private let separator = NSBox()
    private let footer = NSStackView()
    private var listHeight: CGFloat = 136
    private var showAllButton: NSButton!
    private var hideAllButton: NSButton!
    private var closeAllButton: NSButton!
    private static let width: CGFloat = 448
    private static let rowHeight: CGFloat = 112
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
        let title = NSTextField(labelWithString: "Pins")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        header.addArrangedSubview(title)
        header.addArrangedSubview(countLabel)
        header.spacing = 10
        header.alignment = .firstBaseline

        showAllButton = button("Show All", symbol: "eye", action: #selector(showAll))
        hideAllButton = button("Hide All", symbol: "eye.slash", action: #selector(hideAll))
        closeAllButton = button("Close All", symbol: "xmark", action: #selector(closeAll))
        [showAllButton, hideAllButton, closeAllButton].forEach { bulk.addArrangedSubview($0!) }
        bulk.spacing = 8
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
        let emptyTitle = NSTextField(labelWithString: "No Pins")
        emptyTitle.font = .systemFont(ofSize: 15, weight: .medium)
        let emptyHint = NSTextField(labelWithString: "Pin clipboard content to get started.")
        emptyHint.font = .systemFont(ofSize: 12)
        emptyHint.textColor = .secondaryLabelColor
        emptyView.addArrangedSubview(emptyTitle)
        emptyView.addArrangedSubview(emptyHint)

        separator.boxType = .separator
        [
            button("Pin Clipboard", symbol: "plus", action: #selector(paste)),
            button("History", action: #selector(history)),
            button("Settings", action: #selector(settings)),
            button("Quit", action: #selector(quit))
        ].forEach { footer.addArrangedSubview($0) }
        footer.spacing = 8
        footer.distribution = .fillProportionally

        for child in [header, bulk, scrollView, emptyView, separator, footer] { root.addSubview(child) }
    }

    private func layoutContent() {
        let width = view.bounds.width
        header.frame = NSRect(x: 16, y: 16, width: width - 32, height: 24)
        bulk.frame = NSRect(x: 16, y: 52, width: width - 32, height: 24)
        scrollView.frame = NSRect(x: 12, y: 88, width: width - 24, height: listHeight)
        emptyView.frame = NSRect(x: 16, y: 88 + (listHeight - 44) / 2, width: width - 32, height: 44)
        separator.frame = NSRect(x: 16, y: 100 + listHeight, width: width - 32, height: 1)
        footer.frame = NSRect(x: 16, y: 111 + listHeight, width: width - 32, height: 24)
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
            row.update(from: pin)
            return row
        }
        let count = manager.count
        countLabel.stringValue = "\(count) total · \(manager.visibleCount) visible"
        showAllButton.isEnabled = count > 0
        hideAllButton.isEnabled = manager.visibleCount > 0
        closeAllButton.isEnabled = count > 0
        emptyView.isHidden = count > 0
        scrollView.isHidden = count == 0

        let height = CGFloat(count) * (Self.rowHeight + Self.rowSpacing) - (count > 0 ? Self.rowSpacing : 0)
        listHeight = min(max(height, 136), 472)
        let size = NSSize(width: Self.width, height: listHeight + 147)
        preferredContentSize = size
        view.setFrameSize(size)
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

    private func button(_ title: String, symbol: String? = nil, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeft
        }
        button.setAccessibilityLabel(title)
        return button
    }

    @objc private func showAll() { manager.showAll(); reloadPins() }
    @objc private func hideAll() { manager.hideAll(); reloadPins() }
    @objc private func closeAll() { manager.closeAll(); reloadPins() }
    @objc private func paste() { onUtilityAction?(.paste) }
    @objc private func history() { onUtilityAction?(.history) }
    @objc private func settings() { onUtilityAction?(.settings) }
    @objc private func quit() { onUtilityAction?(.quit) }
}

final class MenuBarPanelRootView: NSView {
    var onLayout: (() -> Void)?
    var onDismiss: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }
    override func layout() {
        super.layout()
        onLayout?()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class PinRowView: NSView {
    let pinID: UUID
    let previewView = NSImageView()
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let visibilityLabel = NSTextField(labelWithString: "")
    let showButton = NSButton(title: "Show", target: nil, action: nil)
    let hideButton = NSButton(title: "Hide", target: nil, action: nil)
    let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let onAction: (PinsPanelViewController.PinAction, UUID) -> Void

    init(pinID: UUID, onAction: @escaping (PinsPanelViewController.PinAction, UUID) -> Void) {
        self.pinID = pinID
        self.onAction = onAction
        super.init(frame: NSRect(x: 0, y: 0, width: 424, height: 112))
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
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.target = self
            button.action = selector
        }
        let actions = NSStackView(views: [showButton, hideButton, closeButton])
        actions.spacing = 6
        actions.distribution = .fillEqually
        for child in [previewView, titleLabel, visibilityLabel, actions] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            previewView.centerYAnchor.constraint(equalTo: centerYAnchor),
            previewView.widthAnchor.constraint(equalToConstant: 124),
            previewView.heightAnchor.constraint(equalToConstant: 88),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: previewView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            visibilityLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            visibilityLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            actions.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.65).cgColor }

    func update(from pin: PinWindowController) {
        let title = pin.contentView.previewTitle
        titleLabel.stringValue = title
        titleLabel.toolTip = title
        visibilityLabel.stringValue = pin.isPinVisible ? "Visible" : "Hidden"
        hideButton.isEnabled = pin.isPinVisible
        previewView.image = pin.contentView.menuPreview(fitting: CGSize(width: 248, height: 176))
        previewView.setAccessibilityLabel("Preview of \(title)")
        for button in [showButton, hideButton, closeButton] {
            button.setAccessibilityLabel("\(button.title) Pin: \(title)")
        }
    }

    @objc private func show() { onAction(.show, pinID) }
    @objc private func hide() { onAction(.hide, pinID) }
    @objc private func close() { onAction(.close, pinID) }
}
