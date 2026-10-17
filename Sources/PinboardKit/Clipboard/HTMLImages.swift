import AppKit

/// Image references found in pasted HTML.
///
/// AppKit's HTML importer turns every `<img>` into an `NSTextAttachment`, but
/// it never resolves the pixels — not for `http(s):` URLs, not for `file:`
/// URLs, not even for `data:` URIs — so a message that only ships its chart as
/// markup would paste as an empty attachment. Pinboard parses the sources
/// itself and resolves them once the pin exists.
enum HTMLImages {
    /// `src` values of `<img>` tags in document order, HTML entities decoded.
    ///
    /// Entries are nil for images the page never shows (`display: none`,
    /// `visibility: hidden`, `opacity: 0`) — the position is kept so the
    /// result stays aligned with the attachments the importer creates, and
    /// the caller leaves those placeholders unresolved.
    static func sources(in html: Data) -> [String?] {
        guard let markup = String(data: html, encoding: .utf8)
                ?? String(data: html, encoding: .isoLatin1),
              markup.contains("<img") || markup.contains("<IMG") else {
            return []
        }
        let text = markup as NSString
        return tagPattern.matches(in: markup, range: NSRange(location: 0, length: text.length)).compactMap { match in
            let tag = text.substring(with: match.range(at: 0))
            guard let source = source(in: tag) else { return nil }
            return isInvisible(tag) ? nil : decodeEntities(source)
        }
    }

    /// The tag's `src`, unescaped; nil when the tag has none (the importer
    /// creates no attachment for those).
    private static func source(in tag: String) -> String? {
        let text = tag as NSString
        guard let match = sourcePattern.firstMatch(in: tag, range: NSRange(location: 0, length: text.length)) else {
            return nil
        }
        for group in 1...3 {
            let captured = match.range(at: group)
            guard captured.location != NSNotFound else { continue }
            return text.substring(with: captured)
        }
        return nil
    }

    private static let tagPattern = try! NSRegularExpression(pattern: "<img\\s[^>]*>", options: [.caseInsensitive])
    private static let sourcePattern = try! NSRegularExpression(
        pattern: "src\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))",
        options: [.caseInsensitive]
    )

    /// True when the tag's own style hides the image — chat and web apps ship
    /// loading placeholders this way (`opacity: 0` until the real picture
    /// arrives), and an importer that ignores CSS would otherwise pin them.
    static func isInvisible(_ tag: String) -> Bool {
        guard tag.contains("style") || tag.contains("STYLE") else { return false }
        return invisibleStyle.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) != nil
    }

    private static let invisibleStyle = try! NSRegularExpression(
        pattern: "display\\s*:\\s*none|visibility\\s*:\\s*hidden|opacity\\s*:\\s*(0+(\\.0*)?|\\.0+)\\s*[;\"']",
        options: [.caseInsensitive]
    )

    /// `&amp;` is decoded last so an escaped entity is not decoded twice.
    private static func decodeEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var result = string
        for (entity, replacement) in [
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&#34;", "\""),
            ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")
        ] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}
