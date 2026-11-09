import AppKit
import UniformTypeIdentifiers

/// Reads the system pasteboard and resolves it to a single `PinContent`.
///
/// Resolution order is fixed so the result stays predictable when a pasteboard
/// carries several unrelated representations:
///   RTFD -> RTF -> image data -> image file URL -> HTML -> plain text
/// Rich text wins over image data because apps such as Word or Pages attach a
/// TIFF/PDF preview of the copied selection alongside the real RTF payload.
enum ClipboardReader {
    static func read(from pasteboard: NSPasteboard = .general) -> PinContent? {
        if let text = nonEmpty(readRTF(from: pasteboard)) { return .text(text) }
        if let image = readImage(from: pasteboard) { return .image(image) }
        if let text = nonEmpty(readHTML(from: pasteboard)) { return .text(text) }
        if let text = nonEmpty(readPlainText(from: pasteboard)) { return .text(text) }
        return nil
    }

    static func defaultTextAttributes() -> [NSAttributedString.Key: Any] {
        TextDefaults.attributes
    }

    private static func nonEmpty(_ text: NSAttributedString?) -> NSAttributedString? {
        guard let text, text.length > 0 else { return nil }
        return text
    }

    private static func readRTF(from pasteboard: NSPasteboard) -> NSAttributedString? {
        if let data = pasteboard.data(forType: .rtfd),
           let text = NSAttributedString(rtfd: data, documentAttributes: nil) {
            return normalizeImportedRichText(text, isFromHTML: false)
        }
        if let data = pasteboard.data(forType: .rtf),
           let text = NSAttributedString(rtf: data, documentAttributes: nil) {
            return normalizeImportedRichText(text, isFromHTML: false)
        }
        return nil
    }

    private static func readHTML(from pasteboard: NSPasteboard) -> NSAttributedString? {
        guard let rawData = pasteboard.data(forType: .html) else { return nil }
        let preparedData = preprocessHTML(rawData)
        guard let rich = try? NSAttributedString(
                  data: preparedData,
                  options: [.documentType: NSAttributedString.DocumentType.html,
                            .characterEncoding: String.Encoding.utf8.rawValue],
                  documentAttributes: nil
              ) else { return nil }
        // HTML whitespace collapsing eats the line breaks chat apps ship as
        // raw newlines inside normal-flow markup (they rely on CSS
        // `white-space: pre-wrap`, which the importer ignores). The plain-text
        // flavour on the same pasteboard still carries the true structure, so
        // when both describe the same words, transplant its whitespace back.
        let text: NSAttributedString
        let plain = pasteboard.string(forType: .string)
        if let plain,
           let restored = restoreWhitespace(of: plain, into: rich) {
            text = restored
        } else {
            text = cleanHTMLBlockLineSeparators(in: rich, plainCounterpart: plain)
        }
        let tagged = taggingHTMLImages(in: text, html: rawData)
        return normalizeImportedRichText(tagged, isFromHTML: true)
    }

