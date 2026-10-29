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

/// Minimal generic-password Keychain wrapper.
/// Items are `AfterFirstUnlockThisDeviceOnly`: never synced to iCloud Keychain and never
/// restored onto a different device, and still readable if the device locks mid-import.
enum Keychain {
    private static let service = "com.jondhale.vision.vault"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func set(_ data: Data, for account: String) throws {
        let base = baseQuery(account)
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
    static func read(_ account: String) throws -> Data? {
        var query = baseQuery(account)
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

    static func remove(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
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
enum MasterKey {
    private static let account = "master-key.v1"

    static func loadOrCreate(allowCreate: Bool) throws -> SymmetricKey {
        if let data = try Keychain.read(account), data.count == 32 {
            return SymmetricKey(data: data)
        }
        // Safety: never mint a fresh key when encrypted files already exist —
        // that would silently orphan the whole vault.
        guard allowCreate else { throw VaultKeyError.missingKeyForExistingVault }
        let key = SymmetricKey(size: .bits256)
        try Keychain.set(key.withUnsafeBytes { Data($0) }, for: account)
        return key
    }
}
