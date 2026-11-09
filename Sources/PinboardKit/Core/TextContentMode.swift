import Foundation

/// How a text pin interprets and edits its content.
///
/// `richText` is the original RTF-faithful mode. `plainText` drops all
/// formatting and shows the text in the default font. `markdown` keeps the raw
/// Markdown source as canonical content and renders it for display; the Edit
/// action opens that source.
enum TextContentMode: String, Codable, CaseIterable, Identifiable {
    case richText
    case markdown
    case plainText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .richText: return "Rich Text Format"
        case .markdown: return "GitHub Flavored Markdown"
        case .plainText: return "Plain Text"
        }
    }

    var menuTitle: String {
        switch self {
        case .richText: return "Rich Text"
        case .markdown: return "Markdown"
        case .plainText: return "Plain Text"
        }
    }

    var symbol: String {
        switch self {
        case .richText: return "doc.richtext"
        case .markdown: return "doc.text"
        case .plainText: return "doc.plaintext"
        }
    }
}
