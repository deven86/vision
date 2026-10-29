import XCTest
import CryptoKit
@testable import VISION

final class VaultCryptoTests: XCTestCase {
    private var directory: URL!
    private let key = SymmetricKey(size: .bits256)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func randomData(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private func encrypted(_ plain: Data, chunk: Int = 1024) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".vsn")
        try VaultCrypto.encrypt(data: plain, to: url, masterKey: key, chunkSize: chunk)
        return url
    }

    func testRoundTripAcrossChunkBoundaries() throws {
        for size in [0, 1, 1023, 1024, 1025, 4096, 5000] {
            let plain = randomData(size)
            let reader = try VaultFileReader(url: try encrypted(plain), masterKey: key)
            XCTAssertEqual(reader.plaintextLength, UInt64(size), "size \(size)")
            XCTAssertEqual(try reader.readAll(), plain, "size \(size)")
        }
    }

    func testRandomAccessReadsMatchPlaintext() throws {
        let plain = randomData(10_000)
        let reader = try VaultFileReader(url: try encrypted(plain), masterKey: key)
        for _ in 0..<300 {
            let offset = Int.random(in: 0..<plain.count)
            let length = Int.random(in: 1...3000)
            let expected = Data(plain[offset..<min(plain.count, offset + length)])
            XCTAssertEqual(try reader.read(offset: UInt64(offset), length: length), expected)
        }
        XCTAssertEqual(try reader.read(offset: 20_000, length: 10), Data())
    }

    func testStreamingFileEncryptionRoundTrips() throws {
        let plain = randomData(3 * 1024 * 1024 + 17)
        let source = directory.appendingPathComponent("source.bin")
        try plain.write(to: source)
        let destination = directory.appendingPathComponent("out.vsn")
        let length = try VaultCrypto.encryptFile(at: source, to: destination, masterKey: key)
        XCTAssertEqual(length, UInt64(plain.count))
        XCTAssertEqual(try VaultFileReader(url: destination, masterKey: key).readAll(), plain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path))
    }

    func testTamperingIsDetected() throws {
        let url = try encrypted(randomData(5000))
        var bytes = try Data(contentsOf: url)
        bytes[VaultFormat.headerSize + 2000] ^= 0xFF
        try bytes.write(to: url)
        let reader = try VaultFileReader(url: url, masterKey: key)
        XCTAssertThrowsError(try reader.readAll())
    }

    func testTruncationIsDetected() throws {
        let url = try encrypted(randomData(5000))
        let bytes = try Data(contentsOf: url)
        try bytes.prefix(bytes.count - 100).write(to: url)
        let reader = try VaultFileReader(url: url, masterKey: key)
        XCTAssertThrowsError(try reader.readAll())
    }

    func testWrongMasterKeyIsRejected() throws {
        let url = try encrypted(randomData(100))
        XCTAssertThrowsError(try VaultFileReader(url: url, masterKey: SymmetricKey(size: .bits256)))
    }

    func testCiphertextDoesNotContainPlaintext() throws {
        let marker = Data(repeating: 0x41, count: 4096)
        let bytes = try Data(contentsOf: try encrypted(marker))
        XCTAssertNil(bytes.range(of: Data(repeating: 0x41, count: 64)))
    }

    func testSameInputEncryptsDifferentlyEachTime() throws {
        let plain = randomData(2048)
        let a = try Data(contentsOf: try encrypted(plain))
        let b = try Data(contentsOf: try encrypted(plain))
        XCTAssertNotEqual(a, b, "Per-file keys must make every encryption unique")
    }
}

final class PINHasherTests: XCTestCase {
    func testVerify() {
        let record = PINHasher.makeRecord(pin: "482913", rounds: 1_000)
        XCTAssertTrue(PINHasher.verify("482913", against: record))
        XCTAssertFalse(PINHasher.verify("482914", against: record))
        XCTAssertFalse(PINHasher.verify("", against: record))
    }

    func testSaltMakesHashesUnique() {
        let a = PINHasher.makeRecord(pin: "111111", rounds: 1_000)
        let b = PINHasher.makeRecord(pin: "111111", rounds: 1_000)
        XCTAssertNotEqual(a.hash, b.hash)
    }

    func testPINValidation() {
        XCTAssertTrue(PINHasher.isValidPIN("012345"))
        XCTAssertFalse(PINHasher.isValidPIN("12345"))
        XCTAssertFalse(PINHasher.isValidPIN("12345a"))
        XCTAssertFalse(PINHasher.isValidPIN("١٢٣٤٥٦"))   // non-ASCII digits rejected
    }

    @MainActor
    func testLockoutSchedule() {
        XCTAssertEqual(AuthService.timeout(afterFailures: 4), 0)
        XCTAssertEqual(AuthService.timeout(afterFailures: 5), 30)
        XCTAssertEqual(AuthService.timeout(afterFailures: 7), 300)
        XCTAssertEqual(AuthService.timeout(afterFailures: 20), 900)
    }
}
