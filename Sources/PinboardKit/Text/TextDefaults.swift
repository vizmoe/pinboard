import AppKit

/// The app-wide default typography for text content: plain imports, Plain
/// Text pins, Markdown rendering and formatting resets all share it, so a
/// change here moves every default in one place.
enum TextDefaults {
    /// The default text size.
    static let fontSize: CGFloat = 14

    /// PingFang SC is the macOS CJK face and covers Latin and Chinese alike;
    /// fall back to the system font if it is ever unavailable.
    static var font: NSFont {
        NSFont(name: "PingFang SC", size: fontSize) ?? .systemFont(ofSize: fontSize)
    }

    /// Monospaced face for raw Markdown source editing, one point smaller so
    /// the source sits comfortably dense.
    static var monospacedFont: NSFont {
        .monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
    }

    /// Attributes for content that has no formatting of its own.
    static var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.labelColor]
    }
}
