import AppKit

/// The payload shown by a pin window. Window management never inspects the
/// concrete representation beyond this enum.
enum PinContent {
    case text(NSAttributedString)
    case image(NSImage)

    var kind: PinKind {
        switch self {
        case .text: return .text
        case .image: return .image
        }
    }
}

enum PinKind: String, Codable {
    case text
    case image
}

extension NSAttributedString {
    var fullRange: NSRange { NSRange(location: 0, length: length) }

    /// RTF data for the whole string, used both for the pasteboard and for persistence.
    func rtfRepresentation() -> Data? {
        rtf(from: fullRange, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    func rtfdRepresentation() -> Data? {
        guard containsAttachments else { return nil }
        return rtfd(from: fullRange, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    }

    var containsAttachments: Bool {
        var found = false
        enumerateAttribute(.attachment, in: fullRange, options: []) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}
