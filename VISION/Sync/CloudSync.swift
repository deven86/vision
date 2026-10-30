import Foundation
import CloudKit
import SwiftData
import Observation
import CryptoKit

enum CloudConfig {
    static let containerID = "iCloud.com.jondhale.vision"
    static let libraryZone = CKRecordZone.ID(zoneName: "VISIONLibrary", ownerName: CKCurrentUserDefaultName)
    static let mediaZone = CKRecordZone.ID(zoneName: "VISIONMedia", ownerName: CKCurrentUserDefaultName)
    static let vaultRecordID = CKRecord.ID(recordName: "vault-key", zoneID: libraryZone)

    enum RecordType {
        static let folder = "VFolder"
        static let item = "VItem"
        static let part = "VPart"
        static let vault = "VVault"
    }

    /// True only in builds signed with the iCloud entitlement (CloudKit crashes without it).
    static var isProvisioned: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "VISIONCloudKitEnabled") as? Bool) == true
    }

    static var container: CKContainer { CKContainer(identifier: containerID) }
}

extension SettingsKeys {
    static let syncLibrary = "sync.library"
    static let syncMedia = "sync.media"
    static let syncWiFiOnly = "sync.wifiOnly"
    static let syncAutoDownload = "sync.autoDownload"
}

enum SyncSettings {
    private static var defaults: UserDefaults { .standard }
    static var libraryEnabled: Bool { defaults.bool(forKey: SettingsKeys.syncLibrary) }
    static var mediaEnabled: Bool { libraryEnabled && defaults.bool(forKey: SettingsKeys.syncMedia) }
    static var wifiOnly: Bool { defaults.object(forKey: SettingsKeys.syncWiFiOnly) as? Bool ?? true }
    static var autoDownload: Bool { defaults.bool(forKey: SettingsKeys.syncAutoDownload) }
}

extension CKRecord {
    var encodedSystemFields: Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func restoring(_ systemFields: Data?, type: String, id: CKRecord.ID) -> CKRecord {
        if let systemFields, let coder = try? NSKeyedUnarchiver(forReadingFrom: systemFields) {
            coder.requiresSecureCoding = true
            defer { coder.finishDecoding() }
            if let record = CKRecord(coder: coder), record.recordID == id { return record }
        }
        return CKRecord(recordType: type, recordID: id)
    }
}

/// Library sync between the user's devices via their private iCloud database.
///
/// - Uses Apple's CKSyncEngine (retries, change tokens, account changes).
/// - Every record's content is encrypted with a key derived from the vault key before upload.
/// - Conflicts: last writer wins per folder / per item (whole record), by modification time.
/// - A "vault-key" marker record holds the vault key's fingerprint (never the key itself),
///   so a device with a DIFFERENT key never mixes its data in — it must join first.
@MainActor
@Observable
final class CloudSync: CKSyncEngineDelegate {
    static let shared = CloudSync()

    enum Status: Equatable {
        case off
        case notProvisioned
        case starting
        case idle
        case syncing
        case noAccount
        case keyMismatch
        case error(String)
    }

    private(set) var status: Status = .off
    private(set) var lastSync: Date?
    /// The iCloud vault's key fingerprint and (if a recovery code was made) its escrow.
    private(set) var remoteKeyID: String?
    private(set) var remoteEscrow: Data?

    var isVaultKeyOK: Bool { engine != nil && status != .keyMismatch && status != .noAccount }

    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var periodic: Task<Void, Never>?
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var unresolvedFolderLinks: [UUID: UUID] = [:]   // itemID → folderID

