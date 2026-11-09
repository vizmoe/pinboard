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

    /// Normalizes all dot-prefixed system fonts in `attributed` to concrete
    /// font families so editors and toolbars never expose `.AppleSystemUIFont`,
    /// and ensures italic runs keep visual slant even when resolved to or
    /// falling back to CJK faces (`PingFang SC`) that lack an italic member.
    static func normalizingSystemFonts(in attributed: NSAttributedString) -> NSAttributedString {
        guard attributed.length > 0 else { return attributed }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.length)
        let nsString = mutable.string as NSString
        mutable.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            guard let font = value as? NSFont else {
                mutable.addAttribute(.font, value: Self.font, range: range)
                return
            }
            let wasItalic = font.fontDescriptor.symbolicTraits.contains(.italic)
                || font.fontName.localizedCaseInsensitiveContains("italic")
                || font.fontName.localizedCaseInsensitiveContains("oblique")
            let concrete = concreteFont(for: font)
            if concrete !== font {
                mutable.addAttribute(.font, value: concrete, range: range)
            }
            guard wasItalic else { return }
            let resolvedIsItalic = concrete.fontDescriptor.symbolicTraits.contains(.italic)
            if !resolvedIsItalic {
                mutable.addAttribute(.obliqueness, value: CGFloat(0.16), range: range)
            } else {
                // Latin italic fonts (e.g. Georgia-Italic, Times-Italic) fall
                // back to upright PingFang SC for CJK glyphs without applying
                // slant; split CJK subranges so Chinese italic text slants too.
                let isBold = concrete.fontDescriptor.symbolicTraits.contains(.bold)
                var cjkFont = Self.font.withSize(concrete.pointSize)
                if isBold {
                    cjkFont = NSFontManager.shared.convert(cjkFont, toHaveTrait: .boldFontMask)
                }
                for cjkRange in cjkSubranges(in: nsString, range: range) {
                    mutable.addAttribute(.font, value: cjkFont, range: cjkRange)
                    mutable.addAttribute(.obliqueness, value: CGFloat(0.16), range: cjkRange)
                }
            }
        }
        return mutable
    }

    private static func cjkSubranges(in string: NSString, range: NSRange) -> [NSRange] {
        let substring = string.substring(with: range)
        var ranges: [NSRange] = []
        var utf16Offset = range.location
        var currentStart: Int?
        for scalar in substring.unicodeScalars {
            let isCJK = (0x2E80...0x9FFF).contains(scalar.value)
                || (0x3000...0x303F).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0xFE30...0xFE4F).contains(scalar.value)
                || (0xFF00...0xFFEF).contains(scalar.value)
                || (0x20000...0x2FA1F).contains(scalar.value)
            if isCJK {
                if currentStart == nil { currentStart = utf16Offset }
            } else if let start = currentStart {
                ranges.append(NSRange(location: start, length: utf16Offset - start))
                currentStart = nil
            }
            utf16Offset += scalar.utf16.count
        }
        if let start = currentStart {
            ranges.append(NSRange(location: start, length: utf16Offset - start))
        }
        return ranges
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
