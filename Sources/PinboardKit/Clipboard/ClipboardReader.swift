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
        [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor]
    }

    private static func nonEmpty(_ text: NSAttributedString?) -> NSAttributedString? {
        guard let text, text.length > 0 else { return nil }
        return text
    }

    private static func readRTF(from pasteboard: NSPasteboard) -> NSAttributedString? {
        if let data = pasteboard.data(forType: .rtfd),
           let text = NSAttributedString(rtfd: data, documentAttributes: nil) {
            return text
        }
        if let data = pasteboard.data(forType: .rtf),
           let text = NSAttributedString(rtf: data, documentAttributes: nil) {
            return text
        }
        return nil
    }

    private static func readHTML(from pasteboard: NSPasteboard) -> NSAttributedString? {
        guard let data = pasteboard.data(forType: .html),
              let rich = try? NSAttributedString(
                  data: data,
                  options: [.documentType: NSAttributedString.DocumentType.html,
                            .characterEncoding: String.Encoding.utf8.rawValue],
                  documentAttributes: nil
              ) else { return nil }
        // HTML whitespace collapsing eats the line breaks chat apps ship as
        // raw newlines inside normal-flow markup (they rely on CSS
        // `white-space: pre-wrap`, which the importer ignores). The plain-text
        // flavour on the same pasteboard still carries the true structure, so
        // when both describe the same words, transplant its whitespace back.
        guard let plain = pasteboard.string(forType: .string),
              let restored = restoreWhitespace(of: plain, into: rich) else { return rich }
        return restored
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

        func whitespace(_ string: String, styledLike position: Int) -> NSAttributedString {
            guard !string.isEmpty else { return NSAttributedString() }
            let attributes = rich.length > 0
                ? rich.attributes(at: min(max(position, 0), rich.length - 1), effectiveRange: nil)
                : defaultTextAttributes()
            return NSAttributedString(string: string, attributes: attributes)
        }

        let result = NSMutableAttributedString()
        if let first = plainRuns.first {
            result.append(whitespace(plainString.substring(to: first.location), styledLike: 0))
        }
        for (index, run) in richRuns.enumerated() {
            result.append(rich.attributedSubstring(from: run))
            let nextRich = index + 1 < richRuns.count ? richRuns[index + 1].location : richString.length
            let nextPlain = index + 1 < plainRuns.count ? plainRuns[index + 1].location : plainString.length
            let gap = NSRange(location: NSMaxRange(plainRuns[index]), length: nextPlain - NSMaxRange(plainRuns[index]))
            result.append(whitespace(plainString.substring(with: gap), styledLike: nextRich - 1))
        }
        return result
    }

    /// Ranges of non-whitespace runs in `string`, in UTF-16 space.
    private static func wordRuns(in string: NSString) -> [NSRange] {
        let whitespace = CharacterSet.whitespacesAndNewlines
        var runs: [NSRange] = []
        var index = 0
        while index < string.length {
            if let scalar = UnicodeScalar(string.character(at: index)), whitespace.contains(scalar) {
                index += 1
                continue
            }
            var end = index
            while end < string.length,
                  let scalar = UnicodeScalar(string.character(at: end)),
                  !whitespace.contains(scalar) { end += 1 }
            runs.append(NSRange(location: index, length: end - index))
            index = end
        }
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
