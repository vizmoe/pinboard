import AppKit

/// Applies formatting to an `NSTextView` without flattening attributes the
/// user did not touch.
///
/// Every change goes through `shouldChangeText(in:replacementString:)` /
/// `didChangeText()`, which is how AppKit records attribute-only edits in the
/// text view's own undo stack. Font changes are applied run by run, so a bold
/// toggle over mixed text keeps each run's family, size and colour.
struct TextFormatter {
    let textView: NSTextView

    static let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    // MARK: - Current state

    var selectedRange: NSRange { textView.selectedRange() }
    var hasSelection: Bool { selectedRange.length > 0 }

    /// Attributes a new character would get: the selection's first run, or the
    /// typing attributes when nothing is selected.
    ///
    /// With a collapsed caret the typing attributes are authoritative — AppKit
    /// reseeds them from the caret position on every selection change, and
    /// reading the storage instead would discard formatting the user just chose
    /// for the text they are about to type.
    var currentAttributes: [NSAttributedString.Key: Any] {
        guard let storage = textView.textStorage, storage.length > 0 else { return textView.typingAttributes }
        let range = selectedRange
        guard range.length > 0 else { return textView.typingAttributes }
        return storage.attributes(at: min(range.location, storage.length - 1), effectiveRange: nil)
    }

    var currentFont: NSFont {
        (currentAttributes[.font] as? NSFont) ?? TextFormatter.baseFont
    }

    func currentColor(_ key: NSAttributedString.Key) -> NSColor? {
        currentAttributes[key] as? NSColor
    }

    func isTraitActive(_ trait: NSFontDescriptor.SymbolicTraits) -> Bool {
        currentFont.fontDescriptor.symbolicTraits.contains(trait)
    }

    func isAttributeActive(_ key: NSAttributedString.Key) -> Bool {
        guard let value = currentAttributes[key] as? Int else { return false }
        return value != 0
    }

    // MARK: - Mutations

    /// Transforms the font of every run in the target range individually.
    func transformFonts(_ transform: (NSFont) -> NSFont) {
        guard hasSelection, let storage = textView.textStorage else {
            var attributes = textView.typingAttributes
            attributes[.font] = transform((attributes[.font] as? NSFont) ?? currentFont)
            textView.typingAttributes = attributes
            return
        }
        let range = selectedRange
        var runs: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            runs.append((subrange, (value as? NSFont) ?? TextFormatter.baseFont))
        }
        edit { storage in
            for (subrange, font) in runs {
                storage.addAttribute(.font, value: transform(font), range: subrange)
            }
        }
    }

    func setAttribute(_ key: NSAttributedString.Key, value: Any?) {
        guard hasSelection, let storage = textView.textStorage else {
            var attributes = textView.typingAttributes
            if let value { attributes[key] = value } else { attributes.removeValue(forKey: key) }
            textView.typingAttributes = attributes
            return
        }
        let range = selectedRange
        edit { storage in
            if let value {
                storage.addAttribute(key, value: value, range: range)
            } else {
                storage.removeAttribute(key, range: range)
            }
        }
    }

    func toggleAttribute(_ key: NSAttributedString.Key, activeValue: Int = NSUnderlineStyle.single.rawValue) {
        setAttribute(key, value: isAttributeActive(key) ? 0 : activeValue)
    }

    func toggleTrait(_ trait: NSFontDescriptor.SymbolicTraits) {
        let shouldAdd = !isTraitActive(trait)
        transformFonts { font in
            var traits = font.fontDescriptor.symbolicTraits
            if shouldAdd { traits.insert(trait) } else { traits.remove(trait) }
            let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
            return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }
    }

    func setFontSize(_ size: CGFloat) {
        guard size > 0 else { return }
        transformFonts { font in
            NSFont(descriptor: font.fontDescriptor, size: size) ?? font
        }
    }

    func setFontFamily(_ family: String) {
        let manager = NSFontManager.shared
        transformFonts { font in
            manager.convert(font, toFamily: family)
        }
    }

    /// Drops manual formatting, keeping the text itself untouched.
    func clearFormatting() {
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: TextFormatter.baseFont,
            .foregroundColor: NSColor.labelColor
        ]
        guard hasSelection else {
            textView.typingAttributes = baseAttributes
            return
        }
        let range = selectedRange
        edit { storage in
            for key: NSAttributedString.Key in [.underlineStyle, .strikethroughStyle, .backgroundColor,
                                                .shadow, .paragraphStyle, .kern, .ligature, .baselineOffset,
                                                .underlineColor, .strikethroughColor, .obliqueness, .expansion] {
                storage.removeAttribute(key, range: range)
            }
            for (key, value) in baseAttributes {
                storage.addAttribute(key, value: value, range: range)
            }
        }
    }

    // MARK: - Helpers

    private func edit(_ body: (NSTextStorage) -> Void) {
        guard let storage = textView.textStorage else { return }
        let range = selectedRange
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        body(storage)
        storage.endEditing()
        textView.didChangeText()
    }

    static let commonFontSizes: [CGFloat] = [9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72]
}
