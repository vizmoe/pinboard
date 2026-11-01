import AppKit

/// History navigation stays inside the status popover. The store remains the
/// source of truth, including when a selected record disappears during an edit.
final class HistoryPanelViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let model: HistoryViewModel?
    var onBack: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onUtilityAction: ((PinsPanelViewController.UtilityAction) -> Void)?
    let searchField = NSSearchField()
    let tableView = NSTableView()
    let scrollView = NSScrollView()
    let detailScrollView = NSScrollView()
    let detailTextView = NSTextView()
    let detailImageView = NSImageView()
    let countLabel = NSTextField(labelWithString: "")
    private(set) var records: [HistoryRecord] = []
    private(set) var isConfirmingClear = false
    private let titleLabel = NSTextField(labelWithString: "History")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let detailActions = NSStackView()
    private let confirmationActions = NSStackView()
    private let footer = NSStackView()
    private let separator = NSBox()
    private var backButton: NSButton!
    private var clearButton: NSButton!
    private var updating = false
    private var listOrigin = NSPoint.zero

    init(model: HistoryViewModel?) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model?.onChange = { [weak self] in self?.reloadHistory() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let root = MenuBarPanelRootView(frame: NSRect(x: 0, y: 0, width: 448, height: 450))
        root.onLayout = { [weak self] in self?.layoutContent() }
        root.onDismiss = { [weak self] in self?.onDismiss?() }
        view = root
        preferredContentSize = root.frame.size
        backButton = button("Pins", action: #selector(back))
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        clearButton = button("Clear History", action: #selector(requestClear))
        searchField.placeholderString = "Search history"
        searchField.setAccessibilityLabel("Search history")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 60
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
        detailTextView.textContainerInset = NSSize(width: 12, height: 12)
        detailTextView.textContainer?.widthTracksTextView = true
        detailImageView.imageScaling = .scaleProportionallyUpOrDown
        detailImageView.setAccessibilityLabel("Saved image preview")
        message.alignment = .center
        message.font = .systemFont(ofSize: 13)
        message.textColor = .secondaryLabelColor
        for (title, action) in [("Pin Again", #selector(pinAgain)), ("Copy", #selector(copyRecord)), ("Delete", #selector(deleteRecord))] {
            detailActions.addArrangedSubview(button(title, action: action))
        }
        confirmationActions.addArrangedSubview(button("Cancel", action: #selector(cancelClear)))
        confirmationActions.addArrangedSubview(button("Confirm Clear", action: #selector(confirmClear)))
        for (title, action) in [("Pin Clipboard", #selector(paste)), ("Settings", #selector(settings)), ("Quit", #selector(quit))] {
            footer.addArrangedSubview(button(title, action: action))
        }
        for stack in [detailActions, confirmationActions, footer] {
            stack.spacing = 8
            stack.distribution = .fillEqually
        }
        separator.boxType = .separator
        for child in [backButton!, titleLabel, countLabel, clearButton!, searchField, scrollView,
                      detailScrollView, message, detailActions, confirmationActions, separator, footer] {
            root.addSubview(child)
        }
    }

    private func layoutContent() {
        let width = view.bounds.width
        backButton.frame = NSRect(x: 12, y: 14, width: 60, height: 28)
        titleLabel.frame = NSRect(x: 82, y: 17, width: 150, height: 24)
        clearButton.frame = NSRect(x: width - 124, y: 14, width: 108, height: 28)
        searchField.frame = NSRect(x: 16, y: 54, width: width - 32, height: 28)
        countLabel.frame = NSRect(x: 18, y: 92, width: width - 36, height: 18)
        let content = NSRect(x: 12, y: 118, width: width - 24, height: view.bounds.height - 184)
        scrollView.frame = content
        tableView.tableColumns.first?.width = scrollView.contentSize.width
        detailScrollView.frame = NSRect(x: 12, y: 54, width: width - 24, height: view.bounds.height - 164)
        detailTextView.setFrameSize(NSSize(width: detailScrollView.contentSize.width, height: detailScrollView.contentSize.height))
        detailTextView.textContainer?.containerSize = NSSize(width: detailScrollView.contentSize.width - 24,
                                                           height: .greatestFiniteMagnitude)
        detailTextView.sizeToFit()
        detailImageView.frame = NSRect(origin: .zero, size: detailScrollView.contentSize)
        message.frame = NSRect(x: 32, y: 180, width: width - 64, height: 80)
        detailActions.frame = NSRect(x: 16, y: view.bounds.height - 98, width: width - 32, height: 28)
        confirmationActions.frame = NSRect(x: 48, y: 280, width: width - 96, height: 28)
        separator.frame = NSRect(x: 16, y: view.bounds.height - 54, width: width - 32, height: 1)
        footer.frame = NSRect(x: 16, y: view.bounds.height - 42, width: width - 32, height: 28)
    }

    override func viewWillAppear() { super.viewWillAppear(); reloadHistory() }

    func focusSearch() {
        view.window?.makeFirstResponder(model?.selection == nil ? searchField : view)
    }

    func reloadHistory() {
        guard !updating else { return }
        _ = view
        updating = true
        defer { updating = false }
        if !scrollView.isHidden { listOrigin = scrollView.contentView.bounds.origin }
        if let id = model?.selection, model?.store.record(id: id) == nil { model?.selection = nil }
        records = model?.filtered ?? []
        searchField.stringValue = model?.searchText ?? ""
        tableView.reloadData()
        tableView.deselectAll(nil)
        let detail = model?.record(for: model?.selection)
        let showingList = detail == nil && !isConfirmingClear
        backButton.title = showingList ? "Pins" : "Back"
        backButton.setAccessibilityLabel(showingList ? "Back to Pins" : "Back to History")
        countLabel.stringValue = "\(records.count) saved item\(records.count == 1 ? "" : "s")"
        titleLabel.stringValue = isConfirmingClear ? "Clear History" : "History"
        searchField.isHidden = !showingList
        countLabel.isHidden = !showingList
        clearButton.isHidden = !showingList
        clearButton.isEnabled = !(model?.records.isEmpty ?? true)
        scrollView.isHidden = !showingList || records.isEmpty
        detailScrollView.isHidden = detail == nil || isConfirmingClear
        detailActions.isHidden = detail == nil || isConfirmingClear
        confirmationActions.isHidden = !isConfirmingClear
        message.isHidden = true
        if isConfirmingClear {
            message.stringValue = "Clear saved history?\n\nRecords for open pins will be kept. Other records and their files will be permanently deleted."
            message.isHidden = false
        } else if let detail {
            showDetail(detail)
        } else if records.isEmpty {
            message.stringValue = model?.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? "No matching history.\nTry another search."
                : "No History\nItems you pin will appear here."
            message.isHidden = false
        }
        layoutContent()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(listOrigin.y,
            max(0, tableView.bounds.height - scrollView.contentSize.height))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func showDetail(_ record: HistoryRecord) {
        guard let state = model?.detail(for: record) else { showUnreadable(); return }
        switch state.content {
        case .text(let text):
            let display = state.textMode == .markdown ? MarkdownRenderer.render(text.string) : text
            detailTextView.textStorage?.setAttributedString(display)
            detailTextView.setAccessibilityLabel("Saved text preview")
            detailScrollView.documentView = detailTextView
        case .image(let image):
            let preview = ImagePinView(image: image)
            if let data = state.annotationData {
                do { try preview.restoreAnnotations(data) }
                catch { showUnreadable(); return }
            }
            detailImageView.image = preview.menuPreview(fitting: NSSize(width: 800, height: 600))
            detailScrollView.documentView = detailImageView
        }
    }

    private func showUnreadable() {
        detailScrollView.isHidden = true
        message.stringValue = "This record's content could not be read."
        message.isHidden = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row) else { return nil }
        let record = records[row]
        let cell = HistoryRowView()
        cell.titleLabel.stringValue = record.preview
        cell.titleLabel.toolTip = record.preview
        let kind = record.kind == .image ? record.preview : (record.textMode ?? .richText).title
        cell.subtitleLabel.stringValue = "\(kind) · \(record.updatedAt.formatted(date: .abbreviated, time: .shortened))"
        cell.previewView.image = record.kind == .image ? model?.store.image(id: record.id)
            : NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        cell.setAccessibilityLabel("\(record.preview), \(cell.subtitleLabel.stringValue)")
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

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setAccessibilityLabel(title)
        return button
    }

    @objc private func back() {
        if isConfirmingClear { cancelClear() }
        else if model?.selection != nil { model?.selection = nil; reloadHistory(); focusSearch() }
        else { onBack?() }
    }
    @objc private func requestClear() { isConfirmingClear = true; reloadHistory(); view.window?.makeFirstResponder(view) }
    @objc private func cancelClear() { isConfirmingClear = false; reloadHistory(); focusSearch() }
    @objc private func confirmClear() { isConfirmingClear = false; model?.clearAll(); reloadHistory(); focusSearch() }
    @objc private func pinAgain() { if let id = model?.selection { model?.pinAgain(id) } }
    @objc private func copyRecord() { if let id = model?.selection { model?.copy(id) } }
    @objc private func deleteRecord() { if let id = model?.selection { model?.delete(id); reloadHistory(); focusSearch() } }
    @objc private func paste() { onUtilityAction?(.paste) }
    @objc private func settings() { onUtilityAction?(.settings) }
    @objc private func quit() { onUtilityAction?(.quit) }
}

final class HistoryRowView: NSTableCellView {
    let previewView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        previewView.imageScaling = .scaleProportionallyUpOrDown
        [previewView, titleLabel, subtitleLabel].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        previewView.frame = NSRect(x: 8, y: 10, width: 40, height: 40)
        titleLabel.frame = NSRect(x: 60, y: 32, width: max(0, bounds.width - 72), height: 18)
        subtitleLabel.frame = NSRect(x: 60, y: 12, width: max(0, bounds.width - 72), height: 16)
    }
}