    /// Cleans up redundant line/paragraph separators that `NSHTMLReader` emits
    /// when web apps wrap list items in nested block tags (such as
    /// `<li><div><div><p>...</p></div></div></li>`), where each closing
    /// `</p>` and `</div>` produces an extra `U+2028` before `</li>`'s `\n`,
    /// and trims synthetic trailing block newlines when the plain-text
    /// counterpart confirms the selection does not end with a newline.
    private static func cleanHTMLBlockLineSeparators(
        in rich: NSAttributedString,
        plainCounterpart plain: String?
    ) -> NSAttributedString {
        guard rich.length > 0 else { return rich }
        let mutable = NSMutableAttributedString(attributedString: rich)

        if let regex = try? NSRegularExpression(
            pattern: "[\\u2028\\u2029]+(?=\\n|$)|([\\u2028\\u2029])[\\u2028\\u2029]+"
        ) {
            let matches = regex.matches(in: mutable.string, range: NSRange(location: 0, length: mutable.length))
            for match in matches.reversed() {
                if match.range(at: 1).location != NSNotFound {
                    mutable.replaceCharacters(in: match.range, with: "\u{2028}")
                } else {
                    mutable.deleteCharacters(in: match.range)
                }
            }
        }

        if let plain {
            let richNS = mutable.string as NSString
            let plainNS = plain as NSString
            if let lastRich = wordRuns(in: richNS).last,
               let lastPlain = wordRuns(in: plainNS).last,
               richNS.substring(with: lastRich) == plainNS.substring(with: lastPlain) {
                let plainTrailingNewlines = plain.reversed().prefix(while: { $0 == "\n" || $0 == "\r" }).count
                var richTrailingNewlines = 0
                for ch in mutable.string.reversed() {
                    if ch == "\n" || ch == "\r" || ch == "\u{2028}" || ch == "\u{2029}" {
                        richTrailingNewlines += 1
                    } else {
                        break
                    }
                }
                let excess = richTrailingNewlines - plainTrailingNewlines
                if excess > 0, mutable.length >= excess {
                    mutable.deleteCharacters(in: NSRange(location: mutable.length - excess, length: excess))
                }
            }
        }

        return mutable
    }

