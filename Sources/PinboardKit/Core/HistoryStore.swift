import AppKit

/// Metadata for one pinned item. The heavy payloads (RTF, PNG, annotations)
/// live as sibling files in the record's own directory, so a damaged record
/// can only break itself.
struct HistoryRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: PinKind
    var createdAt: Date
    var updatedAt: Date

    /// Full plain text for text records — used for search and the list preview.
    /// For Markdown records it is the raw source.
    var text: String?
    var imagePixelSize: CGSize?
    var hasAnnotations: Bool
    /// nil for records written before text modes existed (treated as rich text).
    var textMode: TextContentMode? = nil

    var preview: String {
        switch kind {
        case .text:
            let snippet = (text ?? "").replacingOccurrences(of: "\n", with: " ")
            return snippet.isEmpty ? "Empty Text" : String(snippet.prefix(120))
        case .image:
            return hasAnnotations ? "Annotated Image" : "Image"
        }
    }
}

/// Local, file-based pin history. One directory per record under
/// `Application Support/Pinboard/History`:
///
///     <uuid>/record.json        metadata (loaded eagerly)
///     <uuid>/content.rtf[d]     rich text payload (raw Markdown source for
///                               Markdown records, stored as plain text RTF)
///     <uuid>/image.png          original image pixels
///     <uuid>/annotations.json   editable annotation state
///
/// Records keep the *latest* edited state — `upsert` rewrites the payload in
/// place instead of appending copies, and `updatedAt` is what retention is
/// measured against.
final class HistoryStore {
    static let shared = HistoryStore()

