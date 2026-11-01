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
    private let header = MenuBarPanelHeader(title: "History", showingHistory: true)
    private let detailLabel = NSTextField(labelWithString: "")
    private let emptyIcon = NSImageView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let detailActions = NSStackView()
    private let confirmationActions = NSStackView()
    private let footer = MenuBarPanelFooter()
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
        let root = MenuBarPanelRootView(frame: NSRect(x: 0, y: 0, width: 380, height: 486))
        root.onLayout = { [weak self] in self?.layoutContent() }
        root.onDismiss = { [weak self] in self?.onDismiss?() }
        view = root
        preferredContentSize = root.frame.size
        header.onPins = { [weak self] in self?.onBack?() }
        header.onHistory = { [weak self] in
            self?.model?.selection = nil
            self?.isConfirmingClear = false
            self?.reloadHistory()
            self?.focusSearch()
        }
        header.onPaste = { [weak self] in self?.onUtilityAction?(.paste) }
        footer.onSettings = { [weak self] in self?.onUtilityAction?(.settings) }
        footer.onQuit = { [weak self] in self?.onUtilityAction?(.quit) }
        backButton = button("Back", symbol: "chevron.left", action: #selector(back))
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        emptyIcon.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 30, weight: .light))
        emptyIcon.contentTintColor = .tertiaryLabelColor
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        clearButton = button("Clear History", symbol: "trash", action: #selector(requestClear))
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
        for (title, symbol, action) in [("Pin Again", "pin", #selector(pinAgain)), ("Copy", "doc.on.doc", #selector(copyRecord)), ("Delete", "trash", #selector(deleteRecord))] {
            detailActions.addArrangedSubview(button(title, symbol: symbol, action: action))
        }
        confirmationActions.addArrangedSubview(button("Cancel", symbol: "xmark", action: #selector(cancelClear)))
        confirmationActions.addArrangedSubview(button("Confirm Clear", symbol: "trash.fill", action: #selector(confirmClear)))
        for stack in [detailActions, confirmationActions] {
            stack.spacing = 8
            stack.distribution = .fillEqually
        }
        separator.boxType = .separator
        for child in [header, backButton!, detailLabel, countLabel, clearButton!, searchField, scrollView,
                      detailScrollView, emptyIcon, message, detailActions, confirmationActions, separator, footer] {
            root.addSubview(child)
        }
    }

    private func layoutContent() {
        let width = view.bounds.width
        header.frame = NSRect(x: 16, y: 14, width: width - 32, height: 32)
        backButton.frame = NSRect(x: 12, y: 60, width: 32, height: 32)
        detailLabel.frame = NSRect(x: 52, y: 68, width: width - 68, height: 18)
        clearButton.frame = NSRect(x: width - 48, y: 94, width: 32, height: 32)
        searchField.frame = NSRect(x: 16, y: 60, width: width - 32, height: 28)
        countLabel.frame = NSRect(x: 18, y: 102, width: width - 76, height: 18)
        let content = NSRect(x: 12, y: 134, width: width - 24, height: view.bounds.height - 200)
        scrollView.frame = content
        tableView.tableColumns.first?.width = scrollView.contentSize.width
        detailScrollView.frame = NSRect(x: 12, y: 102, width: width - 24, height: view.bounds.height - 218)
        detailTextView.setFrameSize(NSSize(width: detailScrollView.contentSize.width, height: detailScrollView.contentSize.height))
        detailTextView.textContainer?.containerSize = NSSize(width: detailScrollView.contentSize.width - 24,
                                                           height: .greatestFiniteMagnitude)
        detailTextView.sizeToFit()
        detailImageView.frame = NSRect(origin: .zero, size: detailScrollView.contentSize)
        emptyIcon.frame = NSRect(x: (width - 36) / 2, y: 192, width: 36, height: 36)
        message.frame = NSRect(x: 32, y: 244, width: width - 64, height: 96)
        detailActions.frame = NSRect(x: width - 128, y: view.bounds.height - 100, width: 112, height: 32)
        confirmationActions.frame = NSRect(x: (width - 80) / 2, y: 350, width: 80, height: 32)
        separator.frame = NSRect(x: 16, y: view.bounds.height - 54, width: width - 32, height: 1)
        footer.frame = NSRect(x: 16, y: view.bounds.height - 42, width: width - 32, height: 32)
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
        if searchField.stringValue != (model?.searchText ?? "") { searchField.stringValue = model?.searchText ?? "" }
        tableView.reloadData()
        tableView.deselectAll(nil)
        let detail = model?.record(for: model?.selection)
        let showingList = detail == nil && !isConfirmingClear
        header.pinsButton.state = .off
        header.historyButton.state = .on
        backButton.isHidden = showingList
        backButton.setAccessibilityLabel("Back to History")
        backButton.toolTip = "Back to History"
        detailLabel.isHidden = showingList
        detailLabel.stringValue = detail.map {
            "\(Self.kindLabel($0)) · \($0.updatedAt.formatted(date: .abbreviated, time: .shortened))"
        } ?? "Clear History"
        countLabel.stringValue = "\(records.count) saved item\(records.count == 1 ? "" : "s")"
        searchField.isHidden = !showingList
        countLabel.isHidden = !showingList
        clearButton.isHidden = !showingList
        clearButton.isEnabled = !(model?.records.isEmpty ?? true)
        scrollView.isHidden = !showingList || records.isEmpty
        detailScrollView.isHidden = detail == nil || isConfirmingClear
        detailActions.isHidden = detail == nil || isConfirmingClear
        confirmationActions.isHidden = !isConfirmingClear
        message.isHidden = true
        emptyIcon.isHidden = true
        if isConfirmingClear {
            setMessage("Clear saved history?", hint: "Records for open pins will be kept. Other records and their files will be permanently deleted.", symbol: "trash")
            message.isHidden = false
            emptyIcon.isHidden = false
        } else if let detail {
            showDetail(detail)
        } else if records.isEmpty {
            if model?.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                setMessage("No Results", hint: "Try another search.", symbol: "magnifyingglass")
            } else {
                setMessage("No History", hint: "Items you pin will appear here.", symbol: "clock.arrow.circlepath")
            }
            message.isHidden = false
            emptyIcon.isHidden = false
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
        setMessage("Preview Unavailable", hint: "This record's content could not be read.", symbol: "exclamationmark.triangle")
        message.isHidden = false
        emptyIcon.isHidden = false
    }

    private func setMessage(_ title: String, hint: String, symbol: String) {
        let text = NSMutableAttributedString(string: title + "\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.labelColor
        ])
        text.append(NSAttributedString(string: hint, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor
        ]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 2
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        message.attributedStringValue = text
        emptyIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 30, weight: .light))
    }

    private static func kindLabel(_ record: HistoryRecord) -> String {
        guard record.kind == .text else { return record.preview }
        switch record.textMode ?? .richText {
        case .richText: return "Rich Text"
        case .plainText: return "Plain Text"
        case .markdown: return "Markdown"
        }
    }

    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row) else { return nil }
        let record = records[row]
        let cell = HistoryRowView()
        cell.titleLabel.stringValue = record.preview
        cell.titleLabel.toolTip = record.preview
        let now = Date()
        let date = now.timeIntervalSince(record.updatedAt) < 60 ? "Just now"
            : Self.relativeDate.localizedString(for: record.updatedAt, relativeTo: now)
        cell.subtitleLabel.stringValue = "\(Self.kindLabel(record)) · \(date)"
        cell.subtitleLabel.toolTip = record.updatedAt.formatted(date: .abbreviated, time: .shortened)
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

    private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = PanelIconButton(title, symbol: symbol, target: self, action: action)
        button.isDestructive = title == "Confirm Clear" || title == "Delete"
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
}

final class HistoryRowView: NSTableCellView {
    let previewView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        previewView.imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = 8
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .tertiaryLabelColor
        [previewView, titleLabel, subtitleLabel, chevron].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor }

    override func layout() {
        super.layout()
        chevron.frame = NSRect(x: bounds.width - 24, y: 23, width: 12, height: 14)
        previewView.frame = NSRect(x: 8, y: 10, width: 40, height: 40)
        titleLabel.frame = NSRect(x: 60, y: 32, width: max(0, bounds.width - 94), height: 18)
        subtitleLabel.frame = NSRect(x: 60, y: 12, width: max(0, bounds.width - 94), height: 16)
    }
}
