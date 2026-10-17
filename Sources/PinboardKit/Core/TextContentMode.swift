import Foundation

/// How a text pin interprets and edits its content.
///
/// `richText` is the original RTF-faithful mode. `plainText` drops all
/// formatting and shows the text in the default font. `markdown` keeps the raw
/// Markdown source as canonical content and renders it for display; clicking a
/// Markdown pin edits that source.
enum TextContentMode: String, Codable, CaseIterable, Identifiable {
    case richText
    case plainText
    case markdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .richText: return "Rich Text"
        case .plainText: return "Plain Text"
        case .markdown: return "Markdown"
        }
    }
}
