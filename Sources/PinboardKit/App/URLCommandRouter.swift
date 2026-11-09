import AppKit

enum PinboardCommand: String {
    case paste
    case show
    case hide
    case toggle
}

/// Parses `pinboard://` URLs and local file URLs and forwards them to the shared
/// window manager. Unknown commands are ignored instead of raising errors.
enum URLCommandRouter {
    @discardableResult
    static func handle(_ url: URL, manager: PinWindowManager = .shared) -> Bool {
        if url.isFileURL {
            return handleFileURL(url, manager: manager)
        }
        guard url.scheme?.lowercased() == "pinboard" else { return false }
        let raw = url.host?.lowercased()
            ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard let command = PinboardCommand(rawValue: raw) else { return false }
        return perform(command, manager: manager)
    }

    private static func handleFileURL(_ url: URL, manager: PinWindowManager) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["rtf", "rtfd"].contains(ext),
           let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil),
           attributed.length > 0 {
            _ = manager.createPin(content: .text(attributed), textMode: .richText)
            return true
        }
        if ["md", "markdown"].contains(ext),
           let source = try? String(contentsOf: url, encoding: .utf8),
           !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let attributed = NSAttributedString(string: source, attributes: ClipboardReader.defaultTextAttributes())
            _ = manager.createPin(content: .text(attributed), textMode: .markdown)
            return true
        }
        if let image = NSImage(contentsOf: url), image.isValid, image.pixelSize.width > 0 {
            _ = manager.createPin(content: .image(image))
            return true
        }
        if let text = try? String(contentsOf: url, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let attributed = NSAttributedString(string: text, attributes: ClipboardReader.defaultTextAttributes())
            _ = manager.createPin(content: .text(attributed))
            return true
        }
        return false
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
