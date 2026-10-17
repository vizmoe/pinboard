import AppKit

/// Colour palette for rendered Markdown pins, picked in Settings.
///
/// A theme is a display concern: it paints the rendered document, the raw
/// source while editing and the paper behind both. A pin's canonical content
/// stays the Markdown source, so switching themes never changes what a pin
/// stores, copies or brings back from history.
enum MarkdownTheme: String, CaseIterable, Identifiable {
    /// System colours on the usual paper; text pins stay transparent unless
    /// they were switched to an opaque background.
    case standard
    /// Everforest Dark Hard — the low-contrast dark variant of Everforest.
    case everforestDarkHard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Default"
        case .everforestDarkHard: return "Everforest Dark Hard"
        }
    }

    /// The paper behind the document. nil keeps the standard background: a
    /// transparent pin stays transparent, an opaque one paints the system
    /// text background.
    var background: NSColor? {
        switch self {
        case .standard: return nil
        case .everforestDarkHard: return Everforest.bg0
        }
    }

    var text: NSColor {
        switch self {
        case .standard: return .labelColor
        case .everforestDarkHard: return Everforest.fg
        }
    }

    var secondaryText: NSColor {
        switch self {
        case .standard: return .secondaryLabelColor
        case .everforestDarkHard: return Everforest.grey2
        }
    }

    var link: NSColor {
        switch self {
        case .standard: return .linkColor
        case .everforestDarkHard: return Everforest.blue
        }
    }

    var codeBackground: NSColor {
        switch self {
        case .standard: return NSColor.labelColor.withAlphaComponent(0.08)
        case .everforestDarkHard: return Everforest.bg1
        }
    }

    /// Highlight behind a selection in the source editor; nil keeps the system
    /// selection colour.
    var selection: NSColor? {
        switch self {
        case .standard: return nil
        case .everforestDarkHard: return Everforest.visual
        }
    }

    /// Everforest Dark Hard, as published at
    /// https://everforest.vercel.app/palette (scheme by Sainnhe Park,
    /// https://github.com/sainnhe/everforest).
    private enum Everforest {
        static let bg0 = NSColor(rgb: 0x272E33) // Background 0
        static let bg1 = NSColor(rgb: 0x2E383C) // Background 1: code blocks
        static let visual = NSColor(rgb: 0x4C3743) // Background Visual: selection
        static let fg = NSColor(rgb: 0xD3C6AA) // Foreground
        static let grey2 = NSColor(rgb: 0x9DA9A0) // Muted text
        static let blue = NSColor(rgb: 0x7FBBB3) // Links
    }
}

extension MarkdownRenderer.Style {
    /// The colours a theme paints a rendered document with. The pin's paper is
    /// not part of `Style` — it belongs to the pin body.
    init(theme: MarkdownTheme) {
        self.init()
        textColor = theme.text
        secondaryTextColor = theme.secondaryText
        linkColor = theme.link
        codeBackgroundColor = theme.codeBackground
    }
}

private extension NSColor {
    /// A palette colour from its published 0xRRGGBB value. Unlike
    /// `init?(hex:)` this cannot fail, so the literals above stay exact.
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}
