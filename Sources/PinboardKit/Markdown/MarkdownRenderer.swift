import AppKit

/// Converts Markdown source into a display-only attributed string.
///
/// Foundation's parser (cmark) exposes the document structure as
/// `PresentationIntent`s attached to each run. This renderer walks those runs
/// and turns them into AppKit fonts, paragraph styles, list markers and quote
/// bars. The source string is never mutated: a Markdown pin keeps the raw text
/// as its canonical content and re-renders from it on demand.
///
/// The output is for display and measuring; it is not fed back into the
/// document. Copying a Markdown pin copies its source instead.
enum MarkdownRenderer {
    struct Style {
        var baseFont: NSFont = TextDefaults.font
        var textColor: NSColor = .labelColor
        var secondaryTextColor: NSColor = .secondaryLabelColor
        var linkColor: NSColor = .linkColor
        var codeBackgroundColor: NSColor = NSColor.labelColor.withAlphaComponent(0.08)

        static let `default` = Style()
    }

    /// Slant added when the base family has no italic face (e.g. PingFang SC),
    /// so emphasised runs stay visually distinct.
    static let syntheticObliqueness: CGFloat = 0.2

    /// Number of "─" glyphs used for `---` thematic breaks. Long enough to
    /// read as a rule at the pins' usual widths.
    private static let thematicBreakGlyphCount = 32

    static func render(_ source: String, style: Style = .default) -> NSAttributedString {
        guard !source.isEmpty else { return NSAttributedString() }
        let parsed: AttributedString
        do {
            parsed = try AttributedString(markdown: source, options: .init(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            ))
        } catch {
            // cmark only fails when it cannot read the input at all; showing it
            // as plain text beats showing nothing.
            return NSAttributedString(string: source, attributes: [
                .font: style.baseFont,
                .foregroundColor: style.textColor
            ])
        }
        let builder = Builder(style: style)
        for run in parsed.runs {
            builder.append(run, text: String(parsed[run.range].characters))
        }
        return builder.finish()
    }

    /// Returns `font` with the given traits, falling back gracefully: a family
    /// without an italic face keeps the traits it does have (PingFang SC, for
    /// example, has bold but no italic), and callers add synthetic
    /// `obliqueness` when italic could not be resolved.
    static func font(from base: NSFont, bold: Bool, italic: Bool = false, size: CGFloat? = nil) -> NSFont {
        let pointSize = size ?? base.pointSize
        func resolve(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont? {
            NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: pointSize)
        }
        if bold, italic, let font = resolve([.bold, .italic]) { return font }
        if bold, let font = resolve(.bold) { return font }
        if italic, let font = resolve(.italic) { return font }
        return NSFont(descriptor: base.fontDescriptor, size: pointSize) ?? base
    }

    /// The concrete face behind a (possibly dynamic) base font. Using one
    /// representation everywhere keeps AppKit from re-matching plain runs when
    /// they sit next to markers, tabs or bold/italic runs.
    static func plainFont(_ base: NSFont) -> NSFont {
        NSFont(descriptor: base.fontDescriptor, size: base.pointSize) ?? base
    }

    // MARK: - Builder

    private final class Builder {
        private let style: Style
        private let output = NSMutableAttributedString()
        private var block: Block?
        /// List items whose bullet/number was already emitted. A list item may
        /// contain several paragraphs; only the first one carries the marker.
        private var markedListItems: Set<Int> = []

        init(style: Style) {
            self.style = style
        }

        private var plainFont: NSFont { MarkdownRenderer.plainFont(style.baseFont) }

        func append(_ run: AttributedString.Runs.Run, text: String) {
            let components = run.presentationIntent?.components ?? []
            let key = Self.blockKey(components)
            if let current = block, current.key == key {
                current.append(run, components: components, text: text, style: style)
            } else {
                flush()
                let newBlock = Block(key: key, components: components)
                newBlock.append(run, components: components, text: text, style: style)
                block = newBlock
            }
        }

        func finish() -> NSAttributedString {
            flush()
            // Blocks are separated by newlines; the last one is not needed.
            if output.length > 0, output.string.hasSuffix("\n") {
                output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
            }
            return output
        }

        private static func blockKey(_ components: [PresentationIntent.IntentType]) -> Int? {
            // Table cells share a row: keeping one block per row lets the
            // cells be joined with tabs instead of one line per cell.
            if let row = components.first(where: { $0.kind.isTableRow }) {
                return row.identity
            }
            return components.first?.identity
        }

