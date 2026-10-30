import Foundation
import CryptoKit

/// What iCloud stores about the library. Every record's content is one encrypted blob,
/// so Apple's servers see only random-looking bytes plus a record ID — never titles,
/// folder names, sizes or dates.
enum MetadataCrypto {
    static func key(from master: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data("VISION-metadata-v1".utf8), outputByteCount: 32)
    }

    static func seal<T: Encodable>(_ value: T, master: SymmetricKey) throws -> Data {
        let json = try JSONEncoder.sync.encode(value)
        guard let combined = try AES.GCM.seal(json, using: key(from: master)).combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return combined
    }

    static func open<T: Decodable>(_ type: T.Type, from data: Data, master: SymmetricKey) throws -> T {
        let box = try AES.GCM.SealedBox(combined: data)
        return try JSONDecoder.sync.decode(type, from: AES.GCM.open(box, using: key(from: master)))
    }
}

extension JSONEncoder {
    static var sync: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

extension JSONDecoder {
    static var sync: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

struct FolderPayload: Codable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
    var sortIndex: Int
    var coverItemID: UUID?
    var modifiedAt: Date

    init(_ folder: Folder) {
        id = folder.id
        name = folder.name
        createdAt = folder.createdAt
        sortIndex = folder.sortIndex
        coverItemID = folder.coverItemID
        modifiedAt = folder.modifiedAt
    }

    /// Content hash without the timestamp, used to detect local edits.
    var fingerprint: String {
        var copy = self
        copy.modifiedAt = .distantPast
        return SyncFingerprint.of(copy)
    }

    func apply(to folder: Folder) {
        folder.name = name
        folder.createdAt = createdAt
        folder.sortIndex = sortIndex
        folder.coverItemID = coverItemID
        folder.modifiedAt = modifiedAt
    }
}

struct ItemPayload: Codable, Equatable {
    var id: UUID
    var kindRaw: String
    var title: String
    var contentTypeID: String
    var byteSize: Int64
    var duration: Double
    var pixelWidth: Int
    var pixelHeight: Int
    var importedAt: Date
    var isFavorite: Bool
    var watchPosition: Double
    var lastPlayedAt: Date?
    var deletedAt: Date?
    var previousFolderID: UUID?
    var folderID: UUID?
    var usesVLC: Bool
    /// Number of encrypted media parts in iCloud (0 = media not backed up).
    var mediaParts: Int
    var modifiedAt: Date

    init(_ item: MediaItem) {
        id = item.id
        kindRaw = item.kindRaw
        title = item.title
        contentTypeID = item.contentTypeID
        byteSize = item.byteSize
        duration = item.duration
        pixelWidth = item.pixelWidth
        pixelHeight = item.pixelHeight
        importedAt = item.importedAt
        isFavorite = item.isFavorite
        // Coarse position so playing a video doesn't upload every second.
        watchPosition = (item.watchPosition / 5).rounded() * 5
        lastPlayedAt = item.lastPlayedAt
        deletedAt = item.deletedAt
        previousFolderID = item.previousFolderID
        folderID = item.folder?.id
        usesVLC = item.usesVLC
        mediaParts = item.cloudMediaParts
        modifiedAt = item.modifiedAt
    }

    var fingerprint: String {
        var copy = self
        copy.modifiedAt = .distantPast
        copy.lastPlayedAt = nil
        return SyncFingerprint.of(copy)
    }

    func apply(to item: MediaItem, folders: [Folder]) {
        item.kindRaw = kindRaw
        item.title = title
        item.contentTypeID = contentTypeID
        item.byteSize = byteSize
        item.duration = duration
        item.pixelWidth = pixelWidth
        item.pixelHeight = pixelHeight
        item.importedAt = importedAt
        item.isFavorite = isFavorite
        item.watchPosition = watchPosition
        item.lastPlayedAt = lastPlayedAt
        item.deletedAt = deletedAt
        item.previousFolderID = previousFolderID
        item.folder = folderID.flatMap { id in folders.first { $0.id == id } }
        item.usesVLC = usesVLC
        item.cloudMediaParts = mediaParts
        item.modifiedAt = modifiedAt
    }
}

struct EscrowPayload: Codable {
    var keyID: String
    var escrow: Data
    var createdAt: Date
}

enum SyncFingerprint {
    static func of<T: Encodable>(_ value: T) -> String {
        let data = (try? JSONEncoder.sync.encode(value)) ?? Data()
        return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
