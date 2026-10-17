import AppKit

/// Status bar entry point. Every item routes through `PinWindowManager`, the
/// same path the URL scheme uses, so both stay consistent.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let manager: PinWindowManager
    private let onOpenSettings: () -> Void
    var onOpenHistory: (() -> Void)?
    private let countItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    init(manager: PinWindowManager, onOpenSettings: @escaping () -> Void) {
        self.manager = manager
        self.onOpenSettings = onOpenSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinboard")
        statusItem.button?.image?.isTemplate = true
        statusItem.menu = buildMenu()
        manager.onChange = { [weak self] in self?.updateCount() }
        updateCount()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item("Pin Clipboard", #selector(paste)))
        menu.addItem(.separator())
        menu.addItem(item("Show All Pins", #selector(showAll)))
        menu.addItem(item("Hide All Pins", #selector(hideAll)))
        menu.addItem(item("Toggle All Pins", #selector(toggleAll)))
        menu.addItem(.separator())
        menu.addItem(item("History…", #selector(openHistory), key: "y"))
        menu.addItem(.separator())
        countItem.isEnabled = false
        menu.addItem(countItem)
        menu.addItem(item("Close All Pins", #selector(closeAll)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Quit Pinboard", #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateCount()
    }

    private func updateCount() {
        let total = manager.count
        countItem.title = total == 0
            ? "No Pins"
            : "\(total) Pin\(total == 1 ? "" : "s") · \(manager.visibleCount) Visible"
    }

    // MARK: - Actions

    @objc private func paste() { URLCommandRouter.perform(.paste, manager: manager) }
    @objc private func showAll() { URLCommandRouter.perform(.show, manager: manager) }
    @objc private func hideAll() { URLCommandRouter.perform(.hide, manager: manager) }
    @objc private func toggleAll() { URLCommandRouter.perform(.toggle, manager: manager) }
    @objc private func closeAll() { manager.closeAll() }
    @objc private func openSettings() { onOpenSettings() }
    @objc private func openHistory() { onOpenHistory?() }
    @objc private func quit() { NSApp.terminate(nil) }
}
