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
    var text: String?
    var imagePixelSize: CGSize?
    var hasAnnotations: Bool

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
///     <uuid>/content.rtf[d]     rich text payload
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
            let file = directory.appendingPathComponent(name).appendingPathComponent("record.json")
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(HistoryRecord.self, from: data) else {
                return nil // a corrupt record loses only itself
            }
            return record
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func record(id: UUID) -> HistoryRecord? {
        records.first { $0.id == id }
    }

    /// Rebuilds the pin payload: content plus editable annotation data.
    func entry(id: UUID) -> (content: PinContent, annotationData: Data?)? {
        guard let record = record(id: id) else { return nil }
        let dir = recordDirectory(id)
        switch record.kind {
        case .text:
            if let data = try? Data(contentsOf: dir.appendingPathComponent("content.rtfd")),
               let text = NSAttributedString(rtfd: data, documentAttributes: nil) {
                return (.text(text), nil)
            }
            if let data = try? Data(contentsOf: dir.appendingPathComponent("content.rtf")),
               let text = NSAttributedString(rtf: data, documentAttributes: nil) {
                return (.text(text), nil)
            }
            if let plain = record.text {
                return (.text(NSAttributedString(string: plain, attributes: ClipboardReader.defaultTextAttributes())), nil)
            }
            return nil
        case .image:
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("image.png")),
                  let image = NSImage(data: data) else { return nil }
            let annotations = try? Data(contentsOf: dir.appendingPathComponent("annotations.json"))
            return (.image(image), annotations)
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
    /// `updatedAt` moves to now, which is what retention counts from.
    @discardableResult
    func upsert(id: UUID = UUID(), content: PinContent, annotationData: Data? = nil) -> UUID {
        var record = record(id: id) ?? HistoryRecord(
            id: id, kind: content.kind, createdAt: Date(), updatedAt: Date(),
            text: nil, imagePixelSize: nil, hasAnnotations: false
        )
        record.updatedAt = Date()
        record.kind = content.kind

        let dir = recordDirectory(id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Drop stale payloads from a previous write before writing the new one.
        for stale in ["content.rtf", "content.rtfd", "image.png", "annotations.json"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(stale))
        }

        switch content {
        case .text(let attributed):
            record.text = attributed.string
            record.imagePixelSize = nil
            record.hasAnnotations = false
            let rtf = attributed.rtfdRepresentation() ?? attributed.rtfRepresentation()
            if let rtf {
                let name = attributed.containsAttachments ? "content.rtfd" : "content.rtf"
                try? rtf.write(to: dir.appendingPathComponent(name), options: .atomic)
            }
        case .image(let image):
            record.text = nil
            record.imagePixelSize = image.pixelSize
            record.hasAnnotations = annotationData != nil
            if let png = image.pngData() {
                try? png.write(to: dir.appendingPathComponent("image.png"), options: .atomic)
            }
            if let annotationData {
                try? annotationData.write(to: dir.appendingPathComponent("annotations.json"), options: .atomic)
            }
        }

        if let data = try? encoder.encode(record) {
            try? data.write(to: dir.appendingPathComponent("record.json"), options: .atomic)
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

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: recordDirectory(id))
        records.removeAll { $0.id == id }
        onChange?()
    }

    func clear(excluding liveIDs: Set<UUID> = []) {
        for record in records where !liveIDs.contains(record.id) {
            try? FileManager.default.removeItem(at: recordDirectory(record.id))
        }
        records.removeAll { !liveIDs.contains($0.id) }
        onChange?()
    }

    /// Drops records untouched since `cutoff`. Records still attached to an
    /// open pin are always kept.
    func prune(olderThan cutoff: Date, excluding liveIDs: Set<UUID> = []) {
        for record in records where record.updatedAt < cutoff && !liveIDs.contains(record.id) {
            try? FileManager.default.removeItem(at: recordDirectory(record.id))
        }
        let before = records.count
        records.removeAll { $0.updatedAt < cutoff && !liveIDs.contains($0.id) }
        if records.count != before { onChange?() }
    }

    private func recordDirectory(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }
}
