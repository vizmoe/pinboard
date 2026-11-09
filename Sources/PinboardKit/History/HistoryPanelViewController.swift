import AppKit

/// History navigation stays inside the status popover. The store remains the
/// source of truth, including when a selected record disappears during an edit.
final class HistoryPanelViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// Explicit view state of the history panel so list browsing, record detail
    /// inspection, and destructive clear confirmation are mutually exclusive.
    enum ViewState: Equatable {
        case list
        case detail(HistoryRecord, isReadable: Bool)
        case confirmingClear
    }

    let model: HistoryViewModel?
    var onBack: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onUtilityAction: ((MenuBarUtilityAction) -> Void)?
    var isPageActive = true
    let searchField = NSSearchField()
    let tableView = NSTableView()
    let scrollView = NSScrollView()
    let detailScrollView = NSScrollView()
    let detailTextView: NSTextView = {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 288, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        return NSTextView(frame: NSRect(x: 0, y: 0, width: 304, height: 40), textContainer: container)
    }()
    let detailImageView = NSImageView()
    private(set) var records: [HistoryRecord] = []
    private(set) var viewState: ViewState = .list
    var isConfirmingClear: Bool { viewState == .confirmingClear }
    private let toolbar = MenuBarPanelToolbar(showingHistory: true)
    private let errorIcon = NSImageView()
    private var detailButtons: [NSButton] = []
    private var confirmationButtons: [NSButton] = []
    private var clearButton: NSButton!
    private var updating = false
    private var listOrigin = NSPoint.zero
    private var listHeight: CGFloat = 0
    private var detailHeight: CGFloat = 40

    init(model: HistoryViewModel?) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model?.onChange = { [weak self] in
            guard let self, self.isPageActive else { return }
            self.reloadHistory()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let root = MenuBarPanelRootView(frame: NSRect(x: 0, y: 0, width: 320, height: 78))
        root.onLayout = { [weak self] in self?.layoutContent() }
        root.onDismiss = { [weak self] in self?.handleCancelOperation() }
        view = root
        preferredContentSize = root.frame.size
        toolbar.onPins = { [weak self] in self?.onBack?() }
        toolbar.onHistory = { [weak self] in
            self?.model?.selection = nil
            self?.viewState = .list
            self?.reloadHistory()
            self?.focusSearch()
        }
        toolbar.onPaste = { [weak self] in self?.onUtilityAction?(.paste) }
        toolbar.onSettings = { [weak self] in self?.onUtilityAction?(.settings) }
        toolbar.onQuit = { [weak self] in self?.onUtilityAction?(.quit) }
        clearButton = button("Clear History", symbol: "trash", action: #selector(requestClear))
        searchField.placeholderString = ""
        searchField.toolTip = "Search history"
        searchField.setAccessibilityLabel("Search history")
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 48
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("Saved history")
        for scroll in [scrollView, detailScrollView] {
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.borderType = .noBorder
        }
        scrollView.documentView = tableView
        detailTextView.isEditable = false
        detailTextView.isSelectable = true
        detailTextView.drawsBackground = false
        detailTextView.isVerticallyResizable = true
        detailTextView.isHorizontallyResizable = false
        detailTextView.minSize = .zero
        detailTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        detailTextView.autoresizingMask = [.width]
        detailTextView.textContainerInset = NSSize(width: 8, height: 8)
        detailTextView.textContainer?.widthTracksTextView = true
        detailImageView.imageScaling = .scaleProportionallyUpOrDown
        detailImageView.setAccessibilityLabel("Saved image preview")
        errorIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        errorIcon.contentTintColor = .secondaryLabelColor
        errorIcon.toolTip = "Preview unavailable: this record's content could not be read."
        errorIcon.setAccessibilityLabel(errorIcon.toolTip)
        for (title, symbol, action) in [("Back", "chevron.left", #selector(back)), ("Pin Again", "pin", #selector(pinAgain)),
                                        ("Copy", "doc.on.doc", #selector(copyRecord)), ("Delete", "trash", #selector(deleteRecord))] {
            detailButtons.append(button(title, symbol: symbol, action: action))
        }
        detailButtons.first?.toolTip = "Back to History"
        detailButtons.first?.setAccessibilityLabel("Back to History")
        let cancel = button("Cancel", symbol: "xmark", action: #selector(cancelClear))
        let confirm = button("Confirm Clear", symbol: "trash.fill", action: #selector(confirmClear))
        let explanation = "Confirm Clear: permanently delete saved history except records for open pins."
        confirm.toolTip = explanation
        confirm.setAccessibilityLabel(explanation)
        confirmationButtons = [cancel, confirm]
        [toolbar, searchField, scrollView, detailScrollView, errorIcon].forEach { root.addSubview($0) }
        root.onAppearanceChange = { [weak self] in self?.reloadHistory() }
        root.onKeyEquivalent = { [weak self] event in
            self?.handleKeyEquivalent(event) ?? false
        }
    }

    private func layoutContent() {
        let width = view.bounds.width
        toolbar.frame = NSRect(x: 10, y: 10, width: width - 20, height: 26)
        searchField.frame = NSRect(x: 10, y: 46, width: width - 20, height: 24)
        scrollView.frame = NSRect(x: 8, y: 78, width: width - 16, height: listHeight)
        tableView.tableColumns.first?.width = scrollView.contentSize.width
        detailScrollView.frame = NSRect(x: 8, y: 46, width: width - 16, height: detailHeight)
        if detailScrollView.documentView === detailTextView, let container = detailTextView.textContainer {
            let contentSize = detailScrollView.contentSize
            let wrapWidth = max(contentSize.width - detailTextView.textContainerInset.width * 2, 1)
            container.containerSize = NSSize(width: wrapWidth, height: .greatestFiniteMagnitude)
            detailTextView.minSize = NSSize(width: 0, height: contentSize.height)
            detailTextView.setFrameSize(NSSize(width: contentSize.width, height: detailTextView.frame.height))
            detailTextView.layoutManager?.ensureLayout(for: container)
            detailTextView.sizeToFit()
        }
        detailImageView.frame = NSRect(origin: .zero, size: detailScrollView.contentSize)
        errorIcon.frame = NSRect(x: (width - 18) / 2, y: 50, width: 18, height: 18)
    }

    override func viewWillAppear() { super.viewWillAppear(); reloadHistory() }

    func focusSearch() {
        view.window?.makeFirstResponder(viewState == .list ? searchField : view)
    }

    func reloadHistory() {
        guard !updating else { return }
        _ = view
        updating = true
        defer { updating = false }
        if !scrollView.isHidden { listOrigin = scrollView.contentView.bounds.origin }
        if let id = model?.selection, model?.store.record(id: id) == nil { model?.selection = nil }
        records = model?.filtered ?? []
        if searchField.stringValue != (model?.searchText ?? "") { searchField.stringValue = model?.searchText ?? "" }
        tableView.reloadData()
        tableView.deselectAll(nil)

        if viewState == .confirmingClear {
            detailScrollView.isHidden = true
            errorIcon.isHidden = true
        } else if let detail = model?.record(for: model?.selection) {
            detailScrollView.isHidden = false
            errorIcon.isHidden = true
            view.effectiveAppearance.performAsCurrentDrawingAppearance { showDetail(detail) }
            viewState = .detail(detail, isReadable: errorIcon.isHidden)
        } else {
            viewState = .list
            detailScrollView.isHidden = true
            errorIcon.isHidden = true
        }

        let showingList = viewState == .list
        view.setAccessibilityLabel(isConfirmingClear ? "Confirm clearing history" : "History: \(records.count) saved items")
        switch viewState {
        case .confirmingClear:
            toolbar.setActions(confirmationButtons)
        case .detail:
            toolbar.setActions(detailButtons)
        case .list:
            toolbar.setActions([clearButton])
        }
        searchField.isHidden = !showingList
        clearButton.isEnabled = !(model?.records.isEmpty ?? true)
        scrollView.isHidden = !showingList || records.isEmpty

        listHeight = min(CGFloat(records.count) * 52 - (records.isEmpty ? 0 : 4), 308)
        let height: CGFloat
        switch viewState {
        case .confirmingClear:
            height = 46
        case .detail(_, let isReadable):
            height = isReadable ? 54 + detailHeight : 78
        case .list:
            height = 78 + listHeight + (records.isEmpty ? 0 : 8)
        }
        let size = NSSize(width: 320, height: height)
        preferredContentSize = size
        // The popover owns attached view frames; changing one creates stale margins.
        if view.superview == nil { view.setFrameSize(size) }
        layoutContent()
        view.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(listOrigin.y,
            max(0, tableView.bounds.height - scrollView.contentSize.height))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func showDetail(_ record: HistoryRecord) {
        guard let state = model?.detail(for: record) else { showUnreadable(); return }
        switch state.content {
        case .text(let text):
            let display: NSAttributedString
            switch state.textMode {
            case .markdown:
                display = MarkdownRenderer.render(text.string)
            case .plainText:
                display = NSAttributedString(string: text.string, attributes: TextDefaults.attributes)
            case .richText:
                display = text
            }
            detailTextView.textStorage?.setAttributedString(display)
            detailTextView.setAccessibilityLabel("Saved text preview")
            detailScrollView.documentView = detailTextView
            if let container = detailTextView.textContainer, let layout = detailTextView.layoutManager {
                container.containerSize = NSSize(width: view.bounds.width - 32, height: .greatestFiniteMagnitude)
                layout.ensureLayout(for: container)
                detailHeight = min(224, max(40, ceil(layout.usedRect(for: container).height) + 16))
            }
        case .image:
            let image: NSImage?
            do {
                image = try model?.renderedImage(from: state, fitting: NSSize(width: 800, height: 600))
            } catch {
                showUnreadable()
                return
            }
            guard let image, image.size.width > 0 else {
                showUnreadable()
                return
            }
            detailImageView.image = image
            detailScrollView.documentView = detailImageView
            detailHeight = min(224, max(40, ceil((view.bounds.width - 16) * image.size.height / image.size.width)))
        }
    }

    private func showUnreadable() {
        detailScrollView.isHidden = true
        errorIcon.isHidden = false
    }

    private static func kindLabel(_ record: HistoryRecord) -> String {
        guard record.kind == .text else { return record.preview }
        switch record.textMode ?? .richText {
        case .richText: return "Rich Text"
        case .plainText: return "Plain Text"
        case .markdown: return "Markdown"
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row) else { return nil }
        let record = records[row]
        let cell = HistoryRowView()
        let text = record.kind == .text ? (record.text ?? "").replacingOccurrences(of: "\u{FFFC}", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ") : ""
        cell.titleLabel.stringValue = String(text.prefix(120))
        cell.titleLabel.isHidden = text.isEmpty
        let description = "\(record.preview), \(Self.kindLabel(record)), \(record.updatedAt.formatted(date: .abbreviated, time: .shortened))"
        cell.toolTip = description
        cell.previewView.image = record.kind == .image ? model?.store.image(id: record.id)
            : NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        cell.previewView.imageScaling = record.kind == .image ? .scaleProportionallyUpOrDown : .scaleProportionallyDown
        cell.setAccessibilityLabel(description)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, records.indices.contains(tableView.selectedRow) else { return }
        model?.selection = records[tableView.selectedRow].id
        reloadHistory()
        view.window?.makeFirstResponder(view)
    }

    func controlTextDidChange(_ notification: Notification) {
        model?.searchText = searchField.stringValue
        model?.selection = nil
        listOrigin = .zero
        reloadHistory()
    }

    private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = PanelIconButton(title, symbol: symbol, target: self, action: action)
        button.isDestructive = title == "Confirm Clear" || title == "Delete"
        return button
    }

    func handleCancelOperation() {
        switch viewState {
        case .confirmingClear:
            cancelClear()
        case .detail:
            back()
        case .list:
            onDismiss?()
        }
    }

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
            if viewState != .list {
                back()
            } else {
                focusSearch()
            }
            return true
        }
        guard model?.selection != nil else { return false }
        if flags.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
            pinAgain()
            return true
        }
        if (flags == .command && event.keyCode == 51)
            || (flags.isEmpty && (event.keyCode == 51 || event.keyCode == 117)) {
            deleteRecord()
            return true
        }
        return false
    }

    @objc private func back() { model?.selection = nil; viewState = .list; reloadHistory(); focusSearch() }
    @objc func requestClear() { viewState = .confirmingClear; reloadHistory(); view.window?.makeFirstResponder(view) }
    @objc private func cancelClear() { viewState = .list; reloadHistory(); focusSearch() }
    @objc private func confirmClear() { viewState = .list; model?.clearAll(); reloadHistory(); focusSearch() }
    @objc private func pinAgain() { if let id = model?.selection { model?.pinAgain(id) } }
    @objc private func copyRecord() { if let id = model?.selection { model?.copy(id) } }
    @objc private func deleteRecord() { if let id = model?.selection { model?.delete(id); reloadHistory(); focusSearch() } }
}

final class HistoryRowView: NSTableCellView {
    let previewView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.wantsLayer = true
        previewView.layer?.cornerRadius = 3
        previewView.layer?.masksToBounds = true
        wantsLayer = true
        layer?.cornerRadius = 6
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
        chevron.contentTintColor = .tertiaryLabelColor
        [previewView, titleLabel, chevron].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor }

    override func layout() {
        super.layout()
        chevron.frame = NSRect(x: bounds.width - 20, y: 19, width: 8, height: 10)
        previewView.frame = NSRect(x: 8, y: 6, width: titleLabel.isHidden ? bounds.width - 40 : 32, height: 36)
        titleLabel.frame = NSRect(x: 48, y: 15, width: max(0, bounds.width - 80), height: 18)
    }
}
