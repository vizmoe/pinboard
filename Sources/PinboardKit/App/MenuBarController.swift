import AppKit

/// The status item opens one live pins panel. All actions resolve current pin
/// identities through the manager, including buttons retained after a close.
final class MenuBarController: NSObject, NSPopoverDelegate {
    let statusItem: NSStatusItem
    let popover = NSPopover()
    let pinsViewController: PinsPanelViewController
    private let manager: PinWindowManager
    private var refreshScheduled = false
    private let onOpenSettings: () -> Void
    var onOpenHistory: (() -> Void)?

    init(manager: PinWindowManager, onOpenSettings: @escaping () -> Void) {
        self.manager = manager
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
        pinsViewController.view.window?.makeKey()
        pinsViewController.view.window?.makeFirstResponder(pinsViewController.view)
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
            popover.performClose(nil)
            onOpenHistory?()
        case .settings:
            popover.performClose(nil)
            onOpenSettings()
        case .quit:
            popover.performClose(nil)
            NSApp.terminate(nil)
        }
    }
}
