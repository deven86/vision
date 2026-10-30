import Foundation
import CloudKit
import CryptoKit
import Network
import SwiftData
import Observation

enum MediaTransferError: LocalizedError {
    case notInCloud
    case integrity(Int)
    case missingPart(Int)
    case waitingForWiFi

    var errorDescription: String? {
        switch self {
        case .notInCloud: return "This item hasn't been backed up to iCloud from its other device yet."
        case .integrity(let part): return "A downloaded part failed its integrity check (part \(part + 1)). It will be downloaded again."
        case .missingPart(let part): return "Part \(part + 1) is missing in iCloud. Back it up again from the device that has it."
        case .waitingForWiFi: return "Waiting for Wi-Fi (Wi-Fi only is on in Settings)."
        }
    }
}

/// Moves the already-encrypted vault files to and from iCloud.
///
/// - Files are split into 50 MB parts, each its own CloudKit record with a SHA-256 checksum,
///   so an interrupted transfer resumes from the last finished part.
/// - Nothing is decrypted for upload: iCloud only ever receives VISION's ciphertext.
/// - Downloads are verified twice: per-part checksum, then full AES-GCM authentication of
///   every chunk before the file is placed into the vault.
@MainActor
@Observable
final class MediaTransfer {
    static let shared = MediaTransfer()
    static let partSize: Int64 = 50 * 1024 * 1024

    private(set) var pendingUploads = 0
    private(set) var activeTitle: String?
    private(set) var activeProgress: Double = 0
    private(set) var waitingForWiFi = false
    private(set) var lastError: String?
    private(set) var downloadProgress: [UUID: Double] = [:]

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var expensiveNetwork = false
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var downloads: [UUID: Task<Void, Error>] = [:]
    private static let pendingDeletesKey = "sync.pendingPartDeletes"

    private var database: CKDatabase { CloudConfig.container.privateCloudDatabase }

