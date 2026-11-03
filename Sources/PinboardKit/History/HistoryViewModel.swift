import AppKit

/// History actions shared by the menu bar list and detail page.
final class HistoryViewModel {
    let store: HistoryStore
    let manager: PinWindowManager

    private let pasteboard: NSPasteboard
    var onChange: (() -> Void)?
    var records: [HistoryRecord] { store.records }
    var searchText = ""
    var selection: HistoryRecord.ID?

    var filtered: [HistoryRecord] { store.filtered(query: searchText) }

    init(store: HistoryStore = .shared, manager: PinWindowManager = .shared,
         pasteboard: NSPasteboard = .general) {
        self.store = store
        self.manager = manager
        self.pasteboard = pasteboard
        store.onChange = { [weak self] in
            guard let self else { return }
            if let selection = self.selection, self.store.record(id: selection) == nil { self.selection = nil }
            self.onChange?()
        }
    }

    func record(for id: HistoryRecord.ID?) -> HistoryRecord? {
        records.first { $0.id == id }
    }

    func pinAgain(_ id: HistoryRecord.ID) {
        manager.repin(recordID: id)
    }

    func copy(_ id: HistoryRecord.ID) {
        guard let entry = store.entry(id: id) else { return }
        switch entry.content {
        case .text(let attributed):
            pasteboard.clearContents()
            // Plain Text and Markdown records hold no formatting; their data
            // is the source, matching the live pin.
            if entry.textMode == .markdown || entry.textMode == .plainText {
                pasteboard.setString(attributed.string, forType: .string)
            } else {
                pasteboard.writeObjects([attributed])
            }
        case .image:
            // Copy the composited result (crop + annotations), matching what
            // the user would get by copying the live pin.
            let output: NSImage
            do {
                guard let rendered = try renderedImage(from: entry) else { return }
                output = rendered
            } catch {
                manager.onHistoryError?(error)
                return
            }
            pasteboard.clearContents()
            pasteboard.writeObjects([output])
        }
    }

    func renderedImage(from state: PinContentState, fitting maxSize: CGSize? = nil) throws -> NSImage? {
        guard case .image(let image) = state.content else { return nil }
        if maxSize == nil, state.annotationData == nil { return image }
        let imagePin = ImagePinView(image: image)
        if let annotationData = state.annotationData {
            try imagePin.restoreAnnotations(annotationData)
        }
        if let maxSize {
            return imagePin.menuPreview(fitting: maxSize)
        }
        return imagePin.renderedImage()
    }

    func delete(_ id: HistoryRecord.ID) {
        do {
            try store.delete(id: id)
            manager.detachHistoryRecord(id)
            if selection == id { selection = nil }
        } catch {
            manager.onHistoryError?(error)
        }
    }

    func clearAll() {
        do {
            try store.clear(excluding: manager.liveHistoryRecordIDs)
        } catch {
            manager.onHistoryError?(error)
        }
        if let selection, self.store.record(id: selection) == nil { self.selection = nil }
    }

    /// Full content for the detail pane.
    func detail(for record: HistoryRecord) -> PinContentState? {
        store.entry(id: record.id)
    }
}
