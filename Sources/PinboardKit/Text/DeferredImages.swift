import AppKit

/// An image whose pixels have to be resolved after the text around it exists.
///
/// Two producers tag attachments this way — `ClipboardReader` for `<img>` tags
/// (AppKit's HTML importer never resolves their content) and
/// `MarkdownRenderer` for `![alt](url)` — and `TextPinView` resolves them once
/// the pin has a window and a wrap width.
enum DeferredImages {
    /// The image's `src`/`url`: a `data:` URI, a `file:` URL or an `http(s)`
    /// URL. Relative URLs never resolve, so their alt text stands in.
    static let sourceAttribute = NSAttributedString.Key("Pinboard.DeferredImageSource")

    /// Text shown in place of the image when it cannot be loaded. Only
    /// producers that have alt text set it (Markdown); an HTML placeholder
    /// without one simply stays empty.
    static let altAttribute = NSAttributedString.Key("Pinboard.DeferredImageAlt")

    /// The bytes behind a `data:` URI or `file:` URL. Remote sources return
    /// nil; the caller fetches those asynchronously.
    static func localData(from source: String) -> Data? {
        if source.lowercased().hasPrefix("data:") { return dataURI(source) }
        guard let url = URL(string: source), url.isFileURL else { return nil }
        return try? Data(contentsOf: url)
    }

    /// `data:[<image/type>][;base64],<payload>`.
    static func dataURI(_ source: String) -> Data? {
        guard let comma = source.firstIndex(of: ",") else { return nil }
        let metadata = source[source.index(source.startIndex, offsetBy: 5)..<comma].lowercased()
        guard metadata.hasPrefix("image/") else { return nil }
        let payload = String(source[source.index(after: comma)...])
        if metadata.hasSuffix(";base64") {
            return Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
        }
        return payload.removingPercentEncoding.map { Data($0.utf8) }
    }
}
