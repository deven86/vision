import Foundation
import SwiftData

// Models are written CloudKit-compatible from day one (no unique constraints,
// every property has a default, relationships optional) so Phase 2 sync
// does not need a destructive migration.

@Model
final class Folder {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    var sortIndex: Int = 0
    var coverItemID: UUID?
    // iCloud sync bookkeeping (Phase 2)
    var modifiedAt: Date = Date()
    var syncFingerprint: String = ""
    var cloudSystemFields: Data?

    @Relationship(deleteRule: .nullify, inverse: \MediaItem.folder)
    var items: [MediaItem]? = []

    init(name: String, sortIndex: Int) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.sortIndex = sortIndex
    }
}

@Model
final class MediaItem {
    var id: UUID = UUID()
    var kindRaw: String = MediaKind.photo.rawValue
    var title: String = ""
    var contentTypeID: String = "public.data"
    var byteSize: Int64 = 0
    var duration: Double = 0
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var importedAt: Date = Date()
    var isFavorite: Bool = false
    var watchPosition: Double = 0
    var lastPlayedAt: Date?
    var deletedAt: Date?
    var previousFolderID: UUID?
    var usesVLC: Bool = false
    // iCloud sync bookkeeping (Phase 2)
    var modifiedAt: Date = Date()
    var syncFingerprint: String = ""
    var cloudSystemFields: Data?
    /// Encrypted media parts stored in iCloud (0 = not backed up yet).
    var cloudMediaParts: Int = 0
    var folder: Folder?

    init(id: UUID, kind: MediaKind, title: String, contentTypeID: String,
         byteSize: Int64, duration: Double, pixelWidth: Int, pixelHeight: Int) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.title = title
        self.contentTypeID = contentTypeID
        self.byteSize = byteSize
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.importedAt = Date()
    }

    var kind: MediaKind { MediaKind(rawValue: kindRaw) ?? .photo }

    var progress: Double {
        duration > 0 ? min(1, max(0, watchPosition / duration)) : 0
    }

    var qualityLabel: String? {
        let longEdge = max(pixelWidth, pixelHeight), shortEdge = min(pixelWidth, pixelHeight)
        if longEdge >= 3800 || shortEdge >= 2100 { return "4K" }
        if shortEdge >= 1000 { return "Full HD" }
        if shortEdge >= 700 { return "HD" }
        return nil
    }
}

extension Folder {
    var activeItems: [MediaItem] {
        (items ?? []).filter { $0.deletedAt == nil }.sorted { $0.importedAt > $1.importedAt }
    }

    var coverItem: MediaItem? {
        let active = activeItems
        return active.first { $0.id == coverItemID } ?? active.first
    }
}