    func attach(context: ModelContext) {
        self.context = context
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor in
                self?.expensiveNetwork = expensive
                if !expensive { self?.kick() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "vision.network"))
        self.monitor = monitor
    }

    private var operationConfiguration: CKOperation.Configuration {
        let configuration = CKOperation.Configuration()
        configuration.allowsCellularAccess = !SyncSettings.wifiOnly
        configuration.qualityOfService = .utility
        configuration.timeoutIntervalForResource = 6 * 3600
        return configuration
    }

    private var blockedByNetwork: Bool { SyncSettings.wifiOnly && expensiveNetwork }

    // MARK: Background queue

    func kick() {
        guard !running, SyncSettings.mediaEnabled || SyncSettings.autoDownload,
              CloudSync.shared.isVaultKeyOK, let context else { return }
        waitingForWiFi = blockedByNetwork
        guard !blockedByNetwork else { return }
        running = true
        Task {
            await flushPendingDeletes()
            if SyncSettings.mediaEnabled { await uploadAll(context) }
            if SyncSettings.autoDownload { await downloadAll(context) }
            running = false
            activeTitle = nil
        }
    }

    private func uploadAll(_ context: ModelContext) async {
        let store = VaultStore.shared
        let candidates = ((try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.cloudMediaParts == 0 }))) ?? [])
            .filter { store.hasMedia($0.id) }
            .sorted { $0.byteSize < $1.byteSize }   // small items first: most of the library is safe sooner
        pendingUploads = candidates.count
        for item in candidates {
            guard SyncSettings.mediaEnabled, CloudSync.shared.isVaultKeyOK else { break }
            if blockedByNetwork { waitingForWiFi = true; break }
            do {
                try await upload(item)
                lastError = nil
            } catch {
                lastError = CloudSync.describe(error)
                break   // retried on the next sync
            }
            pendingUploads -= 1
        }
    }

    private func downloadAll(_ context: ModelContext) async {
        let store = VaultStore.shared
        let candidates = ((try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.cloudMediaParts > 0 && $0.deletedAt == nil }))) ?? [])
            .filter { !store.hasMedia($0.id) }
        for item in candidates {
            if blockedByNetwork { waitingForWiFi = true; break }
            do { try await ensureLocal(item) } catch { lastError = CloudSync.describe(error); break }
        }
    }

    // MARK: Upload

    private func upload(_ item: MediaItem) async throws {
        let id = item.id
        let source = VaultStore.shared.mediaURL(for: id)
        let size = Int64((try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0)
        let count = max(1, Int((size + Self.partSize - 1) / Self.partSize))
        let ids = (0..<count).map { Self.partID(id, $0) }
        activeTitle = item.title
        activeProgress = 0

        // Resume: skip parts already in iCloud.
        let existing = (try? await database.records(for: ids, desiredKeys: ["sha256"])) ?? [:]
        let configuration = operationConfiguration
        for index in 0..<count {
            if case .success = existing[ids[index]] {
                activeProgress = Double(index + 1) / Double(count)
                continue
            }
            if blockedByNetwork { throw MediaTransferError.waitingForWiFi }
            let (partURL, sha) = try await Task.detached(priority: .utility) {
                try Self.slice(source, index: index)
            }.value
            defer { try? FileManager.default.removeItem(at: partURL) }

            let record = CKRecord(recordType: CloudConfig.RecordType.part, recordID: ids[index])
            record["data"] = CKAsset(fileURL: partURL)
            record["sha256"] = sha
            record["index"] = index
            record["count"] = count
            record["itemID"] = id.uuidString
            let results = try await database.configuredWith(configuration: configuration) { db in
                try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            }
            if case .failure(let error) = results.saveResults[record.recordID] { throw error }
            activeProgress = Double(index + 1) / Double(count)
        }
        item.cloudMediaParts = count
        if let context { Library.save(context) }
    }

    nonisolated static func partID(_ id: UUID, _ index: Int) -> CKRecord.ID {
        CKRecord.ID(recordName: "part-\(id.uuidString)-\(index)", zoneID: CloudConfig.mediaZone)
    }

    /// Copies one 50 MB slice of the (already encrypted) vault file to a temp file and hashes it.
    nonisolated private static func slice(_ source: URL, index: Int) throws -> (URL, String) {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(Int64(index) * partSize))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VISIONUpload", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        var hasher = SHA256()
        var remaining = Int(partSize)
        while remaining > 0 {
            let piece = try autoreleasepool { try input.read(upToCount: min(4 * 1024 * 1024, remaining)) } ?? Data()
            if piece.isEmpty { break }
            hasher.update(data: piece)
            try output.write(contentsOf: piece)
            remaining -= piece.count
        }
        return (url, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    // MARK: Download

    /// Makes sure an item's media file is on this device, downloading it if needed.
    func ensureLocal(_ item: MediaItem) async throws {
        let id = item.id
        if VaultStore.shared.hasMedia(id) { return }
        guard item.cloudMediaParts > 0 else { throw MediaTransferError.notInCloud }
        if let running = downloads[id] { return try await running.value }
        let count = item.cloudMediaParts
        let task = Task { try await self.download(id, count: count) }
        downloads[id] = task
        defer { downloads[id] = nil; downloadProgress[id] = nil }
        try await task.value
    }

    private func download(_ id: UUID, count: Int) async throws {
        let store = VaultStore.shared
        let destination = store.mediaURL(for: id)
        let partial = destination.appendingPathExtension("download")
        let fm = FileManager.default
        if !fm.fileExists(atPath: partial.path) {
            fm.createFile(atPath: partial.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        }
        // Resume from the last complete part.
        let existingSize = Int64((try? fm.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0)
        let start = Int(existingSize / Self.partSize)
        let output = try FileHandle(forUpdating: partial)
        defer { try? output.close() }
        try output.truncate(atOffset: UInt64(Int64(start) * Self.partSize))
        try output.seekToEnd()

        let configuration = operationConfiguration
        for index in start..<count {
            if blockedByNetwork { throw MediaTransferError.waitingForWiFi }
            let recordID = Self.partID(id, index)
            let record: CKRecord
            do {
                record = try await database.configuredWith(configuration: configuration) { db in
                    try await db.record(for: recordID)
                }
            } catch let error as CKError where error.code == .unknownItem {
                throw MediaTransferError.missingPart(index)
            }
            guard let asset = (record["data"] as? CKAsset)?.fileURL else { throw MediaTransferError.missingPart(index) }
            let data = try Data(contentsOf: asset, options: .mappedIfSafe)
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard sha == record["sha256"] as? String else { throw MediaTransferError.integrity(index) }
            try output.write(contentsOf: data)
            downloadProgress[id] = Double(index + 1) / Double(count) * 0.95
        }
        try output.synchronize()

        // Full authentication of every encrypted chunk before the file enters the vault.
        try await Task.detached(priority: .userInitiated) {
            let reader = try store.openFile(at: partial)
            var offset: UInt64 = 0
            while offset < reader.plaintextLength {
                let read = try autoreleasepool { try reader.read(offset: offset, length: 8 * 1024 * 1024) }
                if read.isEmpty { break }
                offset += UInt64(read.count)
            }
        }.value
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: partial, to: destination)
        downloadProgress[id] = 1
    }

    // MARK: Delete

    /// Removes an item's media parts from iCloud (after permanent deletion).
    func deleteParts(itemID: UUID, count: Int) {
        guard count > 0 else { return }
        var pending = UserDefaults.standard.stringArray(forKey: Self.pendingDeletesKey) ?? []
        pending.append(contentsOf: (0..<count).map { Self.partID(itemID, $0).recordName })
        UserDefaults.standard.set(pending, forKey: Self.pendingDeletesKey)
        kick()
    }

    private func flushPendingDeletes() async {
        let names = UserDefaults.standard.stringArray(forKey: Self.pendingDeletesKey) ?? []
        guard !names.isEmpty else { return }
        let ids = names.map { CKRecord.ID(recordName: $0, zoneID: CloudConfig.mediaZone) }
        guard let results = try? await database.modifyRecords(saving: [], deleting: ids) else { return }
        let remaining = ids.filter { id in
            if case .failure(let error as CKError) = results.deleteResults[id], error.code != .unknownItem { return true }
            return false
        }.map(\.recordName)
        UserDefaults.standard.set(remaining, forKey: Self.pendingDeletesKey)
    }
}
