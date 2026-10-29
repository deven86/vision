import Foundation
import CommonCrypto
import Security

struct PINRecord: Codable, Sendable {
    let salt: Data
    let hash: Data
    let rounds: UInt32
}

/// PIN storage: PBKDF2-HMAC-SHA256, random 16-byte salt, 210k rounds.
/// The PIN itself is never stored.
enum PINHasher {
    static let defaultRounds: UInt32 = 210_000

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "System random generator failed")
        return Data(bytes)
    }

    static func derive(_ pin: String, salt: Data, rounds: UInt32) -> Data {
        var derived = [UInt8](repeating: 0, count: 32)
        let saltBytes = [UInt8](salt)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                          pin, pin.utf8.count,
                                          saltBytes, saltBytes.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                          rounds,
                                          &derived, derived.count)
        precondition(Int(status) == kCCSuccess, "PBKDF2 failed")
        return Data(derived)
    }

    static func makeRecord(pin: String, rounds: UInt32 = defaultRounds) -> PINRecord {
        let salt = randomBytes(16)
        return PINRecord(salt: salt, hash: derive(pin, salt: salt, rounds: rounds), rounds: rounds)
    }

    static func verify(_ pin: String, against record: PINRecord) -> Bool {
        constantTimeEqual(derive(pin, salt: record.salt, rounds: record.rounds), record.hash)
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    static func isValidPIN(_ pin: String) -> Bool {
        pin.count == 6 && pin.allSatisfy(\.isASCII) && pin.allSatisfy(\.isNumber)
    }
}
