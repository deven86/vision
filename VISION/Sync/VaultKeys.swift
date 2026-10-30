import Foundation
import CryptoKit
import Security

/// Recovery code: 160 random bits shown as 32 characters in groups of 4,
/// e.g. `K7F2-9QX4-…`. Crockford Base32 alphabet (no I, L, O, U), so it is easy to read
/// back; O/I/L typed by mistake are accepted as 0/1/1. It never leaves the screen: only an
/// escrow of the vault key, sealed WITH this code, is stored in iCloud.
enum RecoveryCode {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let byteCount = 20

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        precondition(SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess)
        return format(Data(bytes))
    }

    static func format(_ data: Data) -> String {
        var bits = 0, value = 0, out: [Character] = []
        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 31]) }
        return stride(from: 0, to: out.count, by: 4)
            .map { String(out[$0..<min($0 + 4, out.count)]) }
            .joined(separator: "-")
    }

    /// Returns nil if the text isn't a complete, valid code.
    static func parse(_ text: String) -> Data? {
        let cleaned = text.uppercased().compactMap { ch -> Character? in
            switch ch {
            case "-", " ", "\n", "\t": return nil
            case "O": return "0"
            case "I", "L": return "1"
            default: return ch
            }
        }
        guard cleaned.count == 32 else { return nil }
        var bits = 0, value = 0, bytes: [UInt8] = []
        for ch in cleaned {
            guard let index = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
            value &= (1 << bits) - 1
        }
        return bytes.count == byteCount ? Data(bytes) : nil
    }
}

enum KeyEscrowError: LocalizedError {
    case badCode
    var errorDescription: String? { "That recovery code doesn't match this vault. Check it and try again." }
}

/// The vault key sealed with a key derived from the recovery code (HKDF-SHA256 → AES-256-GCM).
/// The code has 160 random bits, so no slow password hashing is needed.
enum KeyEscrow {
    private static func wrappingKey(_ code: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: code),
                               salt: Data("VISION-recovery-salt-v1".utf8),
                               info: Data("VISION-escrow-v1".utf8),
                               outputByteCount: 32)
    }

    static func seal(_ masterKey: SymmetricKey, code: Data) throws -> Data {
        let raw = masterKey.withUnsafeBytes { Data($0) }
        guard let combined = try AES.GCM.seal(raw, using: wrappingKey(code)).combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return combined
    }

    static func open(_ escrow: Data, code: Data) throws -> SymmetricKey {
        do {
            let box = try AES.GCM.SealedBox(combined: escrow)
            return SymmetricKey(data: try AES.GCM.open(box, using: wrappingKey(code)))
        } catch {
            throw KeyEscrowError.badCode
        }
    }
}

/// Moves this device's vault onto another vault key (to join the iCloud vault) WITHOUT
/// re-encrypting media: only the 60-byte wrapped per-file key in each file header changes.
/// Idempotent and crash-safe: a file already wrapped with the new key is skipped, and the
/// old key is kept until every file has been converted.
enum KeyRewrapper {
    struct Report { var converted = 0, alreadyDone = 0, failed: [String] = [] }

    static func rewrapAll(from oldKey: SymmetricKey, to newKey: SymmetricKey,
                          progress: (Int, Int) -> Void = { _, _ in }) -> Report {
        let files = VaultStore.shared.allEncryptedFiles()
        var report = Report()
        for (index, url) in files.enumerated() {
            do {
                if try rewrap(url, from: oldKey, to: newKey) { report.converted += 1 } else { report.alreadyDone += 1 }
            } catch {
                report.failed.append(url.lastPathComponent)
            }
            progress(index + 1, files.count)
        }
        return report
    }

    /// Returns true if the header was rewritten, false if it already used `newKey`.
    static func rewrap(_ url: URL, from oldKey: SymmetricKey, to newKey: SymmetricKey) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let headerData = try handle.read(upToCount: VaultFormat.headerSize) ?? Data()
        let header = try VaultHeader(data: headerData)
        if (try? VaultCrypto.unwrap(header.wrappedKey, with: newKey)) != nil { return false }
        let fileKey = try VaultCrypto.unwrap(header.wrappedKey, with: oldKey)
        let updated = VaultHeader(chunkSize: header.chunkSize,
                                  plaintextLength: header.plaintextLength,
                                  wrappedKey: try VaultCrypto.wrap(fileKey, with: newKey))
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: updated.encoded())
        try handle.synchronize()
        return true
    }
}