        private func flush() {
            guard let block else { return }
            defer { self.block = nil }
            let kind = BlockKind(components: block.components)
            var content = block.content

            switch kind {
            case .thematicBreak:
                content = NSMutableAttributedString(
                    string: String(repeating: "─", count: MarkdownRenderer.thematicBreakGlyphCount),
                    attributes: [.font: plainFont, .foregroundColor: style.secondaryTextColor]
                )
            case .codeBlock:
                stripTrailingNewlines(from: content)
                content.addAttribute(.backgroundColor, value: style.codeBackgroundColor,
                                     range: content.fullRange)
                content.addAttribute(.font, value: codeFont(bold: false), range: content.fullRange)
            case .listItem:
                applyTaskListItemMarker(to: content)
            default:
                break
            }
            guard content.length > 0 else { return }

            let prefix = NSMutableAttributedString()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2

            switch kind {
            case .heading(let level):
                content.addAttribute(.font, value: MarkdownRenderer.font(
                    from: style.baseFont, bold: true, size: style.baseFont.pointSize + Self.headingSizeDelta(level)
                ), range: content.fullRange)
                paragraph.paragraphSpacingBefore = level == 1 ? 10 : 8
                paragraph.paragraphSpacing = 5

            case .listItem(let depth, let ordered, let ordinal, let itemIdentity):
                let indent = CGFloat(depth) * 18
                if markedListItems.insert(itemIdentity).inserted {
                    let marker = ordered ? "\(ordinal). " : "• "
                    prefix.append(NSAttributedString(string: marker, attributes: [
                        .font: plainFont,
                        .foregroundColor: ordered ? style.textColor : style.secondaryTextColor
                    ]))
                    paragraph.headIndent = indent + Self.width(of: marker, font: plainFont)
                } else {
                    paragraph.headIndent = indent
                }
                paragraph.firstLineHeadIndent = indent
                paragraph.paragraphSpacing = 3

            case .blockQuote(let depth):
                let bar = String(repeating: "▎ ", count: depth)
                prefix.append(NSAttributedString(string: bar, attributes: [
                    .font: plainFont, .foregroundColor: style.secondaryTextColor
                ]))
                // Soft breaks inside a quote become newlines; give every line
                // its bar so the quote reads as one block.
                insertQuoteBars(into: content, bar: bar)
                let indent = CGFloat(depth) * 14
                paragraph.headIndent = indent
                paragraph.firstLineHeadIndent = indent
                paragraph.paragraphSpacing = 4

            case .codeBlock:
                paragraph.headIndent = 10
                paragraph.firstLineHeadIndent = 10
                paragraph.paragraphSpacingBefore = 4
                paragraph.paragraphSpacing = 8

            case .tableRow(let header):
                // Uniform fonts keep columns tidy and avoid AppKit re-matching
                // plain runs around the tab characters.
                let rowFont = header
                    ? MarkdownRenderer.font(from: style.baseFont, bold: true)
                    : plainFont
                content.addAttribute(.font, value: rowFont, range: content.fullRange)
                paragraph.defaultTabInterval = 96
                paragraph.paragraphSpacing = 2

            case .thematicBreak:
                paragraph.paragraphSpacingBefore = 4
                paragraph.paragraphSpacing = 4

            case .paragraph:
                paragraph.paragraphSpacing = 7
            }

            let assembled = NSMutableAttributedString(attributedString: prefix)
            assembled.append(content)
            assembled.addAttribute(.paragraphStyle, value: paragraph, range: assembled.fullRange)
            output.append(assembled)
            output.append(NSAttributedString(string: "\n", attributes: [
                .font: plainFont, .foregroundColor: style.textColor, .paragraphStyle: paragraph
            ]))
        }

        // MARK: - Inline pieces

        private func applyTaskListItemMarker(to content: NSMutableAttributedString) {
            let marker: String
            let isChecked: Bool
            switch content.string.prefix(4) {
            case "[ ] ": (marker, isChecked) = ("☐ ", false)
            case "[x] ", "[X] ": (marker, isChecked) = ("☑ ", true)
            default: return
            }
            let attributes = content.attributes(at: 0, effectiveRange: nil)
            content.replaceCharacters(in: NSRange(location: 0, length: 4),
                                      with: NSAttributedString(string: marker, attributes: attributes))
            if isChecked, content.length > 2 {
                let range = NSRange(location: 2, length: content.length - 2)
                content.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                content.addAttribute(.foregroundColor, value: style.secondaryTextColor, range: range)
            }
        }

        private func insertQuoteBars(into content: NSMutableAttributedString, bar: String) {
            guard content.length > 1 else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: plainFont, .foregroundColor: style.secondaryTextColor
            ]
            // Walk backwards so inserting never shifts offsets still to visit.
            for index in stride(from: content.length - 1, through: 0, by: -1) {
                let character = (content.string as NSString).substring(with: NSRange(location: index, length: 1))
                if character == "\n" {
                    content.insert(NSAttributedString(string: bar, attributes: attributes), at: index + 1)
                }
            }
        }

        private func stripTrailingNewlines(from content: NSMutableAttributedString) {
            while content.length > 0, content.string.hasSuffix("\n") {
                content.deleteCharacters(in: NSRange(location: content.length - 1, length: 1))
            }
        }

        private func codeFont(bold: Bool) -> NSFont {
            NSFont.monospacedSystemFont(ofSize: style.baseFont.pointSize * 0.95,
                                        weight: bold ? .semibold : .regular)
        }

