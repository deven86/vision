import SwiftUI
import SwiftData
import CloudKit
import CryptoKit

/// Storage manager: what takes space, duplicates, and freeing space for items safely in iCloud.
struct StorageManagerView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<MediaItem> { $0.deletedAt == nil }, sort: \MediaItem.byteSize, order: .reverse)
    private var items: [MediaItem]

    @State private var duplicateGroups: [[MediaItem]] = []
    @State private var scanning = false
    @State private var scanProgress = (0, 0)
    @State private var scanned = false
    @State private var offloading = false
    @State private var message: String?
    @State private var confirmOffload = false

    private var store: VaultStore { .shared }
    private var localItems: [MediaItem] { items.filter { store.hasMedia($0.id) } }
    private var onDeviceBytes: Int64 { localItems.reduce(0) { $0 + $1.byteSize } }
    private var offloadable: [MediaItem] { localItems.filter { $0.cloudMediaParts > 0 && !$0.isFavorite } }

    var body: some View {
        List {
            Section("Overview") {
                LabeledContent("Items", value: "\(items.count)")
                LabeledContent("On this device", value: Format.bytes(onDeviceBytes))
                LabeledContent("Backed up to iCloud", value: "\(items.filter { $0.cloudMediaParts > 0 }.count) of \(items.count)")
                if items.count > localItems.count {
                    LabeledContent("In iCloud only", value: "\(items.count - localItems.count)")
                }
            }

            Section {
                if scanning {
                    ProgressView(value: Double(scanProgress.0), total: Double(max(scanProgress.1, 1))).tint(Theme.accent)
                    Text("Checking \(scanProgress.0) of \(scanProgress.1)…").font(.footnote)
                } else {
                    Button(scanned ? "Scan Again" : "Find Duplicates") { Task { await findDuplicates() } }
                }
                if scanned && duplicateGroups.isEmpty && !scanning {
                    Label("No duplicates found", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                ForEach(duplicateGroups, id: \.first!.id) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            ForEach(group.prefix(4)) { item in
                                VaultThumbnail(id: item.id)
                                    .frame(width: 64, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        Text("\(group.count) copies of “\(group.first?.title ?? "")” · \(Format.bytes(group.first?.byteSize ?? 0)) each")
                            .font(.footnote)
                        Button("Keep the oldest, move \(group.count - 1) to Bin") {
                            let sorted = group.sorted { $0.importedAt < $1.importedAt }
                            Library.moveToBin(Array(sorted.dropFirst()), context: context)
                            duplicateGroups.removeAll { $0.first?.id == group.first?.id }
                        }
                        .font(.footnote.weight(.semibold))
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Duplicates")
            } footer: {
                Text("Compares the actual file contents, not names. New imports are checked automatically and duplicates are skipped.")
            }

            if SyncSettings.mediaEnabled {
                Section {
                    Button(offloading ? "Freeing space…" : "Free Up \(Format.bytes(offloadable.reduce(0) { $0 + $1.byteSize }))") {
                        confirmOffload = true
                    }
                    .disabled(offloadable.isEmpty || offloading)
                } header: {
                    Text("Free up space")
                } footer: {
                    Text("Removes this device's copy of items already backed up to iCloud (favorites are kept). Thumbnails stay; an item downloads again when you open it. VISION checks every part is in iCloud before removing anything.")
                }
            }

            Section("Largest items") {
                ForEach(items.prefix(25)) { item in
                    HStack(spacing: 12) {
                        VaultThumbnail(id: item.id)
                            .frame(width: 72, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.subheadline).lineLimit(1)
                            Text(Format.bytes(item.byteSize) + (store.hasMedia(item.id) ? "" : " · iCloud only"))
                                .font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                    }
                    .swipeActions {
                        Button(role: .destructive) { Library.moveToBin([item], context: context) } label: {
                            Label("Bin", systemImage: "trash")
                        }
                    }
                }
            }

            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(Theme.accent) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Storage")
        .confirmationDialog("Remove local copies of \(offloadable.count) backed-up items?",
                            isPresented: $confirmOffload, titleVisibility: .visible) {
            Button("Free Up Space", role: .destructive) { Task { await offload() } }
        } message: {
            Text("They stay in your library and in iCloud, and download again when opened (Wi-Fi rules apply).")
        }
    }

    // MARK: Duplicates

    private func findDuplicates() async {
        scanning = true
        defer { scanning = false; scanned = true }
        let missing = items.filter { $0.contentHash == nil && store.hasMedia($0.id) }
        scanProgress = (0, missing.count)
        for (index, item) in missing.enumerated() {
            let id = item.id
            // Older items: hash the decrypted content once (streamed, nothing written to disk).
            if let hash = try? await Task.detached(priority: .userInitiated, operation: { try Self.plaintextHash(id) }).value {
                item.contentHash = hash
            }
            scanProgress = (index + 1, missing.count)
        }
        Library.save(context)
        duplicateGroups = Dictionary(grouping: items.filter { $0.contentHash != nil }, by: { $0.contentHash! })
            .values.filter { $0.count > 1 }
            .map { $0.sorted { $0.importedAt < $1.importedAt } }
            .sorted { ($0.first?.byteSize ?? 0) > ($1.first?.byteSize ?? 0) }
    }

    private nonisolated static func plaintextHash(_ id: UUID) throws -> String {
        let reader = try VaultStore.shared.openMedia(id)
        var hasher = SHA256()
        var offset: UInt64 = 0
        while offset < reader.plaintextLength {
            let piece = try autoreleasepool { try reader.read(offset: offset, length: 8 * 1024 * 1024) }
            if piece.isEmpty { break }
            hasher.update(data: piece)
            offset += UInt64(piece.count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Offload

    private func offload() async {
        offloading = true
        defer { offloading = false }
        let database = CloudConfig.container.privateCloudDatabase
        var freed: Int64 = 0, removed = 0, skipped = 0
        for item in offloadable {
            let ids = (0..<item.cloudMediaParts).map { MediaTransfer.partID(item.id, $0) }
            // Safety: only delete locally if EVERY part is confirmed present in iCloud.
            guard let results = try? await database.records(for: ids, desiredKeys: ["sha256"]),
                  ids.allSatisfy({ if case .success = results[$0] { return true } else { return false } }) else {
                skipped += 1
                continue
            }
            try? FileManager.default.removeItem(at: store.mediaURL(for: item.id))
            freed += item.byteSize
            removed += 1
        }
        message = "Freed \(Format.bytes(freed)) (\(removed) items)." + (skipped > 0 ? " \(skipped) were kept because their iCloud copy couldn't be confirmed." : "")
    }
}
