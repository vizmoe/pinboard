import Foundation

/// How a text pin interprets and edits its content.
///
/// `richText` is the original RTF-faithful mode. `markdown` keeps the raw
/// Markdown source as canonical content and renders it for display; clicking a
/// Markdown pin edits that source.
enum TextContentMode: String, Codable, CaseIterable, Identifiable {
    case richText
    case markdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .richText: return "Rich Text"
        case .markdown: return "Markdown"
        }
    }
}
