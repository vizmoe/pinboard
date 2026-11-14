import AppKit

/// History navigation stays inside the floating status panel. The store remains the
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
    let searchField: NSSearchField = MenuBarSearchField()
    let tableView = NSTableView()
    let scrollView = NSScrollView()
    let detailScrollView = NSScrollView()
    let detailTextView: NSTextView = {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 280, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        return NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40), textContainer: container)
    }()
    let detailImageView = NSImageView()
    private(set) var records: [HistoryRecord] = []
    private(set) var viewState: ViewState = .list
    var isConfirmingClear: Bool { viewState == .confirmingClear }
    let toolbar = MenuBarPanelToolbar(showingHistory: true)
    let footer = MenuBarPanelFooter()
    let emptyStateView = PanelEmptyStateView()

    private let detailCard = DetailCardContainerView()
    private let detailAmbientWell = AmbientImageWellView()
    private let detailImageContainer = FlippedDetailContainerView()
    private let errorIcon = NSImageView()
    private var backButton: PanelIconButton!
    private var detailButtons: [NSButton] = []
    private var confirmationButtons: [NSButton] = []
    private var clearButton: PanelIconButton!
    private var scrollBoundsObserver: NSObjectProtocol?
    private var updating = false
    private var listOrigin = NSPoint.zero
    private var listHeight: CGFloat = 0
    private var detailHeight: CGFloat = 40
    private static let width: CGFloat = 320
    private static let listTop: CGFloat = 90
    private static let noResultsHeight: CGFloat = 104

    init(model: HistoryViewModel?) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model?.onChange = { [weak self] in
            guard let self, self.isPageActive else { return }
            self.reloadHistory()
        }
    }

    deinit {
        if let scrollBoundsObserver {
            NotificationCenter.default.removeObserver(scrollBoundsObserver)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let root = MenuBarPanelRootView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 84))
        root.wantsLayer = true
        root.onLayout = { [weak self] in self?.layoutContent() }
        root.onDismiss = { [weak self] in self?.handleCancelOperation() }
        root.onPointerExit = { [weak self] in self?.clearHoverState() }
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
        clearButton.highlightsDestructiveOnHover = true

        searchField.placeholderString = "Search History"
        searchField.toolTip = "Search history"
        searchField.setAccessibilityLabel("Search history")
        searchField.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 48
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
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
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.syncHoveredRowWithPointer()
        }

        detailTextView.isEditable = false
        detailTextView.isSelectable = true
        detailTextView.drawsBackground = false
        detailTextView.isVerticallyResizable = true
        detailTextView.isHorizontallyResizable = false
        detailTextView.minSize = .zero
        detailTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        detailTextView.autoresizingMask = [.width]
        detailTextView.textContainerInset = NSSize(width: 10, height: 8)
        detailTextView.textContainer?.widthTracksTextView = true

        detailAmbientWell.cornerRadius = 10.5
        detailAmbientWell.isHidden = true

        detailImageView.imageScaling = .scaleProportionallyUpOrDown
        detailImageView.wantsLayer = true
        detailImageView.layer?.cornerRadius = 6.5
        detailImageView.layer?.cornerCurve = .continuous
        detailImageView.layer?.masksToBounds = true
        detailImageView.setAccessibilityLabel("Saved image preview")
        detailImageContainer.addSubview(detailImageView)

        detailCard.addSubview(detailAmbientWell)
        detailCard.addSubview(detailScrollView)
        detailCard.addSubview(errorIcon)

        errorIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        errorIcon.contentTintColor = .secondaryLabelColor
        errorIcon.toolTip = "Preview unavailable: this record's content could not be read."
        errorIcon.setAccessibilityLabel(errorIcon.toolTip)

        backButton = button("Back", symbol: "chevron.left", action: #selector(back))
        backButton.toolTip = "Back to History"
        backButton.setAccessibilityLabel("Back to History")

        for (title, symbol, action) in [
            ("Pin Again", "pin", #selector(pinAgain)),
            ("Copy", "doc.on.doc", #selector(copyRecord)),
            ("Delete", "trash", #selector(deleteRecord))
        ] {
            detailButtons.append(button(title, symbol: symbol, action: action))
        }

        let cancel = button("Cancel", symbol: "xmark", action: #selector(cancelClear))
        let confirm = button("Confirm Clear", symbol: "trash.fill", action: #selector(confirmClear))
        let explanation = "Confirm Clear: permanently delete saved history except records for open pins."
        confirm.toolTip = explanation
        confirm.setAccessibilityLabel(explanation)
        confirmationButtons = [cancel, confirm]

        [toolbar, searchField, scrollView, emptyStateView, detailCard, footer].forEach { root.addSubview($0) }
        root.onAppearanceChange = { [weak self] in self?.reloadHistory() }
        root.onKeyEquivalent = { [weak self] event in
            self?.handleKeyEquivalent(event) ?? false
        }
    }

    private func layoutContent() {
        let width = view.bounds.width
        let height = view.bounds.height
        toolbar.frame = NSRect(x: 10, y: 10, width: width - 20, height: PinsPanelViewController.headerHeight)
        searchField.frame = NSRect(x: 10, y: 56, width: width - 20, height: 28)
        scrollView.frame = NSRect(x: 6, y: Self.listTop, width: width - 12, height: listHeight)
        tableView.tableColumns.first?.width = scrollView.contentSize.width
        emptyStateView.frame = searchField.isHidden
            ? NSRect(x: 0, y: 48, width: width, height: PanelEmptyStateView.preferredHeight)
            : NSRect(x: 0, y: 86, width: width, height: Self.noResultsHeight)

        let cardHeight = errorIcon.isHidden ? detailHeight : 44
        detailCard.frame = NSRect(x: 10, y: 56, width: width - 20, height: cardHeight)
        detailAmbientWell.frame = detailCard.bounds
        detailScrollView.frame = detailCard.bounds
        errorIcon.frame = NSRect(
            x: ((detailCard.bounds.width - 20) / 2).rounded(),
            y: ((detailCard.bounds.height - 20) / 2).rounded(),
            width: 20,
            height: 20
        )

        footer.frame = NSRect(
            x: 0,
            y: height - MenuBarPanelFooter.barHeight,
            width: width,
            height: MenuBarPanelFooter.barHeight
        )

        if detailScrollView.documentView === detailTextView, let container = detailTextView.textContainer {
            let contentSize = detailScrollView.contentSize
            let wrapWidth = max(contentSize.width - detailTextView.textContainerInset.width * 2, 1)
            container.containerSize = NSSize(width: wrapWidth, height: .greatestFiniteMagnitude)
            detailTextView.minSize = NSSize(width: 0, height: contentSize.height)
            detailTextView.setFrameSize(NSSize(width: contentSize.width, height: detailTextView.frame.height))
            detailTextView.layoutManager?.ensureLayout(for: container)
            detailTextView.sizeToFit()
        }
        detailImageContainer.frame = detailScrollView.bounds
        detailImageView.frame = detailImageContainer.bounds.insetBy(dx: 6, dy: 6)
    }

    override func viewWillAppear() { super.viewWillAppear(); reloadHistory() }

    func clearHoverState() {
        for row in 0..<tableView.numberOfRows {
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? HistoryRowView {
                cell.isHovered = false
            }
        }
        toolbar.clearHoverStates()
        footer.clearHoverStates()
    }

    private func clearHoverExcept(_ activeCell: HistoryRowView) {
        for row in 0..<tableView.numberOfRows {
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? HistoryRowView,
               cell !== activeCell {
                cell.isHovered = false
            }
        }
    }

    private func syncHoveredRowWithPointer() {
        guard let window = view.window, window.isVisible else { return }
        let pointInWindow = window.mouseLocationOutsideOfEventStream
        let pointInScroll = scrollView.convert(pointInWindow, from: nil)
        let insideScroll = !scrollView.isHidden && scrollView.bounds.contains(pointInScroll)
        for row in 0..<tableView.numberOfRows {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? HistoryRowView else {
                continue
            }
            if insideScroll {
                let pointInCell = cell.convert(pointInWindow, from: nil)
                cell.isHovered = cell.bounds.contains(pointInCell)
            } else {
                cell.isHovered = false
            }
        }
    }

    func focusSearch() {
        view.window?.makeFirstResponder(viewState == .list && !searchField.isHidden ? searchField : view)
    }

    func reloadHistory() {
        guard !updating else { return }
        _ = view
        updating = true
        defer { updating = false }
        if !scrollView.isHidden { listOrigin = scrollView.contentView.bounds.origin }
        if let id = model?.selection, model?.store.record(id: id) == nil { model?.selection = nil }
        records = model?.filtered ?? []
        if searchField.stringValue != (model?.searchText ?? "") {
            searchField.stringValue = model?.searchText ?? ""
        }
        tableView.reloadData()
        tableView.deselectAll(nil)

        let detail = isConfirmingClear ? nil : model?.record(for: model?.selection)
        let showingDetail = detail != nil
        let showingList = !showingDetail
        let hasAnyRecords = !(model?.records.isEmpty ?? true)

        detailCard.isHidden = !showingDetail
        detailScrollView.isHidden = !showingDetail
        detailAmbientWell.isHidden = true
        errorIcon.isHidden = true

        if isConfirmingClear {
            viewState = .confirmingClear
        } else if let detail {
            view.effectiveAppearance.performAsCurrentDrawingAppearance { showDetail(detail) }
            viewState = .detail(detail, isReadable: errorIcon.isHidden)
        } else {
            viewState = .list
        }

        view.setAccessibilityLabel(
            isConfirmingClear ? "Confirm clearing history" : "History: \(records.count) saved items"
        )

        toolbar.showsBottomSeparator = true
        toolbar.pinCount = model?.manager.count ?? 0
        toolbar.refreshShortcutHint()
        clearButton.isEnabled = hasAnyRecords

        let showsFooter: Bool
        switch viewState {
        case .confirmingClear:
            showsFooter = true
            footer.isDangerConfirmation = true
            footer.setStatus("Clear all history?")
            footer.setActions(confirmationButtons)
        case .detail:
            showsFooter = true
            footer.isDangerConfirmation = false
            footer.leadingView = backButton
            footer.setActions(detailButtons)
        case .list:
            footer.isDangerConfirmation = false
            if hasAnyRecords && !records.isEmpty {
                showsFooter = true
                footer.setStatus("\(records.count) \(records.count == 1 ? "item" : "items")")
                footer.setActions([clearButton])
            } else {
                showsFooter = false
                footer.setStatus(nil)
                footer.leadingView = nil
                footer.setActions([])
            }
        }
        footer.isHidden = !showsFooter

        searchField.isHidden = !showingList || !hasAnyRecords
        searchField.isEnabled = !isConfirmingClear
        searchField.alphaValue = isConfirmingClear ? 0.42 : 1.0

        scrollView.isHidden = !showingList || records.isEmpty
        scrollView.alphaValue = isConfirmingClear ? 0.40 : 1.0
        tableView.isEnabled = !isConfirmingClear

        let showsEmptyState = showingList && records.isEmpty
        emptyStateView.isHidden = !showsEmptyState
        if showsEmptyState {
            if hasAnyRecords {
                emptyStateView.configure(symbol: "magnifyingglass", title: "No Results",
                                         message: "Nothing in history matches “\(model?.searchText ?? "")”.")
            } else {
                emptyStateView.configure(symbol: "clock.arrow.circlepath", title: "No History",
                                         message: "Every pin you create is saved here, with its latest edits.")
            }
        }

        let rowPitch: CGFloat = 50
        listHeight = min(CGFloat(records.count) * rowPitch - (records.isEmpty ? 0 : 2), 298)

        let footerReserve: CGFloat = showsFooter ? (6 + MenuBarPanelFooter.barHeight) : 8
        let height: CGFloat
        switch viewState {
        case .detail(_, let isReadable):
            let cardHeight = isReadable ? detailHeight : 44
            height = 56 + cardHeight + 8 + MenuBarPanelFooter.barHeight
        case .list, .confirmingClear:
            if !hasAnyRecords {
                height = 48 + PanelEmptyStateView.preferredHeight
            } else if records.isEmpty {
                height = 86 + Self.noResultsHeight + (showsFooter ? MenuBarPanelFooter.barHeight : 0)
            } else {
                height = Self.listTop + listHeight + footerReserve
            }
        }

        let size = NSSize(width: Self.width, height: height)
        preferredContentSize = size
        if view.superview == nil { view.setFrameSize(size) }
        layoutContent()
        view.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(
            x: 0,
            y: min(listOrigin.y, max(0, tableView.bounds.height - scrollView.contentSize.height))
        ))
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
            detailAmbientWell.isHidden = true
            detailTextView.textStorage?.setAttributedString(display)
            detailTextView.setAccessibilityLabel("Saved text preview")
            detailScrollView.documentView = detailTextView
            if let container = detailTextView.textContainer, let layout = detailTextView.layoutManager {
                let cardWidth = view.bounds.width - 20
                let wrapWidth = max(1, cardWidth - detailTextView.textContainerInset.width * 2)
                container.containerSize = NSSize(width: wrapWidth, height: .greatestFiniteMagnitude)
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
            detailAmbientWell.setAmbientSource(image)
            detailAmbientWell.isHidden = false
            detailImageView.image = image
            detailScrollView.documentView = detailImageContainer
            let cardWidth = view.bounds.width - 20
            detailHeight = min(224, max(56, ceil((cardWidth - 12) * image.size.height / image.size.width) + 12))
        }
    }

    private func showUnreadable() {
        detailAmbientWell.isHidden = true
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

    private static func textModeSymbol(_ record: HistoryRecord) -> String {
        switch record.textMode ?? .richText {
        case .markdown: return "number"
        case .richText: return "textformat"
        case .plainText: return "text.alignleft"
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        HistoryTableRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row) else { return nil }
        let record = records[row]
        let cell = HistoryRowView()
        let text = record.kind == .text
            ? (record.text ?? "")
                .replacingOccurrences(of: "\u{FFFC}", with: "")
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            : ""
        let description = "\(record.preview), \(Self.kindLabel(record)), \(record.updatedAt.formatted(date: .abbreviated, time: .shortened))"
        let image = record.kind == .image ? model?.store.image(id: record.id) : nil
        let symbol = record.kind == .image ? "exclamationmark.triangle" : Self.textModeSymbol(record)
        cell.onHoverEntered = { [weak self] entered in
            self?.clearHoverExcept(entered)
        }
        cell.configure(
            recordID: record.id,
            isImage: record.kind == .image,
            text: String(text.prefix(120)),
            image: image,
            symbol: symbol,
            accessibilityDescription: description,
            onQuickPin: { [weak self] id in self?.model?.pinAgain(id) },
            onQuickCopy: { [weak self] id in self?.model?.copy(id) }
        )
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

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if searchField.stringValue.isEmpty {
                handleCancelOperation()
            } else {
                searchField.stringValue = ""
                controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
            }
            return true
        }
        return false
    }

    private func button(_ title: String, symbol: String, action: Selector) -> PanelIconButton {
        let button = PanelIconButton(title, symbol: symbol, target: self, action: action)
        button.isDestructive = title == "Confirm Clear"
        button.highlightsDestructiveOnHover = title == "Delete"
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
            switch viewState {
            case .confirmingClear:
                cancelClear()
            case .detail:
                back()
            case .list:
                focusSearch()
            }
            return true
        }
        guard case .detail = viewState else { return false }
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
    @objc func requestClear() { clearHoverState(); viewState = .confirmingClear; reloadHistory(); view.window?.makeFirstResponder(view) }
    @objc private func cancelClear() { viewState = .list; reloadHistory(); focusSearch() }
    @objc private func confirmClear() { viewState = .list; model?.clearAll(); reloadHistory(); focusSearch() }
    @objc private func pinAgain() { if let id = model?.selection { model?.pinAgain(id) } }
    @objc private func copyRecord() { if let id = model?.selection { model?.copy(id) } }
    @objc private func deleteRecord() { if let id = model?.selection { model?.delete(id); reloadHistory(); focusSearch() } }
}

private final class FlippedDetailContainerView: NSView {
    override var isFlipped: Bool { true }
}

private final class HistoryTableRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

private final class DetailCardContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = isDarkAppearance
        layer?.backgroundColor = PanelRowStyle.tileFill(dark: dark).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = PanelRowStyle.hairline(dark: dark).cgColor
    }
}

/// One saved record: a flat row with a real image thumbnail or a text-mode tile
/// plus the first lines of text. Pin Again / Copy appear on hover.
final class HistoryRowView: NSTableCellView {
    let previewView = PanelThumbnailView()
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let quickPinButton = PanelIconButton("Quick Pin", symbol: "pin")
    let quickCopyButton = PanelIconButton("Quick Copy", symbol: "doc.on.doc")
    var onHoverEntered: ((HistoryRowView) -> Void)?

    private let iconTile = NSView()
    private let iconView = NSImageView()
    private let hoverPill = HoverActionPillView()

    private var recordID: UUID?
    private var hasValidImage = false
    private var hovered = false
    private var hoverTracking: NSTrackingArea?
    private var onQuickPin: ((UUID) -> Void)?
    private var onQuickCopy: ((UUID) -> Void)?

    private static let inset: CGFloat = 6
    private static let thumbHeight: CGFloat = 38
    private static let actionsWidth: CGFloat = 56

    var isHovered: Bool {
        get { hovered }
        set {
            guard hovered != newValue else { return }
            hovered = newValue
            if !newValue {
                quickPinButton.clearHover()
                quickCopyButton.clearHover()
            }
            hoverPill.isHidden = !hovered
            needsLayout = true
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = PanelRowStyle.cornerRadius
        layer?.cornerCurve = .continuous

        previewView.cornerRadius = 6

        iconTile.wantsLayer = true
        iconTile.layer?.cornerRadius = 8
        iconTile.layer?.cornerCurve = .continuous
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .secondaryLabelColor
        iconTile.addSubview(iconView)

        titleLabel.font = PanelRowStyle.titleFont
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.cell?.truncatesLastVisibleLine = true

        quickPinButton.toolTip = "Pin Again"
        quickPinButton.setAccessibilityLabel("Pin Again")
        quickPinButton.target = self
        quickPinButton.action = #selector(quickPin)

        quickCopyButton.toolTip = "Copy"
        quickCopyButton.setAccessibilityLabel("Copy")
        quickCopyButton.target = self
        quickCopyButton.action = #selector(quickCopy)

        hoverPill.addSubview(quickPinButton)
        hoverPill.addSubview(quickCopyButton)
        hoverPill.isHidden = true

        [previewView, iconTile, titleLabel, hoverPill].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

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
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func updateLayer() {
        let dark = isDarkAppearance
        layer?.backgroundColor = hovered ? PanelRowStyle.hoverFill(dark: dark).cgColor : NSColor.clear.cgColor
        iconTile.layer?.backgroundColor = PanelRowStyle.tileFill(dark: dark).cgColor
    }

    func configure(
        recordID: UUID,
        isImage: Bool,
        text: String,
        image: NSImage?,
        symbol: String,
        accessibilityDescription: String,
        onQuickPin: @escaping (UUID) -> Void,
        onQuickCopy: @escaping (UUID) -> Void
    ) {
        self.recordID = recordID
        self.hasValidImage = isImage && image != nil
        self.onQuickPin = onQuickPin
        self.onQuickCopy = onQuickCopy

        titleLabel.stringValue = text
        titleLabel.isHidden = isImage || text.isEmpty
        toolTip = accessibilityDescription
        setAccessibilityLabel(accessibilityDescription)

        previewView.isHidden = !hasValidImage
        previewView.image = hasValidImage ? image : nil
        iconTile.isHidden = hasValidImage
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))

        quickPinButton.setAccessibilityLabel("Pin Again: \(accessibilityDescription)")
        quickCopyButton.setAccessibilityLabel("Copy: \(accessibilityDescription)")
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let inset = Self.inset
        let thumbHeight = Self.thumbHeight
        let thumbY = ((bounds.height - thumbHeight) / 2).rounded()

        hoverPill.frame = NSRect(
            x: bounds.width - Self.actionsWidth - inset,
            y: ((bounds.height - 26) / 2).rounded(),
            width: Self.actionsWidth,
            height: 26
        )
        quickPinButton.frame = NSRect(x: 0, y: 0, width: 26, height: 26)
        quickCopyButton.frame = NSRect(x: 30, y: 0, width: 26, height: 26)

        if hasValidImage {
            let maxWidth = bounds.width - inset * 2 - Self.actionsWidth - 8
            let width = PanelThumbnailView.fittedWidth(for: previewView.image, height: thumbHeight, maxWidth: maxWidth)
            previewView.frame = NSRect(x: inset + 2, y: thumbY, width: width, height: thumbHeight)
        } else {
            let tile = NSRect(x: inset + 2, y: ((bounds.height - 32) / 2).rounded(), width: 32, height: 32)
            iconTile.frame = tile
            iconView.frame = iconTile.bounds.insetBy(dx: 8, dy: 8)

            let labelX = tile.maxX + 10
            let trailing: CGFloat = hovered ? Self.actionsWidth + inset + 6 : 10
            let labelWidth = max(0, bounds.width - labelX - trailing)
            let measured = titleLabel.cell?.cellSize(
                forBounds: NSRect(x: 0, y: 0, width: labelWidth, height: 36)
            ).height ?? 16
            let height = min(36, ceil(measured))
            titleLabel.frame = NSRect(
                x: labelX, y: ((bounds.height - height) / 2).rounded(), width: labelWidth, height: height
            )
        }
    }

    @objc private func quickPin() {
        if let recordID { onQuickPin?(recordID) }
    }

    @objc private func quickCopy() {
        if let recordID { onQuickCopy?(recordID) }
    }
}
