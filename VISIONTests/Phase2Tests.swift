import XCTest
import CryptoKit
@testable import VISION

final class RecoveryCodeTests: XCTestCase {
    func testRoundTripAndFormatting() {
        let code = RecoveryCode.generate()
        XCTAssertEqual(code.count, 32 + 7, "32 characters in 8 groups")
        XCTAssertEqual(code.split(separator: "-").count, 8)
        XCTAssertEqual(RecoveryCode.parse(code)?.count, RecoveryCode.byteCount)
        XCTAssertEqual(RecoveryCode.format(RecoveryCode.parse(code)!), code)
    }

    func testForgivingInput() {
        let code = RecoveryCode.generate()
        let messy = code.lowercased().replacingOccurrences(of: "-", with: " ")
        XCTAssertEqual(RecoveryCode.parse(messy), RecoveryCode.parse(code))
        let withO = code.replacingOccurrences(of: "0", with: "O")
        XCTAssertEqual(RecoveryCode.parse(withO), RecoveryCode.parse(code))
        XCTAssertNil(RecoveryCode.parse(String(code.dropLast())))
        XCTAssertNil(RecoveryCode.parse(code + "A"))
    }

    func testEscrow() throws {
        let master = SymmetricKey(size: .bits256)
        let code = RecoveryCode.parse(RecoveryCode.generate())!
        let escrow = try KeyEscrow.seal(master, code: code)
        let opened = try KeyEscrow.open(escrow, code: code)
        XCTAssertEqual(opened.withUnsafeBytes { Data($0) }, master.withUnsafeBytes { Data($0) })
        let wrong = RecoveryCode.parse(RecoveryCode.generate())!
        XCTAssertThrowsError(try KeyEscrow.open(escrow, code: wrong))
    }

    func testKeyIdentifierIsStableAndDistinct() {
        let a = SymmetricKey(size: .bits256), b = SymmetricKey(size: .bits256)
        XCTAssertEqual(MasterKey.identifier(of: a), MasterKey.identifier(of: a))
        XCTAssertNotEqual(MasterKey.identifier(of: a), MasterKey.identifier(of: b))
        XCTAssertEqual(MasterKey.identifier(of: a).count, 16)
    }
}

final class RewrapAndMetadataTests: XCTestCase {
    func testRewrapKeepsContentAndIsIdempotent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldKey = SymmetricKey(size: .bits256), newKey = SymmetricKey(size: .bits256)
        let plain = Data((0..<5000).map { _ in UInt8.random(in: 0...255) })
        let url = dir.appendingPathComponent("f.vsn")
        try VaultCrypto.encrypt(data: plain, to: url, masterKey: oldKey, chunkSize: 1024, protection: .none)

        XCTAssertTrue(try KeyRewrapper.rewrap(url, from: oldKey, to: newKey))
        XCTAssertFalse(try KeyRewrapper.rewrap(url, from: oldKey, to: newKey), "second pass is a no-op")
        XCTAssertEqual(try VaultFileReader(url: url, masterKey: newKey).readAll(), plain)
        XCTAssertThrowsError(try VaultFileReader(url: url, masterKey: oldKey))
    }

    func testMetadataEnvelope() throws {
        struct Sample: Codable, Equatable { var title: String; var date: Date }
        let master = SymmetricKey(size: .bits256)
        let value = Sample(title: "Holiday 2026", date: Date(timeIntervalSince1970: 1_800_000_000))
        let sealed = try MetadataCrypto.seal(value, master: master)
        XCTAssertNil(sealed.range(of: Data("Holiday".utf8)), "titles must not be readable in iCloud")
        XCTAssertEqual(try MetadataCrypto.open(Sample.self, from: sealed, master: master), value)
        XCTAssertThrowsError(try MetadataCrypto.open(Sample.self, from: sealed, master: SymmetricKey(size: .bits256)))
    }
}
