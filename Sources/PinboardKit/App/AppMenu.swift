import AppKit

/// Minimal main menu. An accessory app still needs one so standard editing key
/// equivalents (⌘Z/⌘X/⌘C/⌘V/⌘A, ⌘B/⌘I/⌘U) reach the focused text view.
enum AppMenu {
    static func install() {
        let main = NSMenu()
        main.addItem(submenu(title: "Pinboard") { menu in
            add(menu, "About Pinboard", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
            menu.addItem(.separator())
            add(menu, "Settings…", #selector(AppDelegate.openSettings(_:)), ",")
            menu.addItem(.separator())
            add(menu, "Hide All Pins", #selector(AppDelegate.hideAllPins(_:)))
            menu.addItem(.separator())
            add(menu, "Quit Pinboard", #selector(NSApplication.terminate(_:)), "q")
        })
        main.addItem(submenu(title: "Edit") { menu in
            add(menu, "Undo", Selector(("undo:")), "z")
            add(menu, "Redo", Selector(("redo:")), "z", modifiers: [.command, .shift])
            menu.addItem(.separator())
            add(menu, "Cut", #selector(NSText.cut(_:)), "x")
            add(menu, "Copy", #selector(NSText.copy(_:)), "c")
            add(menu, "Paste", #selector(NSText.paste(_:)), "v")
            add(menu, "Paste as Plain Text", #selector(NSTextView.pasteAsPlainText(_:)), "v",
                modifiers: [.command, .option, .shift])
            add(menu, "Delete", #selector(NSText.delete(_:)))
            add(menu, "Select All", #selector(NSText.selectAll(_:)), "a")
        })
        main.addItem(submenu(title: "Format") { menu in
            add(menu, "Bold", #selector(NSFontManager.addFontTrait(_:)), "b",
                target: NSFontManager.shared, tag: Int(NSFontTraitMask.boldFontMask.rawValue))
            add(menu, "Italic", #selector(NSFontManager.addFontTrait(_:)), "i",
                target: NSFontManager.shared, tag: Int(NSFontTraitMask.italicFontMask.rawValue))
            add(menu, "Underline", #selector(NSText.underline(_:)), "u")
            menu.addItem(.separator())
            add(menu, "Show Colors", #selector(NSApplication.orderFrontColorPanel(_:)), "c",
                modifiers: [.command, .shift])
        })
        main.addItem(submenu(title: "Window") { menu in
            add(menu, "Close Pin", #selector(AppDelegate.closeFocusedPin(_:)), "w")
            add(menu, "Hide Pin", #selector(AppDelegate.hideFocusedPin(_:)), "h")
        })
        NSApp.mainMenu = main
    }

    private static func submenu(title: String, build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: title)
        build(menu)
        item.submenu = menu
        return item
    }

    @discardableResult
    private static func add(
        _ menu: NSMenu,
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        modifiers: NSEvent.ModifierFlags? = nil,
        target: AnyObject? = nil,
        tag: Int = 0
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if let modifiers { item.keyEquivalentModifierMask = modifiers }
        item.target = target
        item.tag = tag
        menu.addItem(item)
        return item
    }
}