        private static func headingSizeDelta(_ level: Int) -> CGFloat {
            switch level {
            case 1: return 7
            case 2: return 4
            case 3: return 2.5
            case 4: return 1
            case 5: return 0
            default: return -1
            }
        }

        private static func width(of string: String, font: NSFont) -> CGFloat {
            ceil((string as NSString).size(withAttributes: [.font: font]).width)
        }
    }

    // MARK: - Blocks

    private final class Block {
        let key: Int?
        let components: [PresentationIntent.IntentType]
        let content = NSMutableAttributedString()
        private var lastCellIdentity: Int?

        init(key: Int?, components: [PresentationIntent.IntentType]) {
            self.key = key
            self.components = components
        }

        func append(_ run: AttributedString.Runs.Run, components: [PresentationIntent.IntentType], text: String, style: Style) {
            let plainFont = MarkdownRenderer.plainFont(style.baseFont)
            if let cell = components.first(where: { $0.kind.isTableCell }) {
                if let lastCellIdentity, lastCellIdentity != cell.identity {
                    content.append(NSAttributedString(string: "\t", attributes: [
                        .font: plainFont, .foregroundColor: style.textColor
                    ]))
                }
                lastCellIdentity = cell.identity
            }
            let inline = run.inlinePresentationIntent ?? []
            if inline.contains(.softBreak) || inline.contains(.lineBreak) {
                content.append(NSAttributedString(string: "\n", attributes: [
                    .font: plainFont, .foregroundColor: style.textColor
                ]))
                return
            }
            content.append(NSAttributedString(string: text, attributes: Self.attributes(
                for: run, inline: inline, style: style
            )))
        }

        private static func attributes(
            for run: AttributedString.Runs.Run,
            inline: InlinePresentationIntent,
            style: Style
        ) -> [NSAttributedString.Key: Any] {
            let bold = inline.contains(.stronglyEmphasized)
            let italic = inline.contains(.emphasized)
            let isCode = inline.contains(.code)
            let font: NSFont
            if isCode {
                font = NSFont.monospacedSystemFont(ofSize: style.baseFont.pointSize * 0.95,
                                                   weight: bold ? .semibold : .regular)
            } else {
                font = MarkdownRenderer.font(from: style.baseFont, bold: bold, italic: italic)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: style.textColor
            ]
            if italic, !font.fontDescriptor.symbolicTraits.contains(.italic) {
                attributes[.obliqueness] = MarkdownRenderer.syntheticObliqueness
            }
            if isCode {
                attributes[.backgroundColor] = style.codeBackgroundColor
            }
            if inline.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.foregroundColor] = style.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.link] = link.absoluteString
            }
            return attributes
        }
    }

    private enum BlockKind: Equatable {
        case paragraph
        case heading(Int)
        case listItem(depth: Int, ordered: Bool, ordinal: Int, itemIdentity: Int)
        case blockQuote(depth: Int)
        case codeBlock
        case tableRow(header: Bool)
        case thematicBreak

        init(components: [PresentationIntent.IntentType]) {
            var listDepth = 0
            var isOrdered = false
            var sawListType = false
            var ordinal = 1
            var itemIdentity: Int?
            var quoteDepth = 0
            var headingLevel = 0
            var isCode = false
            var isThematicBreak = false
            var tableIsHeader: Bool?

            // Components are innermost-first; the first list/listItem seen is
            // the one this block belongs to.
            for component in components {
                switch component.kind {
                case .header(let level): headingLevel = level
                case .unorderedList:
                    listDepth += 1
                    if !sawListType { isOrdered = false; sawListType = true }
                case .orderedList:
                    listDepth += 1
                    if !sawListType { isOrdered = true; sawListType = true }
                case .listItem(let index):
                    if itemIdentity == nil { ordinal = index; itemIdentity = component.identity }
                case .blockQuote: quoteDepth += 1
                case .codeBlock: isCode = true
                case .thematicBreak: isThematicBreak = true
                case .tableHeaderRow: tableIsHeader = true
                case .tableRow: tableIsHeader = false
                default: break
                }
            }

            if isThematicBreak {
                self = .thematicBreak
            } else if isCode {
                self = .codeBlock
            } else if headingLevel > 0 {
                self = .heading(headingLevel)
            } else if let itemIdentity {
                self = .listItem(depth: listDepth, ordered: isOrdered, ordinal: ordinal, itemIdentity: itemIdentity)
            } else if quoteDepth > 0 {
                self = .blockQuote(depth: quoteDepth)
            } else if let tableIsHeader {
                self = .tableRow(header: tableIsHeader)
            } else {
                self = .paragraph
            }
        }
    }
}

extension PresentationIntent.Kind {
    fileprivate var isTableRow: Bool {
        switch self {
        case .tableRow, .tableHeaderRow: return true
        default: return false
        }
    }

    fileprivate var isTableCell: Bool {
        if case .tableCell = self { return true }
        return false
    }
}
