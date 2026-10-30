import Foundation
import CryptoKit

enum ThumbnailSize: String, Sendable {
    case small = "s"   // 480 px — cards and grids
    case large = "l"   // 1280 px — hero, folder covers, viewer placeholder
}

/// Owns the on-disk layout of the vault. Only encrypted bytes live under `root`.
///
/// The vault lives in the App Group container so the Share Extension can add files.
/// Vaults created by older builds (in the app's own Application Support) are moved there once.
final class VaultStore: @unchecked Sendable {
    static let shared = VaultStore()

    let root: URL
    let mediaDirectory: URL
    let thumbnailDirectory: URL
    let stagingDirectory: URL
    let inboxDirectory: URL

    private let legacyRoot: URL
    private let keyLock = NSLock()
    private var cachedKey: SymmetricKey?

    private init() {
        let fm = FileManager.default
        legacyRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vault", isDirectory: true)
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: SharedConfig.appGroup) {
            root = group.appendingPathComponent("Vault", isDirectory: true)
            inboxDirectory = group.appendingPathComponent("Inbox", isDirectory: true)
        } else {
            // App Group not provisioned (e.g. unsigned simulator test builds): stay app-private.
            root = legacyRoot
            inboxDirectory = legacyRoot.appendingPathComponent("Inbox", isDirectory: true)
        }
        // Per-process temp (app and extension each have their own), so neither can purge the other's in-flight files.
        stagingDirectory = fm.temporaryDirectory.appendingPathComponent("VISIONStaging", isDirectory: true)
        mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        thumbnailDirectory = root.appendingPathComponent("thumbs", isDirectory: true)
    }

    /// Main app only (the extension must never move the vault).
    func migrateLegacyVaultIfNeeded() {
        let fm = FileManager.default
        guard root != legacyRoot, fm.fileExists(atPath: legacyRoot.path) else { return }
        if !fm.fileExists(atPath: root.path) {
            try? fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.moveItem(at: legacyRoot, to: root)) != nil { return }
        }
        // Destination already exists: merge file by file, never overwrite.
        for sub in ["media", "thumbs"] {
            let from = legacyRoot.appendingPathComponent(sub), to = root.appendingPathComponent(sub)
            try? fm.createDirectory(at: to, withIntermediateDirectories: true)
            for file in (try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil)) ?? [] {
                let target = to.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: file, to: target) }
            }
        }
        let remaining = ["media", "thumbs"].flatMap {
            (try? fm.contentsOfDirectory(atPath: legacyRoot.appendingPathComponent($0).path)) ?? []
        }
        if remaining.isEmpty { try? fm.removeItem(at: legacyRoot) }
    }

    func prepareDirectories(purgeStaging: Bool = true) {
        let fm = FileManager.default
        for directory in [mediaDirectory, thumbnailDirectory, stagingDirectory, inboxDirectory] {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        }
        // The master key is device-only, so an iCloud/iTunes copy of these files
        // could never be decrypted elsewhere. Excluding them saves the user's iCloud space.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var rootURL = root
        try? rootURL.setResourceValues(values)
        if purgeStaging { self.purgeStaging() }
    }

    func masterKey() throws -> SymmetricKey {
        keyLock.lock()
        defer { keyLock.unlock() }
        if let key = cachedKey { return key }
        let fm = FileManager.default
        let existing = ((try? fm.contentsOfDirectory(atPath: mediaDirectory.path)) ?? [])
            + ((try? fm.contentsOfDirectory(atPath: legacyRoot.appendingPathComponent("media").path)) ?? [])
        let key = try MasterKey.loadOrCreate(allowCreate: existing.isEmpty)
        cachedKey = key
        return key
    }

    /// Drop the cached key (after the vault was re-keyed to join an iCloud vault).
    func resetKeyCache() {
        keyLock.lock()
        cachedKey = nil
        keyLock.unlock()
    }

    func hasMedia(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: mediaURL(for: id).path)
    }

    /// Every encrypted file whose header wraps a per-file key with the master key.
    func allEncryptedFiles() -> [URL] {
        [mediaDirectory, thumbnailDirectory, inboxDirectory].flatMap {
            ((try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "vsn" }
        }
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

    /// Plaintext only ever exists here, briefly, while importing.
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
