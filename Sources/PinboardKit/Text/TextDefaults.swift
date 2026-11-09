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

    /// Monospaced face for Markdown code, one point smaller so code sits
    /// comfortably dense. Uses a concrete family (Menlo) rather than
    /// `.AppleSystemUIFontMonospaced`.
    static var monospacedFont: NSFont {
        NSFont(name: "Menlo-Regular", size: fontSize - 1)
            ?? NSFont(name: "Menlo", size: fontSize - 1)
            ?? .monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
    }

    /// Resolves a concrete user-facing font family name for toolbar pickers,
    /// mapping internal dot-prefixed system fonts (e.g. `.AppleSystemUIFont`)
    /// to the app's concrete default family (`PingFang SC` or `Menlo`).
    static func displayFontFamily(for font: NSFont) -> String {
        if let family = font.familyName, !family.isEmpty, !family.hasPrefix(".") {
            return family
        }
        if !font.fontName.isEmpty, !font.fontName.hasPrefix(".") {
            return font.fontName
        }
        if font.fontDescriptor.symbolicTraits.contains(.monoSpace)
            || font.fontName.localizedCaseInsensitiveContains("mono") {
            return "Menlo"
        }
        if isSerifFont(font) {
            return "Georgia"
        }
        return Self.font.familyName ?? "PingFang SC"
    }

    static func displayFontFamily(named name: String?) -> String {
        if let name, !name.isEmpty, !name.hasPrefix(".") {
            return name
        }
        if let name, name.localizedCaseInsensitiveContains("mono") {
            return "Menlo"
        }
        if let name, name.localizedCaseInsensitiveContains("serif") || name.localizedCaseInsensitiveContains("newyork") {
            return "Georgia"
        }
        return Self.font.familyName ?? "PingFang SC"
    }

    private static func isSerifFont(_ font: NSFont) -> Bool {
        let family = font.familyName ?? ""
        if font.fontName.localizedCaseInsensitiveContains("serif")
            || font.fontName.localizedCaseInsensitiveContains("newyork")
            || family.localizedCaseInsensitiveContains("serif") {
            return true
        }
        let serifClasses: NSFontDescriptor.SymbolicTraits = [
            .classOldStyleSerifs, .classTransitionalSerifs, .classModernSerifs,
            .classClarendonSerifs, .classSlabSerifs
        ]
        return !font.fontDescriptor.symbolicTraits.intersection(serifClasses).isEmpty
    }

    /// Replaces internal dot-prefixed system fonts (`.AppleSystemUIFont`,
    /// `.AppleSystemUIFontMonospaced`, `.NewYork`, etc.) with concrete fonts
    /// (`PingFang SC`, `Georgia` or `Menlo`) while preserving point size and
    /// bold/italic traits.
    static func concreteFont(for font: NSFont) -> NSFont {
        let family = font.familyName ?? ""
        guard family.isEmpty || family.hasPrefix(".") || font.fontName.hasPrefix(".") else {
            return font
        }
        let traits = font.fontDescriptor.symbolicTraits
        let isMono = traits.contains(.monoSpace) || font.fontName.localizedCaseInsensitiveContains("mono")
        let isSerif = isSerifFont(font)
        let targetFamily: String
        if isMono {
            targetFamily = "Menlo"
        } else if isSerif {
            targetFamily = "Georgia"
        } else {
            targetFamily = Self.font.familyName ?? "PingFang SC"
        }
        let base = NSFont(name: targetFamily, size: font.pointSize) ?? Self.font.withSize(font.pointSize)
        var resolved = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? base
        if traits.contains(.bold), !resolved.fontDescriptor.symbolicTraits.contains(.bold) {
            resolved = NSFontManager.shared.convert(resolved, toHaveTrait: .boldFontMask)
        }
        if traits.contains(.italic), !resolved.fontDescriptor.symbolicTraits.contains(.italic) {
            resolved = NSFontManager.shared.convert(resolved, toHaveTrait: .italicFontMask)
        }
        return resolved
    }

    /// Shared paragraph style across Rich Text, Plain Text and Markdown body
    /// text so unstyled text has identical line height and layout in every mode.
    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 0
        return style
    }

    /// Attributes for content that has no formatting of its own.
    static var attributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    /// Fills in missing default font, foreground colour and paragraph style on
    /// an attributed string while keeping explicit run attributes intact.
    static func applyingDefaults(to attributed: NSAttributedString) -> NSAttributedString {
        guard attributed.length > 0 else { return attributed }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            if attrs[.font] == nil {
                mutable.addAttribute(.font, value: font, range: range)
            }
            if attrs[.foregroundColor] == nil {
                mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
            if attrs[.paragraphStyle] == nil {
                mutable.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
            }
        }
        return mutable
    }
}
