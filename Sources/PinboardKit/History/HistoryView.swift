import AppKit
import SwiftUI

/// Observable model between `HistoryStore` and the SwiftUI list.
final class HistoryViewModel: ObservableObject {
    let store: HistoryStore
    let manager: PinWindowManager

    @Published private(set) var records: [HistoryRecord] = []
    @Published var searchText = ""
    @Published var selection: HistoryRecord.ID?

    var filtered: [HistoryRecord] { store.filtered(query: searchText) }

    init(store: HistoryStore = .shared, manager: PinWindowManager = .shared) {
        self.store = store
        self.manager = manager
        self.records = store.records
        store.onChange = { [weak self] in
            DispatchQueue.main.async { self?.records = self?.store.records ?? [] }
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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch entry.content {
        case .text(let attributed):
            pasteboard.writeObjects([attributed])
        case .image(let image):
            // Copy the composited result (crop + annotations), matching what
            // the user would get by copying the live pin.
            var output = image
            if let annotationData = entry.annotationData {
                let imagePin = ImagePinView(image: image)
                imagePin.restoreAnnotations(annotationData)
                output = imagePin.renderedImage()
            }
            pasteboard.writeObjects([output])
        }
    }

    func delete(_ id: HistoryRecord.ID) {
        store.delete(id: id)
        manager.detachHistoryRecord(id)
        if selection == id { selection = nil }
    }

    func clearAll() {
        store.clear(excluding: manager.liveHistoryRecordIDs)
        selection = nil
    }

    /// Full content for the detail pane.
    func detail(for record: HistoryRecord) -> PinContentState? {
        store.entry(id: record.id)
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel
    @State private var showClearConfirm = false

    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.filtered) { record in
                    row(record).tag(record.id)
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search history")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text("\(model.records.count) item\(model.records.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History…") { showClearConfirm = true }
                        .controlSize(.small)
                }
                .padding(8)
            }
        } detail: {
            if let record = model.record(for: model.selection) {
                detail(record)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "pin")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No Selection")
                        .font(.headline)
                    Text("Pick a history entry to preview it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 620, minHeight: 400)
        .alert("Clear all history?", isPresented: $showClearConfirm) {
            Button("Clear History", role: .destructive) { model.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every history record and its files. Pins currently open are not affected.")
        }
    }

    @ViewBuilder
    private func row(_ record: HistoryRecord) -> some View {
        HStack(spacing: 8) {
            thumbnail(record)
                .frame(width: 32, height: 32)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(record.preview).lineLimit(1)
                Text(Self.relativeDate.localizedString(for: record.updatedAt, relativeTo: Date()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func thumbnail(_ record: HistoryRecord) -> some View {
        if record.kind == .image, let image = model.store.image(id: record.id) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: record.kind == .text ? "doc.text" : "photo")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func detail(_ record: HistoryRecord) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                detailContent(record)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            Divider()
            HStack {
                Text(record.kind == .text ? "Text" : "Image")
                    .font(.caption).foregroundStyle(.secondary)
                Text("·")
                Text(record.updatedAt, style: .date)
                    .font(.caption).foregroundStyle(.secondary)
                Text(record.updatedAt, style: .time)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Pin Again") { model.pinAgain(record.id) }
                Button("Copy") { model.copy(record.id) }
                Button("Delete", role: .destructive) { model.delete(record.id) }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private func detailContent(_ record: HistoryRecord) -> some View {
        switch model.detail(for: record)?.content {
        case .text(let attributed):
            Text(AttributedString(attributed))
                .textSelection(.enabled)
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        case nil:
            Text("This record's content could not be read.")
                .foregroundStyle(.secondary)
        }
    }
}
