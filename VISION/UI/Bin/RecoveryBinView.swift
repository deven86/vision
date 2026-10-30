import SwiftUI
import SwiftData

struct RecoveryBinView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<MediaItem> { $0.deletedAt != nil },
           sort: [SortDescriptor(\MediaItem.deletedAt, order: .reverse)])
    private var binned: [MediaItem]
    @AppStorage(SettingsKeys.binRetentionDays) private var retentionDays = 30

    @State private var confirmEmpty = false
    @State private var pendingDelete: MediaItem?

    var body: some View {
        Group {
            if binned.isEmpty {
                ContentUnavailableView("Bin is empty",
                                       systemImage: "trash",
                                       description: Text("Deleted items stay here for \(retentionDays) days, then are removed for good."))
            } else {
                List {
                    Section {
                        ForEach(binned) { item in row(item) }
                    } footer: {
                        Text("Swipe right to restore, left to delete permanently. Permanent deletion removes the encrypted file and its key from this device. If iCloud Backup is on, the iCloud copy is deleted too.")
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.background)
        .navigationTitle("Recovery Bin")
        .toolbar {
            if !binned.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Empty", role: .destructive) { confirmEmpty = true }
                }
            }
        }
        .confirmationDialog("Permanently delete \(binned.count) items?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) { Library.deleteForever(binned, context: context) }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog("Delete permanently?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDelete) { item in
            Button("Delete “\(item.title)”", role: .destructive) { Library.deleteForever([item], context: context) }
        } message: { _ in
            Text("This can't be undone.")
        }
    }

    private func row(_ item: MediaItem) -> some View {
        HStack(spacing: 12) {
            VaultThumbnail(id: item.id)
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(daysLeft(item)).font(.caption).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
        }
        .swipeActions(edge: .leading) {
            Button { Library.restore([item], context: context) } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { pendingDelete = item } label: {
                Label("Delete", systemImage: "trash.slash")
            }
        }
        .contextMenu {
            Button { Library.restore([item], context: context) } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) { pendingDelete = item } label: {
                Label("Delete Permanently", systemImage: "trash.slash")
            }
        }
    }

    private func daysLeft(_ item: MediaItem) -> String {
        guard let deleted = item.deletedAt else { return "" }
        let expiry = deleted.addingTimeInterval(Double(retentionDays) * 86_400)
        let days = max(0, Int(ceil(expiry.timeIntervalSinceNow / 86_400)))
        return days == 0 ? "Removed today" : "\(days) day\(days == 1 ? "" : "s") left"
    }
}