    private static var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloudSyncState.json")
    }
    private static let tombstonesKey = "sync.tombstones"
    private static let vaultFieldsKey = "sync.vaultSystemFields"

    // MARK: Lifecycle

    func start(context: ModelContext) async {
        self.context = context
        guard SyncSettings.libraryEnabled else { stop(); status = .off; return }
        guard CloudConfig.isProvisioned else { status = .notProvisioned; return }
        guard engine == nil else { await syncNow(); return }
        status = .starting

        do {
            guard try await CloudConfig.container.accountStatus() == .available else {
                status = .noAccount
                return
            }
        } catch {
            status = .noAccount
            return
        }

        let localKey: SymmetricKey
        do { localKey = try VaultStore.shared.masterKey() } catch { status = .error(error.localizedDescription); return }
        let localID = MasterKey.identifier(of: localKey)
        // Offer this key to the user's other devices (never overwrite a different one).
        if let synced = MasterKey.readSynced() {
            if MasterKey.identifier(of: synced) != localID { status = .keyMismatch }
        } else {
            try? MasterKey.storeSynced(localKey)
        }

        var configuration = CKSyncEngine.Configuration(database: CloudConfig.container.privateCloudDatabase,
                                                       stateSerialization: loadState(),
                                                       delegate: self)
        configuration.automaticallySync = false
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudConfig.libraryZone)),
                                                  .saveZone(CKRecordZone(zoneID: CloudConfig.mediaZone))])
        flushTombstones()

        await checkVaultMarker(localID: localID)
        await syncNow()

        periodic?.cancel()
        periodic = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(90))
                await self?.syncNow()
            }
        }
    }

    func stop() {
        periodic?.cancel()
        periodic = nil
        scheduled?.cancel()
        engine = nil
        if status != .notProvisioned { status = .off }
    }

    /// Debounced sync after local edits.
    func scheduleSync() {
        guard engine != nil else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard let engine, !syncing, status != .keyMismatch else { return }
        syncing = true
        defer { syncing = false }
        status = .syncing
        do {
            try await engine.fetchChanges(.init(scope: .zoneIDs([CloudConfig.libraryZone])))
            if status == .keyMismatch { return }
            scanLocalChanges()
            try await engine.sendChanges()
            lastSync = Date()
            if status == .syncing { status = .idle }
        } catch {
            if status == .syncing { status = .error(Self.describe(error)) }
        }
        MediaTransfer.shared.kick()
    }

    // MARK: Vault key marker

    private func checkVaultMarker(localID: String) async {
        do {
            let record = try await CloudConfig.container.privateCloudDatabase.record(for: CloudConfig.vaultRecordID)
            readVaultRecord(record)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            remoteKeyID = nil   // first device: the marker is created with the first upload
        } catch {
            return
        }
        if let remote = remoteKeyID {
            status = remote == localID ? .starting : .keyMismatch
        }
        if remoteKeyID == nil || remoteKeyID == localID {
            engine?.state.add(pendingRecordZoneChanges: [.saveRecord(CloudConfig.vaultRecordID)])
        }
    }

    private func readVaultRecord(_ record: CKRecord) {
        remoteKeyID = record["keyID"] as? String
        remoteEscrow = record["escrow"] as? Data
        UserDefaults.standard.set(record.encodedSystemFields, forKey: Self.vaultFieldsKey)
        if let remote = remoteKeyID, let local = try? VaultStore.shared.masterKey(),
           remote != MasterKey.identifier(of: local) {
            status = .keyMismatch
        }
    }

    /// Stores an escrow of the vault key sealed with the user's recovery code.
    func saveRecoveryEscrow(code: Data) async throws {
        let key = try VaultStore.shared.masterKey()
        remoteEscrow = try KeyEscrow.seal(key, code: code)
        remoteKeyID = MasterKey.identifier(of: key)
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(CloudConfig.vaultRecordID)])
        await syncNow()
    }

    /// Join the iCloud vault on this device: re-wrap local files to the iCloud key, then sync.
    func join(using newKey: SymmetricKey, progress: @escaping (Int, Int) -> Void) async throws -> KeyRewrapper.Report {
        guard let remote = remoteKeyID, MasterKey.identifier(of: newKey) == remote else {
            throw KeyEscrowError.badCode
        }
        let oldKey = try VaultStore.shared.masterKey()
        let report = await Task.detached(priority: .userInitiated) {
            KeyRewrapper.rewrapAll(from: oldKey, to: newKey) { done, total in
                Task { @MainActor in progress(done, total) }
            }
        }.value
        guard report.failed.isEmpty else { return report }   // keep the old key; nothing is lost
        try MasterKey.replaceLocal(with: newKey)
        VaultStore.shared.resetKeyCache()
        ThumbnailCache.shared.purge()
        // Everything local must be uploaded under the new key; fetch the iCloud library from scratch.
        if let context {
            for folder in (try? context.fetch(FetchDescriptor<Folder>())) ?? [] {
                folder.syncFingerprint = ""
                folder.cloudSystemFields = nil
            }
            for item in (try? context.fetch(FetchDescriptor<MediaItem>())) ?? [] {
                item.syncFingerprint = ""
                item.cloudSystemFields = nil
                item.cloudMediaParts = 0
            }
            try? context.save()
        }
        try? FileManager.default.removeItem(at: Self.stateURL)
        engine = nil
        status = .starting
        if let context { await start(context: context) }
        return report
    }

    // MARK: Local changes → pending uploads

    private func scanLocalChanges() {
        guard let context, let engine, status != .keyMismatch else { return }
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        for folder in (try? context.fetch(FetchDescriptor<Folder>())) ?? [] {
            let fingerprint = FolderPayload(folder).fingerprint
            guard fingerprint != folder.syncFingerprint else { continue }
            if !folder.syncFingerprint.isEmpty { folder.modifiedAt = Date() }
            folder.syncFingerprint = fingerprint
            pending.append(.saveRecord(Self.recordID(folder: folder.id)))
        }
        for item in (try? context.fetch(FetchDescriptor<MediaItem>())) ?? [] {
            let fingerprint = ItemPayload(item).fingerprint
            guard fingerprint != item.syncFingerprint else { continue }
            if !item.syncFingerprint.isEmpty { item.modifiedAt = Date() }
            item.syncFingerprint = fingerprint
            pending.append(.saveRecord(Self.recordID(item: item.id)))
        }
        if !pending.isEmpty {
            try? context.save()
            engine.state.add(pendingRecordZoneChanges: pending)
        }
    }

    /// Called by Library when items/folders are permanently deleted.
    func recordDeleted(itemIDs: [UUID] = [], folderIDs: [UUID] = []) {
        guard SyncSettings.libraryEnabled else { return }
        let names = itemIDs.map { Self.recordID(item: $0).recordName } + folderIDs.map { Self.recordID(folder: $0).recordName }
        var stored = UserDefaults.standard.stringArray(forKey: Self.tombstonesKey) ?? []
        stored.append(contentsOf: names)
        UserDefaults.standard.set(stored, forKey: Self.tombstonesKey)
        flushTombstones()
        scheduleSync()
    }

    private func flushTombstones() {
        guard let engine else { return }
        let names = UserDefaults.standard.stringArray(forKey: Self.tombstonesKey) ?? []
        guard !names.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: names.map {
            .deleteRecord(CKRecord.ID(recordName: $0, zoneID: CloudConfig.libraryZone))
        })
        UserDefaults.standard.removeObject(forKey: Self.tombstonesKey)   // the engine persists pending changes itself
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            saveState(update.stateSerialization)
        case .accountChange(let change):
            switch change.changeType {
            case .signIn: break
            case .signOut, .switchAccounts:
                try? FileManager.default.removeItem(at: Self.stateURL)
                stop()
                status = .noAccount
            @unknown default: break
            }
        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications { apply(modification.record) }
            for deletion in changes.deletions { applyDeletion(deletion.recordID) }
            resolveFolderLinks()
            try? context?.save()
        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords { storeSystemFields(record) }
            for failure in sent.failedRecordSaves { handleFailedSave(failure.record, error: failure.error) }
            try? context?.save()
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        let batch = Array(pending.prefix(50))
        var records: [CKRecord.ID: CKRecord] = [:]
        var dropped: [CKSyncEngine.PendingRecordZoneChange] = []
        for change in batch {
            guard case .saveRecord(let id) = change else { continue }
            if let record = buildRecord(id) { records[id] = record } else { dropped.append(change) }
        }
        if !dropped.isEmpty { syncEngine.state.remove(pendingRecordZoneChanges: dropped) }
        let sendable = batch.filter { change in !dropped.contains(change) }
        let built = records
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: sendable) { id in built[id] }
    }

    // MARK: Records

    static func recordID(folder id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "folder-\(id.uuidString)", zoneID: CloudConfig.libraryZone)
    }

    static func recordID(item id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "item-\(id.uuidString)", zoneID: CloudConfig.libraryZone)
    }

    private static func parse(_ id: CKRecord.ID) -> (kind: String, uuid: UUID)? {
        let name = id.recordName
        for prefix in ["folder-", "item-"] where name.hasPrefix(prefix) {
            if let uuid = UUID(uuidString: String(name.dropFirst(prefix.count))) { return (prefix, uuid) }
        }
        return nil
    }

    private func buildRecord(_ id: CKRecord.ID) -> CKRecord? {
        guard let key = try? VaultStore.shared.masterKey() else { return nil }
        let keyID = MasterKey.identifier(of: key)

        if id == CloudConfig.vaultRecordID {
            let record = CKRecord.restoring(UserDefaults.standard.data(forKey: Self.vaultFieldsKey),
                                            type: CloudConfig.RecordType.vault, id: id)
            record["keyID"] = keyID
            if let remoteEscrow { record["escrow"] = remoteEscrow }
            return record
        }
        guard let parsed = Self.parse(id) else { return nil }
        if parsed.kind == "folder-" {
            guard let folder = folder(parsed.uuid),
                  let payload = try? MetadataCrypto.seal(FolderPayload(folder), master: key) else { return nil }
            let record = CKRecord.restoring(folder.cloudSystemFields, type: CloudConfig.RecordType.folder, id: id)
            record["payload"] = payload
            record["keyID"] = keyID
            return record
        } else {
            guard let item = item(parsed.uuid),
                  let payload = try? MetadataCrypto.seal(ItemPayload(item), master: key) else { return nil }
            let firstUpload = item.cloudSystemFields == nil
            let record = CKRecord.restoring(item.cloudSystemFields, type: CloudConfig.RecordType.item, id: id)
            record["payload"] = payload
            record["keyID"] = keyID
            if firstUpload {
                // Thumbnails are already encrypted vault files; upload them as-is (only once).
                let store = VaultStore.shared
                for (field, size) in [("thumbS", ThumbnailSize.small), ("thumbL", ThumbnailSize.large)] {
                    let url = store.thumbnailURL(for: item.id, size: size)
                    if FileManager.default.fileExists(atPath: url.path) { record[field] = CKAsset(fileURL: url) }
                }
            }
            return record
        }
    }

    private func apply(_ record: CKRecord) {
        if record.recordID == CloudConfig.vaultRecordID {
            readVaultRecord(record)
            return
        }
        guard let context, let key = try? VaultStore.shared.masterKey(),
              let data = record["payload"] as? Data else { return }
        guard (record["keyID"] as? String) == MasterKey.identifier(of: key) else {
            status = .keyMismatch
            return
        }

        switch record.recordType {
        case CloudConfig.RecordType.folder:
            guard let payload = try? MetadataCrypto.open(FolderPayload.self, from: data, master: key) else { return }
            let folder = folder(payload.id) ?? {
                let created = Folder(name: payload.name, sortIndex: payload.sortIndex)
                created.id = payload.id
                context.insert(created)
                return created
            }()
            let hasLocalEdits = !folder.syncFingerprint.isEmpty
                && FolderPayload(folder).fingerprint != folder.syncFingerprint
            if !(hasLocalEdits && folder.modifiedAt > payload.modifiedAt) {
                payload.apply(to: folder)
                folder.syncFingerprint = FolderPayload(folder).fingerprint
            }
            folder.cloudSystemFields = record.encodedSystemFields

        case CloudConfig.RecordType.item:
            guard let payload = try? MetadataCrypto.open(ItemPayload.self, from: data, master: key) else { return }
            let existing = item(payload.id)
            let item = existing ?? {
                let created = MediaItem(id: payload.id, kind: MediaKind(rawValue: payload.kindRaw) ?? .photo,
                                        title: payload.title, contentTypeID: payload.contentTypeID,
                                        byteSize: payload.byteSize, duration: payload.duration,
                                        pixelWidth: payload.pixelWidth, pixelHeight: payload.pixelHeight)
                context.insert(created)
                return created
            }()
            let hasLocalEdits = existing != nil && !item.syncFingerprint.isEmpty
                && ItemPayload(item).fingerprint != item.syncFingerprint
            if !(hasLocalEdits && item.modifiedAt > payload.modifiedAt) {
                let folders = (try? context.fetch(FetchDescriptor<Folder>())) ?? []
                payload.apply(to: item, folders: folders)
                if let folderID = payload.folderID, item.folder == nil { unresolvedFolderLinks[item.id] = folderID }
                item.syncFingerprint = ItemPayload(item).fingerprint
            }
            item.cloudSystemFields = record.encodedSystemFields
            installThumbnails(from: record, for: payload.id)

        default:
            break
        }
    }

    private func installThumbnails(from record: CKRecord, for id: UUID) {
        let store = VaultStore.shared
        var changed = false
        for (field, size) in [("thumbS", ThumbnailSize.small), ("thumbL", ThumbnailSize.large)] {
            guard let source = (record[field] as? CKAsset)?.fileURL else { continue }
            let destination = store.thumbnailURL(for: id, size: size)
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.copyItem(at: source, to: destination)) != nil { changed = true }
        }
        if changed { ThumbnailCache.shared.remove(id) }
    }

    private func resolveFolderLinks() {
        guard let context, !unresolvedFolderLinks.isEmpty else { return }
        let folders = (try? context.fetch(FetchDescriptor<Folder>())) ?? []
        for (itemID, folderID) in unresolvedFolderLinks {
            guard let folder = folders.first(where: { $0.id == folderID }), let item = item(itemID) else { continue }
            item.folder = folder
            item.syncFingerprint = ItemPayload(item).fingerprint
            unresolvedFolderLinks[itemID] = nil
        }
    }

    private func applyDeletion(_ id: CKRecord.ID) {
        guard let context, let parsed = Self.parse(id) else { return }
        if parsed.kind == "folder-", let folder = folder(parsed.uuid) {
            context.delete(folder)
        } else if parsed.kind == "item-", let item = item(parsed.uuid) {
            VaultStore.shared.removeFiles(for: item.id)
            ThumbnailCache.shared.remove(item.id)
            context.delete(item)
        }
    }

    private func storeSystemFields(_ record: CKRecord) {
        if record.recordID == CloudConfig.vaultRecordID {
            UserDefaults.standard.set(record.encodedSystemFields, forKey: Self.vaultFieldsKey)
            return
        }
        guard let parsed = Self.parse(record.recordID) else { return }
        if parsed.kind == "folder-" { folder(parsed.uuid)?.cloudSystemFields = record.encodedSystemFields }
        else { item(parsed.uuid)?.cloudSystemFields = record.encodedSystemFields }
    }

    private func handleFailedSave(_ record: CKRecord, error: CKError) {
        guard let engine else { return }
        switch error.code {
        case .serverRecordChanged:
            guard let server = error.serverRecord else { return }
            if record.recordID == CloudConfig.vaultRecordID {
                readVaultRecord(server)
                if status != .keyMismatch { engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)]) }
                return
            }
            // Take the server's version unless ours is newer (apply() keeps newer local edits),
            // then retry our save on top of the server's change tag.
            apply(server)
            storeSystemFields(server)
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        case .zoneNotFound:
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: record.recordID.zoneID))])
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        case .unknownItem:
            if let parsed = Self.parse(record.recordID) {
                if parsed.kind == "folder-" { folder(parsed.uuid)?.cloudSystemFields = nil }
                else { item(parsed.uuid)?.cloudSystemFields = nil }
            }
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        case .quotaExceeded:
            status = .error("Your iCloud storage is full.")
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            break   // CKSyncEngine retries these automatically
        default:
            status = .error(Self.describe(error))
        }
    }

    private func folder(_ id: UUID) -> Folder? {
        try? context?.fetch(FetchDescriptor<Folder>(predicate: #Predicate { $0.id == id })).first
    }

    private func item(_ id: UUID) -> MediaItem? {
        try? context?.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.id == id })).first
    }

    // MARK: State persistence

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: Self.stateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveState(_ state: CKSyncEngine.State.Serialization) {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func describe(_ error: Error) -> String {
        guard let error = error as? CKError else { return error.localizedDescription }
        switch error.code {
        case .notAuthenticated: return "Sign in to iCloud in Settings to sync."
        case .quotaExceeded: return "Your iCloud storage is full."
        case .networkUnavailable, .networkFailure: return "No internet connection."
        default: return error.localizedDescription
        }
    }
}
