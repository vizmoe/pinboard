import AppKit

/// The status item opens one popover for pins and history. Actions resolve current
/// identities through the manager, including buttons retained after a close.
final class MenuBarController: NSObject, NSPopoverDelegate {
    let statusItem: NSStatusItem
    let popover = NSPopover()
    let pinsViewController: PinsPanelViewController
    private(set) var historyViewController: HistoryPanelViewController?
    private let manager: PinWindowManager
    private var refreshScheduled = false
    private let onOpenSettings: () -> Void
    private let historyPasteboard: NSPasteboard

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
        button?.setAccessibilityLabel("Pinboard — Pins")

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = pinsViewController
        popover.delegate = self
        pinsViewController.onUtilityAction = { [weak self] action in self?.perform(action) }
        pinsViewController.onDismiss = { [weak self] in self?.popover.performClose(nil) }
        manager.onChange = { [weak self] in self?.pinsDidChange() }
        pinsDidChange()
    }

    deinit {
        popover.close()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc func togglePanel(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let anchor = (sender as? NSView) ?? statusItem.button {
            pinsViewController.reloadPins()
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }

    func popoverWillShow(_ notification: Notification) {
        pinsViewController.reloadPins()
    }

    func popoverDidShow(_ notification: Notification) {
        let view = popover.contentViewController?.view
        view?.window?.makeKey()
        view?.window?.makeFirstResponder(view)
    }

    private func showHistory() {
        manager.flushAllHistorySyncs()
        if historyViewController == nil || historyViewController?.model?.store !== manager.historyStore {
            let model = manager.historyStore.map {
                HistoryViewModel(store: $0, manager: manager, pasteboard: historyPasteboard)
            }
            let history = HistoryPanelViewController(model: model)
            history.onBack = { [weak self] in
                guard let self else { return }
                self.pinsViewController.reloadPins()
                self.popover.contentViewController = self.pinsViewController
                self.pinsViewController.view.window?.makeFirstResponder(self.pinsViewController.view)
            }
            history.onDismiss = { [weak self] in self?.popover.performClose(nil) }
            history.onUtilityAction = { [weak self] in self?.perform($0) }
            historyViewController = history
        }
        historyViewController?.reloadHistory()
        popover.contentViewController = historyViewController
        historyViewController?.focusSearch()
    }

    private func pinsDidChange() {
        statusItem.button?.toolTip = "Pinboard · \(manager.count) pins · \(manager.visibleCount) visible"
        guard popover.isShown, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            if self.popover.isShown { self.pinsViewController.reloadPins() }
        }
    }

    private func perform(_ action: PinsPanelViewController.UtilityAction) {
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
