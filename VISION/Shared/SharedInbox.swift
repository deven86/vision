import Foundation

/// Hand-off from the Share Extension to the app.
///
/// The extension cannot open the library database, so for every item it has already
/// encrypted into the vault it drops a small ENCRYPTED note (title, type, size, etc.)
/// into the shared Inbox. The app turns those notes into library items on next unlock.
/// The extension is write-only: it can add to the vault but never read or list it.
enum SharedInbox {

    static func deposit(_ result: IngestResult) throws {
        let store = VaultStore.shared
        let data = try JSONEncoder().encode(result)
        let url = store.inboxDirectory.appendingPathComponent("\(result.id.uuidString).vsn")
        try VaultCrypto.encrypt(data: data, to: url, masterKey: store.masterKey(), protection: .completeUnlessOpen)
    }

    struct Pending {
        let result: IngestResult
        let noteURL: URL
    }

    static func pending() -> [Pending] {
        let store = VaultStore.shared
        let urls = (try? FileManager.default.contentsOfDirectory(at: store.inboxDirectory,
                                                                 includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls
            .filter { $0.pathExtension == "vsn" }
            .compactMap { url -> Pending? in
                guard let reader = try? store.openFile(at: url),
                      let data = try? reader.readAll(),
                      let result = try? JSONDecoder().decode(IngestResult.self, from: data),
                      FileManager.default.fileExists(atPath: store.mediaURL(for: result.id).path)
                else { return nil }
                return Pending(result: result, noteURL: url)
            }
    }

    static func remove(_ pending: Pending) {
        try? FileManager.default.removeItem(at: pending.noteURL)
    }
}