    /// Preprocesses raw HTML before `NSHTMLReader` parses it. Only inline
    /// `style` attribute values are rewritten; visible text (including pasted
    /// CSS snippets) passes through untouched.
    static func preprocessHTML(_ data: Data) -> Data {
        guard let html = String(data: data, encoding: .utf8) else { return data }
        let rewritten = replacingMatches(of: openingTagPattern, in: html) { tag in
            replacingMatches(of: styleAttributePattern, in: tag) { attribute in
                guard let quoteIndex = attribute.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return attribute }
                let prefix = attribute[...quoteIndex]
                let value = attribute[attribute.index(after: quoteIndex)..<attribute.index(before: attribute.endIndex)]
                return String(prefix) + rewriteInlineStyle(String(value)) + String(attribute[quoteIndex])
            }
        }
        return Data(rewritten.utf8)
    }

    private static let openingTagPattern = try? NSRegularExpression(pattern: #"<[A-Za-z][^>]*>"#)
    private static let styleAttributePattern = try? NSRegularExpression(
        pattern: #"\bstyle\s*=\s*(?:"[^"]*"|'[^']*')"#, options: [.caseInsensitive]
    )
    private static let cssVariablePattern = try? NSRegularExpression(
        pattern: #"var\(\s*--[^,)]+,\s*([^)]+)\)"#, options: [.caseInsensitive]
    )
    private static let systemSerifPattern = try? NSRegularExpression(
        pattern: #"(?:-apple-system-)?ui-serif"#, options: [.caseInsensitive]
    )
    private static let containerIndentPattern = try? NSRegularExpression(
        pattern: #"(?:margin-(?:left|right|inline(?:-start|-end)?)|text-indent\s*:\s*0(?:px|pt|em|rem|%)?)\s*(?::\s*[^;"']+)?"#,
        options: [.caseInsensitive]
    )

    /// - Expands CSS `var(--name, fallback)` so browser extensions (e.g.
    ///   Immersive Translate) keep their custom colours.
    /// - Maps `ui-serif` / `-apple-system-ui-serif` to `Georgia` because
    ///   `NSHTMLReader` maps `ui-serif` to `.NewYork-Regular` and drops italic.
    /// - Strips `margin-left`/`margin-right` and `text-indent: 0px` that Chrome
    ///   serializes from centered page containers (which otherwise cause
    ///   `NSHTMLReader` to emit a hanging indent on lines 2+).
    private static func rewriteInlineStyle(_ style: String) -> String {
        var css = style
        if let cssVariablePattern {
            for _ in 0..<3 {
                let next = cssVariablePattern.stringByReplacingMatches(
                    in: css, range: NSRange(location: 0, length: (css as NSString).length), withTemplate: "$1")
                if next == css { break }
                css = next
            }
        }
        for (pattern, template) in [(systemSerifPattern, "Georgia"), (containerIndentPattern, "")] {
            guard let pattern else { continue }
            css = pattern.stringByReplacingMatches(
                in: css, range: NSRange(location: 0, length: (css as NSString).length), withTemplate: template)
        }
        return css
    }

    private static func replacingMatches(
        of pattern: NSRegularExpression?,
        in string: String,
        transform: (String) -> String
    ) -> String {
        guard let pattern else { return string }
        let source = string as NSString
        var output = ""
        var cursor = 0
        for match in pattern.matches(in: string, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += transform(source.substring(with: match.range))
            cursor = NSMaxRange(match.range)
        }
        output += source.substring(from: cursor)
        return output
    }

    /// Cleans up web/HTML layout artifacts while preserving semantic rich-text
    /// formatting (bold, italic, serif/monospace faces, links, highlights and
    /// intentional text colours).
    static func normalizeImportedRichText(_ attributed: NSAttributedString, isFromHTML: Bool) -> NSAttributedString {
        let normalizedFonts = TextDefaults.normalizingSystemFonts(in: attributed)
        guard normalizedFonts.length > 0 else { return normalizedFonts }
        let mutable = NSMutableAttributedString(attributedString: normalizedFonts)
        let fullRange = NSRange(location: 0, length: mutable.length)

        var hasWebStroke = false
        var nonWhitespaceCount = 0
        var lowSatBackgroundCount = 0
        var fontSizeCounts: [CGFloat: Int] = [:]
        let nsString = mutable.string as NSString

        mutable.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            let sub = nsString.substring(with: range)
            let charCount = sub.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
            nonWhitespaceCount += charCount

            if attrs[.strokeColor] != nil {
                let width = (attrs[.strokeWidth] as? NSNumber)?.doubleValue ?? 0
                if abs(width) < 0.01 {
                    hasWebStroke = true
                }
            }
            if let bg = (attrs[.backgroundColor] as? NSColor)?.usingColorSpace(.sRGB),
               bg.alphaComponent > 0.05, bg.saturationComponent < 0.22 {
                lowSatBackgroundCount += charCount
            }
            if charCount > 0, let font = attrs[.font] as? NSFont {
                let rounded = (font.pointSize * 2).rounded() / 2
                fontSizeCounts[rounded, default: 0] += charCount
            }
        }

        let isWebContent = isFromHTML || hasWebStroke
        let stripContainerBackground = isWebContent && nonWhitespaceCount > 0
            && Double(lowSatBackgroundCount) / Double(nonWhitespaceCount) >= 0.5

        // Scale oversized web body text (e.g. 18–20px article prose) toward the
        // app's 14pt base while keeping relative heading scale.
        var fontScale: CGFloat = 1.0
        if isWebContent,
           let dominantSize = fontSizeCounts.max(by: { $0.value < $1.value })?.key,
           dominantSize > 15.5, dominantSize <= 22 {
            fontScale = max(0.72, TextDefaults.fontSize / dominantSize)
        }

        mutable.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            if attrs[.strokeColor] != nil {
                let width = (attrs[.strokeWidth] as? NSNumber)?.doubleValue ?? 0
                if abs(width) < 0.01 {
                    mutable.removeAttribute(.strokeColor, range: range)
                    mutable.removeAttribute(.strokeWidth, range: range)
                }
            }

            if stripContainerBackground,
               let bg = (attrs[.backgroundColor] as? NSColor)?.usingColorSpace(.sRGB),
               bg.saturationComponent < 0.22 {
                mutable.removeAttribute(.backgroundColor, range: range)
            }

            if isWebContent,
               let fg = (attrs[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB),
               fg.saturationComponent < 0.15 {
                // Neutral web body text (near-white from dark pages or near-black
                // from light pages) adapts to the pin's native labelColor, while
                // coloured text (e.g. teal translations) keeps its hue.
                if stripContainerBackground || fg.brightnessComponent > 0.82 || fg.brightnessComponent < 0.22 {
                    mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
                }
            }

            if fontScale < 0.99, let font = attrs[.font] as? NSFont {
                let newSize = max(11, (font.pointSize * fontScale * 2).rounded() / 2)
                if let scaled = NSFont(descriptor: font.fontDescriptor, size: newSize) {
                    mutable.addAttribute(.font, value: scaled, range: range)
                }
            }

            if let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle {
                let clean = cleanParagraphStyle(paragraph, isWebContent: isWebContent)
                mutable.addAttribute(.paragraphStyle, value: clean, range: range)
            }
        }

        return mutable
    }

    private static func cleanParagraphStyle(_ style: NSParagraphStyle, isWebContent: Bool) -> NSParagraphStyle {
        let mutable = (style.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        // A positive tail indent fixes the line width, so text would never wrap
        // to the pin; web containers also leave negative right insets behind.
        if mutable.tailIndent > 0 || (isWebContent && mutable.tailIndent != 0) {
            mutable.tailIndent = 0
        }
        // Native RTF hanging indents (bibliographies, definitions) are intentional.
        if isWebContent, mutable.textLists.isEmpty {
            // Fix NSHTMLReader's `margin-left` + `text-indent: 0px` bug where
            // line 1 starts at 0 and lines 2+ indent by the page margin.
            if mutable.firstLineHeadIndent == 0, mutable.headIndent > 0 {
                mutable.headIndent = 0
            } else if mutable.headIndent > 36 {
                mutable.headIndent = 0
                mutable.firstLineHeadIndent = 0
            }
        }
        if isWebContent {
            mutable.lineSpacing = max(mutable.lineSpacing, 2)
            if !mutable.textLists.isEmpty {
                if mutable.paragraphSpacing > 4 {
                    mutable.paragraphSpacing = 4
                }
            } else if mutable.paragraphSpacing > 10 {
                mutable.paragraphSpacing = 8
            }
            if mutable.paragraphSpacingBefore > 8 {
                mutable.paragraphSpacingBefore = 4
            }
        }
        return mutable
    }

    /// Tags the attachment of every `<img>` with its source, in document
    /// order, and drops the placeholder character of images the page never
    /// shows. The importer creates exactly one attachment per image and never
    /// resolves its content, so the tag is what lets a pin fill the image in.
    private static func taggingHTMLImages(in text: NSAttributedString, html: Data) -> NSAttributedString {
        let sources = HTMLImages.sources(in: html)
        guard !sources.isEmpty else { return text }

        let result = NSMutableAttributedString(attributedString: text)
        var attachmentRanges: [NSRange] = []
        result.enumerateAttribute(.attachment, in: result.fullRange, options: []) { value, range, _ in
            if value is NSTextAttachment { attachmentRanges.append(range) }
        }
        // Positional mapping is only trustworthy while both sides agree; a
        // mismatch would attach the wrong picture somewhere.
        guard attachmentRanges.count == sources.count else { return text }

        for (index, range) in attachmentRanges.enumerated().reversed() {
            guard let source = sources[index], !source.isEmpty else {
                // The importer still reserves a character for a hidden image
                // and renders its bytes; the page itself shows nothing.
                result.deleteCharacters(in: range)
                continue
            }
            result.addAttribute(DeferredImages.sourceAttribute, value: source, range: range)
        }
        return result
    }

    /// Rebuilds `rich` using the whitespace runs of `plain`, keeping every
    /// non-whitespace character and its attributes from `rich`. Returns nil
    /// when the two don't describe the same text — e.g. a stale or unrelated
    /// plain-text flavour — so callers can keep the imported result.
    private static func restoreWhitespace(of plain: String, into rich: NSAttributedString) -> NSAttributedString? {
        let richString = rich.string as NSString
        let plainString = plain as NSString
        let richRuns = wordRuns(in: richString)
        let plainRuns = wordRuns(in: plainString)
        guard richRuns.count == plainRuns.count, zip(richRuns, plainRuns).allSatisfy({
            richString.substring(with: $0) == plainString.substring(with: $1)
        }) else { return nil }

        func whitespace(_ string: String, styledLike position: Int, keepLink: Bool) -> NSAttributedString {
            guard !string.isEmpty else { return NSAttributedString() }
            var attributes = rich.length > 0
                ? rich.attributes(at: min(max(position, 0), rich.length - 1), effectiveRange: nil)
                : defaultTextAttributes()
            if !keepLink {
                attributes.removeValue(forKey: .link)
            }
            return NSAttributedString(string: string, attributes: attributes)
        }

        func linksMatch(_ lhs: Any?, _ rhs: Any?) -> Bool {
            guard let lhs, let rhs else { return false }
            if let u1 = lhs as? URL, let u2 = rhs as? URL { return u1 == u2 }
            if let s1 = lhs as? String, let s2 = rhs as? String { return s1 == s2 }
            return String(describing: lhs) == String(describing: rhs)
        }

        let result = NSMutableAttributedString()
        if let first = plainRuns.first {
            result.append(whitespace(plainString.substring(to: first.location), styledLike: 0, keepLink: false))
        }
        for (index, run) in richRuns.enumerated() {
            result.append(rich.attributedSubstring(from: run))
            let nextRich = index + 1 < richRuns.count ? richRuns[index + 1].location : richString.length
            let nextPlain = index + 1 < plainRuns.count ? plainRuns[index + 1].location : plainString.length
            let gap = NSRange(location: NSMaxRange(plainRuns[index]), length: nextPlain - NSMaxRange(plainRuns[index]))
            let keepLink: Bool
            if index + 1 < richRuns.count {
                let leftLink = rich.attribute(.link, at: NSMaxRange(run) - 1, effectiveRange: nil)
                let rightLink = rich.attribute(.link, at: richRuns[index + 1].location, effectiveRange: nil)
                keepLink = linksMatch(leftLink, rightLink)
            } else {
                keepLink = false
            }
            result.append(whitespace(plainString.substring(with: gap), styledLike: nextRich - 1, keepLink: keepLink))
        }
        return result
    }

    /// Ranges of non-whitespace runs in `string`, in UTF-16 space.
    private static func wordRuns(in string: NSString) -> [NSRange] {
        let whitespace = CharacterSet.whitespacesAndNewlines
        var runs: [NSRange] = []
        var offset = 0
        var start: Int?
        // Walk whole scalars, but retain UTF-16 offsets for attributed ranges.
        // A surrogate half is not a scalar and must never stall the scan.
        for scalar in (string as String).unicodeScalars {
            if whitespace.contains(scalar) {
                if let start { runs.append(NSRange(location: start, length: offset - start)) }
                start = nil
            } else if start == nil {
                start = offset
            }
            offset += scalar.utf16.count
        }
        if let start { runs.append(NSRange(location: start, length: offset - start)) }
        return runs
    }

    private static func readPlainText(from pasteboard: NSPasteboard) -> NSAttributedString? {
        guard let plain = pasteboard.string(forType: .string), !plain.isEmpty else { return nil }
        return NSAttributedString(string: plain, attributes: defaultTextAttributes())
    }

    private static func readImage(from pasteboard: NSPasteboard) -> NSImage? {
        for type in imageDataTypes {
            guard let data = pasteboard.data(forType: type),
                  let image = NSImage(data: data),
                  image.isValid, image.size.width > 0, image.size.height > 0 else { continue }
            return image
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           let url = urls.first, let image = NSImage(contentsOf: url), image.isValid {
            return image
        }
        return nil
    }

    private static var imageDataTypes: [NSPasteboard.PasteboardType] {
        [.png, NSPasteboard.PasteboardType(UTType.jpeg.identifier), .tiff, .pdf]
    }
}
