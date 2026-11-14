import AppKit

/// The status item opens one borderless floating glass panel for pins and history.
/// Actions resolve current identities through the manager, including buttons retained
/// after a close.
final class MenuBarController: NSObject {
    enum Page: Equatable {
        case pins
        case history
    }

    let statusItem: NSStatusItem
    let panel = MenuBarFloatingPanel()
    var popover: MenuBarFloatingPanel { panel }
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
        let symbol = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinboard")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        symbol?.isTemplate = true
        button?.image = symbol
        button?.target = self
        button?.action = #selector(togglePanel(_:))
        button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button?.setAccessibilityLabel("Pinboard")

        panel.contentViewController = pinsViewController
        panel.onDidShow = { [weak self] in self?.panelDidShow() }
        panel.onDidClose = { [weak self] in self?.panelDidClose() }
        pinsSizeObservation = observeSize(of: pinsViewController)
        pinsViewController.onUtilityAction = { [weak self] action in self?.perform(action) }
        pinsViewController.onDismiss = { [weak self] in self?.panel.performClose(nil) }
        manager.onChange = { [weak self] in self?.pinsDidChange() }
        pinsDidChange()
    }

    deinit {
        panel.close()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private var isShowingHistory: Bool { activePage == .history }

    @objc func togglePanel(_ sender: Any?) {
        if let button = statusItem.button,
           sender as AnyObject? === button,
           let event = NSApp.currentEvent,
           event.type == .rightMouseUp || (event.type == .leftMouseUp && event.modifierFlags.contains(.control)) {
            panel.performClose(sender)
            presentStatusItemContextMenu(from: button)
            return
        }
        if panel.isShown {
            panel.performClose(sender)
        } else if let anchor = (sender as? NSView) ?? statusItem.button {
            refreshActivePage()
            panel.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }

    private func presentStatusItemContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu(title: "Pinboard")
        let pasteItem = NSMenuItem(title: "Pin Clipboard", action: #selector(contextPaste), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(contextOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit Pinboard", action: #selector(contextQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func contextPaste() { perform(.paste) }
    @objc private func contextOpenSettings() { perform(.settings) }
    @objc private func contextQuit() { perform(.quit) }

    private func panelDidShow() {
        statusItem.button?.highlight(true)
        let view = panel.contentViewController?.view
        view?.window?.makeKey()
        if isShowingHistory {
            historyViewController?.isPageActive = true
            historyViewController?.focusSearch()
        } else {
            view?.window?.makeFirstResponder(view)
        }
    }

    private func panelDidClose() {
        statusItem.button?.highlight(false)
        pinsViewController.clearHoverState()
        historyViewController?.clearHoverState()
        historyViewController?.isPageActive = false
    }

    private func refreshActivePage() {
        switch activePage {
        case .history:
            showHistory()
        case .pins:
            pinsViewController.reloadPins()
            syncPanelSize(for: pinsViewController)
        }
    }

    private func showHistory() {
        activePage = .history
        pinsViewController.clearHoverState()
        manager.flushAllHistorySyncs()
        if historyViewController == nil || historyViewController?.model?.store !== manager.historyStore {
            let model = manager.historyStore.map {
                HistoryViewModel(store: $0, manager: manager, pasteboard: historyPasteboard)
            }
            let history = HistoryPanelViewController(model: model)
            history.onBack = { [weak self, weak history] in
                guard let self else { return }
                self.activePage = .pins
                history?.clearHoverState()
                history?.isPageActive = false
                self.panel.contentViewController = self.pinsViewController
                self.pinsViewController.reloadPins()
                self.syncPanelSize(for: self.pinsViewController)
                self.pinsViewController.view.window?.makeFirstResponder(self.pinsViewController.view)
            }
            history.onDismiss = { [weak self] in self?.panel.performClose(nil) }
            history.onUtilityAction = { [weak self] in self?.perform($0) }
            historyViewController = history
            historySizeObservation = observeSize(of: history)
        }
        historyViewController?.isPageActive = true
        if panel.contentViewController !== historyViewController {
            panel.contentViewController = historyViewController
        }
        historyViewController?.reloadHistory()
        if let historyViewController { syncPanelSize(for: historyViewController) }
        if panel.isShown { historyViewController?.focusSearch() }
    }

    private func observeSize(of page: NSViewController) -> NSKeyValueObservation {
        page.observe(\.preferredContentSize, options: [.new]) { [weak self] page, _ in
            self?.syncPanelSize(for: page)
        }
    }

    private func syncPanelSize(for page: NSViewController) {
        guard panel.contentViewController === page,
              panel.contentSize != page.preferredContentSize else { return }
        panel.contentSize = page.preferredContentSize
    }

    private func pinsDidChange() {
        statusItem.button?.toolTip = "Pinboard · \(manager.count) pins · \(manager.visibleCount) visible"
        historyViewController?.toolbar.pinCount = manager.count
        guard panel.isShown, !isShowingHistory, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            if self.panel.isShown, !self.isShowingHistory { self.pinsViewController.reloadPins() }
        }
    }

    private func perform(_ action: MenuBarUtilityAction) {
        switch action {
        case .paste:
            URLCommandRouter.perform(.paste, manager: manager)
        case .history:
            showHistory()
        case .settings:
            panel.performClose(nil)
            onOpenSettings()
        case .quit:
            panel.performClose(nil)
            NSApp.terminate(nil)
        }
    }
}
