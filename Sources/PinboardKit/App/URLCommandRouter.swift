import AppKit

enum PinboardCommand: String {
    case paste
    case show
    case hide
    case toggle
}

/// Parses `pinboard://` URLs and forwards them to the shared window manager.
/// Unknown commands are ignored instead of raising errors.
enum URLCommandRouter {
    @discardableResult
    static func handle(_ url: URL, manager: PinWindowManager = .shared) -> Bool {
        guard url.scheme?.lowercased() == "pinboard" else { return false }
        let raw = url.host?.lowercased()
            ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard let command = PinboardCommand(rawValue: raw) else { return false }
        return perform(command, manager: manager)
    }

    @discardableResult
    static func perform(_ command: PinboardCommand, manager: PinWindowManager = .shared) -> Bool {
        switch command {
        case .paste:
            guard manager.pasteFromClipboard() else {
                Toast.show("Nothing on the clipboard to pin")
                return false
            }
        case .show:
            manager.showAll()
        case .hide:
            manager.hideAll()
        case .toggle:
            manager.toggleAll()
        }
        return true
    }
}
