import AppKit

/// The status item opens one popover for pins and history. Actions resolve current
/// identities through the manager, including buttons retained after a close.
final class MenuBarController: NSObject, NSPopoverDelegate {
    enum Page: Equatable {
        case pins
        case history
    }

    let statusItem: NSStatusItem
    let popover = NSPopover()
    let pinsViewController: PinsPanelViewController
    private(set) var historyViewController: HistoryPanelViewController?
    private(set) var activePage: Page = .pins
    private let manager: PinWindowManager
    private var refreshScheduled = false
    private let onOpenSettings: () -> Void
    private let historyPasteboard: NSPasteboard
    private var pinsSizeObservation: NSKeyValueObservation?
    private var historySizeObservation: NSKeyValueObservation?

    init(manager: PinWindowManager, historyPasteboard: NSPasteboard = .general,
         onOpenSettings: @escaping () -> Void) {
        self.manager = manager
        self.historyPasteboard = historyPasteboard
        self.onOpenSettings = onOpenSettings
        pinsViewController = PinsPanelViewController(manager: manager)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let button = statusItem.button
        button?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinboard")
        button?.image?.isTemplate = true
        button?.target = self
        button?.action = #selector(togglePanel(_:))
        button?.setAccessibilityLabel("Pinboard")

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = pinsViewController
        popover.delegate = self
        pinsSizeObservation = observeSize(of: pinsViewController)
        pinsViewController.onUtilityAction = { [weak self] action in self?.perform(action) }
        pinsViewController.onDismiss = { [weak self] in self?.popover.performClose(nil) }
        manager.onChange = { [weak self] in self?.pinsDidChange() }
        pinsDidChange()
    }

    deinit {
        popover.close()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private var isShowingHistory: Bool { activePage == .history }

    @objc func togglePanel(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let anchor = (sender as? NSView) ?? statusItem.button {
            refreshActivePage()
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }

    func popoverDidShow(_ notification: Notification) {
        let view = popover.contentViewController?.view
        view?.window?.makeKey()
        if isShowingHistory {
            historyViewController?.isPageActive = true
            historyViewController?.focusSearch()
        } else {
            view?.window?.makeFirstResponder(view)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        historyViewController?.isPageActive = false
    }

    private func refreshActivePage() {
        switch activePage {
        case .history:
            showHistory()
        case .pins:
            pinsViewController.reloadPins()
            syncPopoverSize(for: pinsViewController)
        }
    }

    private func showHistory() {
        activePage = .history
        manager.flushAllHistorySyncs()
        if historyViewController == nil || historyViewController?.model?.store !== manager.historyStore {
            let model = manager.historyStore.map {
                HistoryViewModel(store: $0, manager: manager, pasteboard: historyPasteboard)
            }
            let history = HistoryPanelViewController(model: model)
            history.onBack = { [weak self, weak history] in
                guard let self else { return }
                self.activePage = .pins
                history?.isPageActive = false
                self.popover.contentViewController = self.pinsViewController
                self.pinsViewController.reloadPins()
                self.syncPopoverSize(for: self.pinsViewController)
                self.pinsViewController.view.window?.makeFirstResponder(self.pinsViewController.view)
            }
            history.onDismiss = { [weak self] in self?.popover.performClose(nil) }
            history.onUtilityAction = { [weak self] in self?.perform($0) }
            historyViewController = history
            historySizeObservation = observeSize(of: history)
        }
        historyViewController?.isPageActive = true
        if popover.contentViewController !== historyViewController {
            popover.contentViewController = historyViewController
        }
        historyViewController?.reloadHistory()
        if let historyViewController { syncPopoverSize(for: historyViewController) }
        if popover.isShown { historyViewController?.focusSearch() }
    }

    private func observeSize(of page: NSViewController) -> NSKeyValueObservation {
        page.observe(\.preferredContentSize, options: [.new]) { [weak self] page, _ in
            self?.syncPopoverSize(for: page)
        }
    }

    private func syncPopoverSize(for page: NSViewController) {
        // Older AppKit versions resize the page without updating the popover's
        // content size. Only the active page may resize the shared container.
        guard popover.contentViewController === page,
              popover.contentSize != page.preferredContentSize else { return }
        popover.contentSize = page.preferredContentSize
    }

    private func pinsDidChange() {
        statusItem.button?.toolTip = "Pinboard · \(manager.count) pins · \(manager.visibleCount) visible"
        guard popover.isShown, !isShowingHistory, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            if self.popover.isShown, !self.isShowingHistory { self.pinsViewController.reloadPins() }
        }
    }

    private func perform(_ action: MenuBarUtilityAction) {
        switch action {
        case .paste:
            URLCommandRouter.perform(.paste, manager: manager)
        case .history:
            showHistory()
        case .settings:
            popover.performClose(nil)
            onOpenSettings()
        case .quit:
            popover.performClose(nil)
            NSApp.terminate(nil)
        }
    }
}
