import AppKit

/// Status bar entry point. Every item routes through `PinWindowManager`, the
/// same path the URL scheme uses, so both stay consistent.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    var menu: NSMenu { statusItem.menu! }
    private let manager: PinWindowManager
    private let onOpenSettings: () -> Void
    var onOpenHistory: (() -> Void)?
    private let countItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pinsItem = NSMenuItem(title: "Current Pins", action: nil, keyEquivalent: "")
    private var pinMenus: [ObjectIdentifier: UUID] = [:]

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

    deinit { NSStatusBar.system.removeStatusItem(statusItem) }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
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
        let pinsMenu = NSMenu(title: "Current Pins")
        pinsMenu.autoenablesItems = false
        pinsMenu.delegate = self
        pinsItem.submenu = pinsMenu
        menu.addItem(pinsItem)
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
        if menu === self.menu || menu === pinsItem.submenu {
            rebuildPinList()
        } else if let id = pinMenus[ObjectIdentifier(menu)] {
            rebuildActions(menu, for: id, includingPreview: true)
        }
    }

    func rebuildPinList() {
        guard let list = pinsItem.submenu else { return }
        list.removeAllItems()
        pinMenus.removeAll()
        guard !manager.pins.isEmpty else {
            let empty = NSMenuItem(title: "No Pins", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            list.addItem(empty)
            return
        }
        for (index, pin) in manager.pins.enumerated() {
            let title = pin.contentView.previewTitle
            let row = NSMenuItem(title: "\(index + 1). \(title)\(pin.isPinVisible ? "" : " · Hidden")",
                                 action: nil, keyEquivalent: "")
            row.representedObject = pin.id
            row.state = pin.isPinVisible ? .on : .off
            row.image = pin.kind == .image
                ? pin.contentView.menuPreview(fitting: CGSize(width: 40, height: 28))
                : NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Text Pin")
            let actions = NSMenu(title: title)
            actions.autoenablesItems = false
            actions.delegate = self
            pinMenus[ObjectIdentifier(actions)] = pin.id
            rebuildActions(actions, for: pin.id, includingPreview: false)
            row.submenu = actions
            list.addItem(row)
        }
    }

    private func rebuildActions(_ menu: NSMenu, for id: UUID, includingPreview: Bool) {
        menu.removeAllItems()
        guard let pin = manager.pin(with: id) else {
            let closed = NSMenuItem(title: "Pin Closed", action: nil, keyEquivalent: "")
            closed.isEnabled = false
            menu.addItem(closed)
            return
        }
        if includingPreview,
           let image = pin.contentView.menuPreview(fitting: CGSize(width: 320, height: 180)) {
            let preview = NSMenuItem(title: pin.contentView.previewTitle, action: nil, keyEquivalent: "")
            preview.isEnabled = false
            preview.view = PinMenuPreviewView(image: image, title: pin.contentView.previewTitle,
                                              isVisible: pin.isPinVisible)
            menu.addItem(preview)
            menu.addItem(.separator())
        }
        for (label, selector) in [("Show Pin", #selector(showPin(_:))), ("Close Pin", #selector(closePin(_:)))] {
            let action = item(label, selector)
            action.representedObject = id
            menu.addItem(action)
        }
    }

    @objc private func showPin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let pin = manager.pin(with: id) else { return }
        pin.present()
        manager.notifyChange()
    }

    @objc private func closePin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        manager.pin(with: id)?.closePin()
    }

    private func updateCount() {
        let total = manager.count
        pinsItem.isEnabled = total > 0
        menu.items.first { $0.action == #selector(closeAll) }?.isEnabled = total > 0
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
