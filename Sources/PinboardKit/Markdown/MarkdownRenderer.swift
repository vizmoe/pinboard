import AppKit
import cmark_gfm
import cmark_gfm_extensions

/// GFM syntax is parsed by cmark-gfm with its extensions explicitly enabled.
/// This renderer owns native AppKit presentation; raw HTML is displayed as
/// literal text. Copying and history always retain the original source.
enum MarkdownRenderer {
    struct Style {
        var baseFont: NSFont = TextDefaults.font
        var textColor: NSColor = .labelColor
        var secondaryTextColor: NSColor = .secondaryLabelColor
        var linkColor: NSColor = .linkColor
        var codeBackgroundColor: NSColor = NSColor.labelColor.withAlphaComponent(0.08)
        static let `default` = Style()
    }

    static let syntheticObliqueness: CGFloat = 0.2
    private static let registerExtensions: Void = cmark_gfm_core_extensions_ensure_registered()

    static func render(_ source: String, style: Style = .default) -> NSAttributedString {
        _ = registerExtensions
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { preconditionFailure("Cannot allocate Markdown parser") }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist", "autolink", "tagfilter"] {
            guard let ext = cmark_find_syntax_extension(name) else { preconditionFailure("Missing GFM extension: \(name)") }
            precondition(cmark_parser_attach_syntax_extension(parser, ext) != 0)
        }
        source.withCString { cmark_parser_feed(parser, $0, source.utf8.count) }
        guard let document = cmark_parser_finish(parser) else { preconditionFailure("Cannot parse Markdown") }
        defer { cmark_node_free(document) }
        let builder = Builder(style: style)
        for child in children(of: document) { builder.append(child) }
        return builder.finish()
    }

    private typealias Node = UnsafeMutablePointer<cmark_node>

    private static func children(of node: Node) -> [Node] {
        var result: [Node] = []
        var child = cmark_node_first_child(node)
        while let current = child {
            result.append(current)
            child = cmark_node_next(current)
        }
        return result
    }

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

    static func plainFont(_ base: NSFont) -> NSFont {
        NSFont(descriptor: base.fontDescriptor, size: base.pointSize) ?? base
    }

    private final class Builder {
        let style: Style
        let output = NSMutableAttributedString()

        init(style: Style) { self.style = style }

        private var attributes: [NSAttributedString.Key: Any] {
            [.font: plainFont(style.baseFont), .foregroundColor: style.textColor]
        }

        func finish() -> NSAttributedString {
            if output.length > 0, output.string.hasSuffix("\n"),
               (output.attribute(.paragraphStyle, at: output.length - 1, effectiveRange: nil)
                as? NSParagraphStyle)?.textBlocks.isEmpty != false {
                output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
            }
            return output
        }

        func append(_ node: Node, indent: CGFloat = 0, quoteDepth: Int = 0, marker: String = "") {
            let type = cmark_node_get_type(node)
            if type == CMARK_NODE_LIST {
                appendList(node, indent: indent, quoteDepth: quoteDepth)
                return
            }
            if type == CMARK_NODE_BLOCK_QUOTE {
                for child in children(of: node) { append(child, indent: indent, quoteDepth: quoteDepth + 1) }
                return
            }
            if String(cString: cmark_node_get_type_string(node)) == "table" {
                appendTable(node)
                return
            }

            var base = attributes
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            paragraph.paragraphSpacing = 7
            let content: NSMutableAttributedString
            switch type {
            case CMARK_NODE_HEADING:
                let level = Int(cmark_node_get_heading_level(node))
                let deltas: [CGFloat] = [7, 4, 2.5, 1, 0, -1]
                base[.font] = font(from: style.baseFont, bold: true, size: style.baseFont.pointSize + deltas[level - 1])
                content = inlineChildren(node, attributes: base)
                paragraph.paragraphSpacingBefore = level == 1 ? 10 : 8
                paragraph.paragraphSpacing = 5
            case CMARK_NODE_CODE_BLOCK:
                base[.font] = NSFont.monospacedSystemFont(ofSize: style.baseFont.pointSize * 0.95, weight: .regular)
                base[.backgroundColor] = style.codeBackgroundColor
                var text = String(cString: cmark_node_get_literal(node))
                if text.hasSuffix("\n") { text.removeLast() }
                content = NSMutableAttributedString(string: text, attributes: base)
                paragraph.paragraphSpacingBefore = 4
                paragraph.paragraphSpacing = 8
            case CMARK_NODE_THEMATIC_BREAK:
                base[.foregroundColor] = style.secondaryTextColor
                content = NSMutableAttributedString(string: String(repeating: "─", count: 32), attributes: base)
            case CMARK_NODE_HTML_BLOCK:
                content = NSMutableAttributedString(
                    string: String(cString: cmark_node_get_literal(node)).trimmingCharacters(in: .newlines), attributes: base)
            case CMARK_NODE_PARAGRAPH:
                content = inlineChildren(node, attributes: base)
            default:
                for child in children(of: node) { append(child, indent: indent, quoteDepth: quoteDepth, marker: marker) }
                return
            }

            let quote = String(repeating: "▎ ", count: quoteDepth)
            let prefix = quote + marker
            let assembled = NSMutableAttributedString(string: prefix, attributes: attributes)
            if !quote.isEmpty {
                assembled.addAttribute(.foregroundColor, value: style.secondaryTextColor,
                                       range: NSRange(location: 0, length: quote.utf16.count))
                for index in stride(from: content.length - 1, through: 0, by: -1) {
                    if (content.string as NSString).character(at: index) == 10 {
                        content.insert(NSAttributedString(string: quote, attributes: attributes), at: index + 1)
                    }
                }
            }
            assembled.append(content)
            paragraph.firstLineHeadIndent = indent + CGFloat(quoteDepth) * 14
            paragraph.headIndent = paragraph.firstLineHeadIndent
                + (prefix as NSString).size(withAttributes: attributes).width
            if type == CMARK_NODE_CODE_BLOCK {
                paragraph.firstLineHeadIndent += 10
                paragraph.headIndent += 10
            }
            assembled.append(NSAttributedString(string: "\n", attributes: base))
            assembled.addAttribute(.paragraphStyle, value: paragraph, range: assembled.fullRange)
            output.append(assembled)
        }

        private func appendList(_ list: Node, indent: CGFloat, quoteDepth: Int) {
            let ordered = cmark_node_get_list_type(list) == CMARK_ORDERED_LIST
            let start = Int(cmark_node_get_list_start(list))
            for (index, item) in children(of: list).enumerated() {
                let task = String(cString: cmark_node_get_type_string(item)) == "tasklist"
                let checked = task && cmark_gfm_extensions_get_tasklist_item_checked(item)
                let marker = task ? (checked ? "☑ " : "☐ ") : (ordered ? "\(start + index). " : "• ")
                let startOffset = output.length
                for (blockIndex, block) in children(of: item).enumerated() {
                    append(block, indent: indent + 18, quoteDepth: quoteDepth,
                           marker: blockIndex == 0 ? marker : "")
                }
                if checked, output.length > startOffset {
                    output.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                        range: NSRange(location: startOffset, length: output.length - startOffset))
                }
            }
        }

        /// Shared table blocks preserve empty cells, column alignment and
        /// wrapping without fixed tab stops drifting between rows.
        private func appendTable(_ table: Node) {
            let grid = NSTextTable()
            grid.numberOfColumns = Int(cmark_gfm_extensions_get_table_columns(table))
            grid.layoutAlgorithm = .automaticLayoutAlgorithm
            grid.collapsesBorders = true
            grid.setValue(100, type: .percentageValueType, for: .width)
            let alignments = cmark_gfm_extensions_get_table_alignments(table)!
            for (rowIndex, row) in children(of: table).enumerated() {
                for (column, cell) in children(of: row).enumerated() {
                    let block = NSTextTableBlock(table: grid, startingRow: rowIndex, rowSpan: 1,
                                                startingColumn: column, columnSpan: 1)
                    block.setWidth(5, type: .absoluteValueType, for: .padding)
                    block.setWidth(0.5, type: .absoluteValueType, for: .border)
                    block.setBorderColor(style.secondaryTextColor.withAlphaComponent(0.35))
                    if rowIndex == 0 { block.backgroundColor = style.codeBackgroundColor }
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.textBlocks = [block]
                    switch alignments[column] {
                    case 99: paragraph.alignment = .center // c
                    case 114: paragraph.alignment = .right // r
                    default: paragraph.alignment = .left
                    }
                    var base = attributes
                    if rowIndex == 0 { base[.font] = font(from: style.baseFont, bold: true) }
                    let content = inlineChildren(cell, attributes: base)
                    content.append(NSAttributedString(string: "\n", attributes: base))
                    content.addAttribute(.paragraphStyle, value: paragraph, range: content.fullRange)
                    output.append(content)
                }
            }
        }

        private func inlineChildren(_ node: Node, attributes: [NSAttributedString.Key: Any]) -> NSMutableAttributedString {
            let result = NSMutableAttributedString()
            for child in children(of: node) { result.append(inline(child, attributes: attributes)) }
            return result
        }

        private func inline(_ node: Node, attributes inherited: [NSAttributedString.Key: Any]) -> NSAttributedString {
            var attrs = inherited
            let type = cmark_node_get_type(node)
            switch type {
            case CMARK_NODE_TEXT, CMARK_NODE_HTML_INLINE:
                return NSAttributedString(string: String(cString: cmark_node_get_literal(node)), attributes: attrs)
            case CMARK_NODE_SOFTBREAK, CMARK_NODE_LINEBREAK:
                return NSAttributedString(string: "\n", attributes: attrs)
            case CMARK_NODE_CODE:
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: style.baseFont.pointSize * 0.95, weight: .regular)
                attrs[.backgroundColor] = style.codeBackgroundColor
                return NSAttributedString(string: String(cString: cmark_node_get_literal(node)), attributes: attrs)
            case CMARK_NODE_STRONG, CMARK_NODE_EMPH:
                let base = attrs[.font] as! NSFont
                let traits = base.fontDescriptor.symbolicTraits
                let italic = type == CMARK_NODE_EMPH || traits.contains(.italic) || attrs[.obliqueness] != nil
                let resolved = font(from: base, bold: type == CMARK_NODE_STRONG || traits.contains(.bold), italic: italic)
                attrs[.font] = resolved
                if italic, !resolved.fontDescriptor.symbolicTraits.contains(.italic) { attrs[.obliqueness] = syntheticObliqueness }
            case CMARK_NODE_LINK:
                attrs[.link] = String(cString: cmark_node_get_url(node))
                attrs[.foregroundColor] = style.linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case CMARK_NODE_IMAGE:
                let result = NSMutableAttributedString(attachment: NSTextAttachment())
                attrs[DeferredImages.sourceAttribute] = String(cString: cmark_node_get_url(node))
                let alt = inlineChildren(node, attributes: attributes).string
                if !alt.isEmpty { attrs[DeferredImages.altAttribute] = alt }
                result.addAttributes(attrs, range: result.fullRange)
                return result
            default:
                if String(cString: cmark_node_get_type_string(node)) == "strikethrough" {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            return inlineChildren(node, attributes: attrs)
        }
    }
}
