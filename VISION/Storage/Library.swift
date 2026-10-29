import Foundation
import SwiftData

/// All library mutations in one place, so the UI never deletes or moves files directly.
@MainActor
enum Library {

    static func bootstrap(context: ModelContext, retentionDays: Int) {
        let count = (try? context.fetchCount(FetchDescriptor<Folder>())) ?? 0
        if count == 0 { createFolder(named: "My Vault", context: context) }
        purgeExpired(retentionDays: retentionDays, context: context)
    }

    // MARK: Folders

    @discardableResult
    static func createFolder(named name: String, context: ModelContext) -> Folder {
        let maxIndex = ((try? context.fetch(FetchDescriptor<Folder>())) ?? []).map(\.sortIndex).max() ?? -1
        let folder = Folder(name: name, sortIndex: maxIndex + 1)
        context.insert(folder)
        save(context)
        return folder
    }

    static func rename(_ folder: Folder, to name: String, context: ModelContext) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folder.name = trimmed
        save(context)
    }

    /// Deleting a folder never destroys media: its items go to the Recovery Bin.
    static func deleteFolder(_ folder: Folder, context: ModelContext) {
        moveToBin(folder.activeItems, context: context)
        context.delete(folder)
        save(context)
    }

    static func setCover(_ item: MediaItem, for folder: Folder, context: ModelContext) {
        folder.coverItemID = item.id
        save(context)
    }

    // MARK: Items

    static func toggleFavorite(_ item: MediaItem, context: ModelContext) {
        item.isFavorite.toggle()
        save(context)
    }

    static func move(_ items: [MediaItem], to folder: Folder, context: ModelContext) {
        for item in items { item.folder = folder }
        save(context)
    }

    static func moveToBin(_ items: [MediaItem], context: ModelContext) {
        let now = Date()
        for item in items {
            item.previousFolderID = item.folder?.id
            item.folder = nil
            item.deletedAt = now
        }
        save(context)
    }

    static func restore(_ items: [MediaItem], context: ModelContext) {
        let folders = ((try? context.fetch(FetchDescriptor<Folder>(sortBy: [SortDescriptor(\.sortIndex)])))) ?? []
        for item in items {
            let destination = folders.first { $0.id == item.previousFolderID }
                ?? folders.first
                ?? createFolder(named: "Restored", context: context)
            item.folder = destination
            item.deletedAt = nil
            item.previousFolderID = nil
        }
        save(context)
    }

    /// Removes the encrypted file (which carries its wrapped per-file key) and thumbnails.
    static func deleteForever(_ items: [MediaItem], context: ModelContext) {
        for item in items {
            VaultStore.shared.removeFiles(for: item.id)
            ThumbnailCache.shared.remove(item.id)
            context.delete(item)
        }
        save(context)
    }

    static func purgeExpired(retentionDays: Int, context: ModelContext) {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        let descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt != nil })
        let expired = ((try? context.fetch(descriptor)) ?? []).filter { ($0.deletedAt ?? .distantFuture) < cutoff }
        if !expired.isEmpty { deleteForever(expired, context: context) }
    }

    static func save(_ context: ModelContext) {
        do { try context.save() } catch { assertionFailure("Library save failed: \(error)") }
    }
}
