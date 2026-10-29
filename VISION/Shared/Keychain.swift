import Foundation
import Security
import CryptoKit

enum KeychainError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    var errorDescription: String? {
        if case .unexpectedStatus(let s) = self { return "Keychain error \(s)." }
        return nil
    }
}

/// Shared identifiers for the app and its Share Extension.
enum SharedConfig {
    static let appGroup = "group.com.jondhale.vision"

    /// "<TEAMID>.com.jondhale.vision.shared" — injected via Info.plist ($(AppIdentifierPrefix)),
    /// so the team ID never has to be hard-coded.
    static var keychainGroup: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "VISIONKeychainGroup") as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}

/// Minimal generic-password Keychain wrapper.
/// Items are `AfterFirstUnlockThisDeviceOnly`: never synced and never restored onto another
/// device, and still readable if the device locks mid-import or from the Share Extension.
enum Keychain {
    private static let service = "com.jondhale.vision.vault"

    private static func baseQuery(_ account: String, group: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    static func set(_ data: Data, for account: String, group: String? = nil) throws {
        let base = baseQuery(account, group: group)
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// Returns nil ONLY when the item truly does not exist. Any other failure throws,
    /// so callers never mistake a temporary error for "no key" and overwrite real data.
    static func read(_ account: String, group: String? = nil) throws -> Data? {
        var query = baseQuery(account, group: group)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    static func remove(_ account: String, group: String? = nil) {
        SecItemDelete(baseQuery(account, group: group) as CFDictionary)
    }
}

enum VaultKeyError: Error, LocalizedError {
    case missingKeyForExistingVault
    var errorDescription: String? {
        "The vault key is missing on this device, so existing items can't be opened. Nothing was overwritten."
    }
}

/// 256-bit master key (key-encryption key). Each media file has its own random key,
/// wrapped by this one and stored in the file header.
///
/// Lives in the shared keychain group so the Share Extension can encrypt incoming files.
/// Builds before the extension stored it in the app's private group; it is copied over once.
enum MasterKey {
    private static let account = "master-key.v1"

    static func loadOrCreate(allowCreate: Bool) throws -> SymmetricKey {
        let shared = SharedConfig.keychainGroup

        if let data = try Keychain.read(account, group: shared), data.count == 32 {
            return SymmetricKey(data: data)
        }
        // One-time migration from the app-private group (only possible from the main app).
        if shared != nil, let legacy = try Keychain.read(account, group: nil), legacy.count == 32 {
            try Keychain.set(legacy, for: account, group: shared)
            if let copied = try Keychain.read(account, group: shared), copied == legacy {
                return SymmetricKey(data: legacy)
            }
            return SymmetricKey(data: legacy)   // keep working even if the copy check failed
        }
        // Safety: never mint a fresh key when encrypted files already exist —
        // that would silently orphan the whole vault.
        guard allowCreate else { throw VaultKeyError.missingKeyForExistingVault }
        let key = SymmetricKey(size: .bits256)
        try Keychain.set(key.withUnsafeBytes { Data($0) }, for: account, group: shared)
        return key
    }
}