    let directory: URL
    private(set) var records: [HistoryRecord] = []
    var onChange: (() -> Void)?
    var onReadError: ((Error) -> Void)?

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pinboard/History", isDirectory: true)
        self.directory = base
        load()
    }

    // MARK: - Reading

    private func load() {
        let fileManager = FileManager.default
        guard let ids = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            records = []
            return
        }
        records = ids.compactMap { name in
            guard let id = UUID(uuidString: name) else { return nil }
            let file = directory.appendingPathComponent(name).appendingPathComponent("record.json")
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(HistoryRecord.self, from: data),
                  record.id == id else {
                return nil // a corrupt record loses only itself
            }
            return record
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func record(id: UUID) -> HistoryRecord? {
        records.first { $0.id == id }
    }

    /// Rebuilds the pin payload: content plus editable annotation data.
    func entry(id: UUID) -> PinContentState? {
        guard let record = record(id: id) else { return nil }
        let dir = recordDirectory(id)
        switch record.kind {
        case .text:
            let mode = record.textMode ?? .richText
            if let data = try? Data(contentsOf: dir.appendingPathComponent("content.rtfd")),
               let text = NSAttributedString(rtfd: data, documentAttributes: nil) {
                return PinContentState(content: .text(text), textMode: mode)
            }
            if let data = try? Data(contentsOf: dir.appendingPathComponent("content.rtf")),
               let text = NSAttributedString(rtf: data, documentAttributes: nil) {
                return PinContentState(content: .text(text), textMode: mode)
            }
            if let plain = record.text {
                return PinContentState(content: .text(NSAttributedString(string: plain, attributes: ClipboardReader.defaultTextAttributes())),
                                       textMode: mode)
            }
            return nil
        case .image:
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("image.png")),
                  let image = NSImage(data: data) else { return nil }
            do {
                let annotations = record.hasAnnotations
                    ? try Data(contentsOf: dir.appendingPathComponent("annotations.json")) : nil
                return PinContentState(content: .image(image), annotationData: annotations)
            } catch {
                NSLog("Pinboard history payload could not be read: %@", error.localizedDescription)
                onReadError?(error)
                return nil
            }
        }
    }

    /// Thumbnail source for the list. For images the original is returned at
    /// whatever scale AppKit wants; annotations are not baked in.
    func image(id: UUID) -> NSImage? {
        guard let data = try? Data(contentsOf: recordDirectory(id).appendingPathComponent("image.png")) else { return nil }
        return NSImage(data: data)
    }

    func filtered(query: String) -> [HistoryRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return records }
        return records.filter {
            ($0.text ?? "").localizedCaseInsensitiveContains(needle)
                || $0.preview.localizedCaseInsensitiveContains(needle)
        }
    }

    // MARK: - Writing

    /// Creates or replaces a record's payload. `createdAt` survives updates;
    /// `updatedAt` moves to now, which is what retention counts from. A failed
    /// save throws without publishing changes or destroying the previous payload.
    ///
    /// `textMode` describes text payloads. Omitting it keeps the record's
    /// existing mode, so a caller that does not care about modes never
    /// downgrades a Markdown record.
    @discardableResult
    func upsert(id: UUID = UUID(), content: PinContent, annotationData: Data? = nil,
                textMode: TextContentMode? = nil) throws -> UUID {
        var record = record(id: id) ?? HistoryRecord(
            id: id, kind: content.kind, createdAt: Date(), updatedAt: Date(),
            text: nil, imagePixelSize: nil, hasAnnotations: false
        )
        record.updatedAt = Date()
        record.kind = content.kind

        let fileManager = FileManager.default
        let staged = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staged) }

        switch content {
        case .text(let attributed):
            record.text = attributed.string
            record.textMode = textMode ?? record.textMode ?? .richText
            record.imagePixelSize = nil
            record.hasAnnotations = false
            // Never downgrade attachments to RTF or mislabel RTF as RTFD.
            if attributed.containsAttachments {
                guard let data = attributed.rtfdRepresentation() else { throw SaveError.encodingFailed(.text) }
                try data.write(to: staged.appendingPathComponent("content.rtfd"))
            } else {
                guard let data = attributed.rtfRepresentation() else { throw SaveError.encodingFailed(.text) }
                try data.write(to: staged.appendingPathComponent("content.rtf"))
            }
        case .image(let image):
            record.text = nil
            record.textMode = nil
            record.imagePixelSize = image.pixelSize
            record.hasAnnotations = annotationData != nil
            guard let png = image.pngData() else { throw SaveError.encodingFailed(.image) }
            try png.write(to: staged.appendingPathComponent("image.png"))
            if let annotationData {
                try annotationData.write(to: staged.appendingPathComponent("annotations.json"))
            }
        }

        try encoder.encode(record).write(to: staged.appendingPathComponent("record.json"))
        // Commit the whole record on the same volume. Readers see either the
        // previous record or the complete replacement, never mixed payloads.
        let destination = recordDirectory(id)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records.sort { $0.updatedAt > $1.updatedAt }
        onChange?()
        return id
    }

    private enum SaveError: LocalizedError {
        case encodingFailed(PinKind)

        var errorDescription: String? {
            switch self {
            case .encodingFailed(.text): return "The rich text could not be saved."
            case .encodingFailed(.image): return "The image could not be saved as PNG."
            }
        }
    }

    func delete(id: UUID) throws {
        try removeRecords { $0.id == id }
    }

    func clear(excluding liveIDs: Set<UUID> = []) throws {
        try removeRecords { !liveIDs.contains($0.id) }
    }

    /// Drops records untouched since `cutoff`. Records still attached to an
    /// open pin are always kept.
    func prune(olderThan cutoff: Date, excluding liveIDs: Set<UUID> = []) throws {
        try removeRecords { $0.updatedAt < cutoff && !liveIDs.contains($0.id) }
    }

    /// Publish only successful removals. A batch may partially succeed; failed
    /// records stay visible and the first error is reported after the batch.
    private func removeRecords(where shouldRemove: (HistoryRecord) -> Bool) throws {
        var removed: Set<UUID> = []
        var firstError: Error?
        for record in records where shouldRemove(record) {
            do {
                try FileManager.default.removeItem(at: recordDirectory(record.id))
                removed.insert(record.id)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                removed.insert(record.id)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if !removed.isEmpty {
            records.removeAll { removed.contains($0.id) }
            onChange?()
        }
        if let firstError { throw firstError }
    }

    private func recordDirectory(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }
}
