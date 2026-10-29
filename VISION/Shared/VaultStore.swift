import Foundation
import CryptoKit

enum ThumbnailSize: String, Sendable {
    case small = "s"   // 480 px — cards and grids
    case large = "l"   // 1280 px — hero, folder covers, viewer placeholder
}

/// Owns the on-disk layout of the vault. Only encrypted bytes live under `root`.
final class VaultStore: @unchecked Sendable {
    static let shared = VaultStore()

    let root: URL
    let mediaDirectory: URL
    let thumbnailDirectory: URL
    let stagingDirectory: URL

    private let keyLock = NSLock()
    private var cachedKey: SymmetricKey?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("Vault", isDirectory: true)
        mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        thumbnailDirectory = root.appendingPathComponent("thumbs", isDirectory: true)
        stagingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("VISIONStaging", isDirectory: true)
    }

    func prepareDirectories() {
        let fm = FileManager.default
        for directory in [mediaDirectory, thumbnailDirectory, stagingDirectory] {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        }
        // The master key is device-only, so an iCloud/iTunes copy of these files
        // could never be decrypted elsewhere. Excluding them saves the user's iCloud space.
        // Real backup arrives in Phase 2 (encrypted, with key recovery).
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var rootURL = root
        try? rootURL.setResourceValues(values)
        purgeStaging()
    }

    func masterKey() throws -> SymmetricKey {
        keyLock.lock()
        defer { keyLock.unlock() }
        if let key = cachedKey { return key }
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: mediaDirectory.path)) ?? []
        let key = try MasterKey.loadOrCreate(allowCreate: existing.isEmpty)
        cachedKey = key
        return key
    }

    func mediaURL(for id: UUID) -> URL {
        mediaDirectory.appendingPathComponent("\(id.uuidString).vsn")
    }

    func thumbnailURL(for id: UUID, size: ThumbnailSize) -> URL {
        thumbnailDirectory.appendingPathComponent("\(id.uuidString)-\(size.rawValue).vsn")
    }

    func makeStagingURL(pathExtension: String) -> URL {
        let url = stagingDirectory.appendingPathComponent(UUID().uuidString)
        return pathExtension.isEmpty ? url : url.appendingPathExtension(pathExtension)
    }

    func openFile(at url: URL) throws -> VaultFileReader {
        try VaultFileReader(url: url, masterKey: masterKey())
    }

    func openMedia(_ id: UUID) throws -> VaultFileReader {
        try openFile(at: mediaURL(for: id))
    }

    func removeFiles(for id: UUID) {
        let fm = FileManager.default
        try? fm.removeItem(at: mediaURL(for: id))
        try? fm.removeItem(at: thumbnailURL(for: id, size: .small))
        try? fm.removeItem(at: thumbnailURL(for: id, size: .large))
    }

    /// Plaintext only ever exists here, briefly, while importing from Photos.
    func purgeStaging() {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
    }

    func diskUsage() -> (media: Int64, thumbnails: Int64) {
        (directorySize(mediaDirectory), directorySize(thumbnailDirectory))
    }

    private func directorySize(_ url: URL) -> Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(Int64(0)) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
