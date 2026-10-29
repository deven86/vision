import Foundation
import CryptoKit

// MARK: - Errors

enum VaultCryptoError: Error, LocalizedError {
    case badHeader
    case unsupportedVersion(UInt8)
    case corruptChunk(UInt64)
    case outOfRange
    case io(String)

    var errorDescription: String? {
        switch self {
        case .badHeader: return "This file is not a VISION vault file."
        case .unsupportedVersion(let v): return "Unsupported vault file version \(v)."
        case .corruptChunk(let i): return "The file is damaged or was modified (block \(i))."
        case .outOfRange: return "Read past the end of the file."
        case .io(let message): return message
        }
    }
}

// MARK: - File format

/// VISION vault container ("VSN1").
///
/// Chunked AES-256-GCM so any byte range can be decrypted without touching the
/// rest of the file. This is what lets the video player seek instantly and play
/// smoothly without ever writing a decrypted copy to disk.
///
/// Layout (all integers little-endian):
///   [0..<4]    magic "VSN1"
///   [4]        version (1)
///   [5..<9]    chunkSize (UInt32) — plaintext bytes per chunk
///   [9..<17]   plaintextLength (UInt64)
///   [17..<77]  per-file key wrapped with the master key (AES-GCM combined: nonce 12 + ct 32 + tag 16)
///   [77..<128] reserved (zero)
///   [128...]   chunks: ciphertext (chunkSize, last one shorter) + tag (16)
///
/// Chunk nonce = 4 zero bytes + chunk index (UInt64 big-endian). Safe because every
/// file has its own random key, so a (key, nonce) pair is never reused.
/// AAD = chunk index + final-chunk flag, so blocks cannot be reordered, dropped or truncated undetected.
enum VaultFormat {
    static let magic: [UInt8] = Array("VSN1".utf8)
    static let version: UInt8 = 1
    static let headerSize = 128
    static let tagSize = 16
    static let wrappedKeySize = 60
    static let defaultChunkSize = 512 * 1024

    static func chunkCount(plaintextLength: UInt64, chunkSize: Int) -> UInt64 {
        let size = UInt64(chunkSize)
        return plaintextLength == 0 ? 1 : (plaintextLength + size - 1) / size
    }

    static func nonce(for index: UInt64) -> AES.GCM.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        for i in 0..<8 {
            bytes[4 + i] = UInt8(truncatingIfNeeded: index >> (8 * UInt64(7 - i)))
        }
        // 12 bytes is always a valid GCM nonce size.
        return try! AES.GCM.Nonce(data: bytes)
    }

    static func aad(index: UInt64, isFinal: Bool) -> Data {
        var data = Data("VSN1".utf8)
        for i in 0..<8 {
            data.append(UInt8(truncatingIfNeeded: index >> (8 * UInt64(7 - i))))
        }
        data.append(isFinal ? 1 : 0)
        return data
    }
}

struct VaultHeader {
    let chunkSize: Int
    let plaintextLength: UInt64
    let wrappedKey: Data

    init(chunkSize: Int, plaintextLength: UInt64, wrappedKey: Data) {
        self.chunkSize = chunkSize
        self.plaintextLength = plaintextLength
        self.wrappedKey = wrappedKey
    }

    init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= VaultFormat.headerSize, Array(bytes[0..<4]) == VaultFormat.magic else {
            throw VaultCryptoError.badHeader
        }
        guard bytes[4] == VaultFormat.version else { throw VaultCryptoError.unsupportedVersion(bytes[4]) }
        let size = Int(Self.le32(bytes, at: 5))
        guard size > 0, size <= 16 * 1024 * 1024 else { throw VaultCryptoError.badHeader }
        chunkSize = size
        plaintextLength = Self.le64(bytes, at: 9)
        wrappedKey = Data(bytes[17..<(17 + VaultFormat.wrappedKeySize)])
    }

    func encoded() -> Data {
        var data = Data(VaultFormat.magic)
        data.append(VaultFormat.version)
        withUnsafeBytes(of: UInt32(chunkSize).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: plaintextLength.littleEndian) { data.append(contentsOf: $0) }
        data.append(wrappedKey)
        data.append(Data(count: VaultFormat.headerSize - data.count))
        return data
    }

    private static func le32(_ b: [UInt8], at o: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { acc, i in acc | (UInt32(b[o + i]) << UInt32(8 * i)) }
    }

    private static func le64(_ b: [UInt8], at o: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { acc, i in acc | (UInt64(b[o + i]) << UInt64(8 * i)) }
    }
}

// MARK: - Encryption

enum VaultCrypto {

    /// Streams a file into an encrypted vault file. Memory use stays at ~one chunk,
    /// so multi-GB videos import without spikes.
    @discardableResult
    static func encryptFile(at source: URL,
                            to destination: URL,
                            masterKey: SymmetricKey,
                            chunkSize: Int = VaultFormat.defaultChunkSize,
                            protection: FileProtectionType = .completeUnlessOpen) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let length = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        try write(length: length, to: destination, masterKey: masterKey, chunkSize: chunkSize, protection: protection) { count in
            var buffer = Data()
            buffer.reserveCapacity(count)
            while buffer.count < count {
                guard let part = try input.read(upToCount: count - buffer.count), !part.isEmpty else { break }
                buffer.append(part)
            }
            return buffer
        }
        return length
    }

    /// Encrypts in-memory data (thumbnails, small files).
    static func encrypt(data: Data,
                        to destination: URL,
                        masterKey: SymmetricKey,
                        chunkSize: Int = VaultFormat.defaultChunkSize,
                        protection: FileProtectionType = .complete) throws {
        var cursor = data.startIndex
        try write(length: UInt64(data.count), to: destination, masterKey: masterKey, chunkSize: chunkSize, protection: protection) { count in
            let end = min(cursor + count, data.endIndex)
            defer { cursor = end }
            return data.subdata(in: cursor..<end)
        }
    }

    static func wrap(_ fileKey: SymmetricKey, with masterKey: SymmetricKey) throws -> Data {
        let raw = fileKey.withUnsafeBytes { Data($0) }
        guard let combined = try AES.GCM.seal(raw, using: masterKey).combined,
              combined.count == VaultFormat.wrappedKeySize else {
            throw VaultCryptoError.io("Could not protect the file key.")
        }
        return combined
    }

    static func unwrap(_ wrapped: Data, with masterKey: SymmetricKey) throws -> SymmetricKey {
        let box = try AES.GCM.SealedBox(combined: wrapped)
        return SymmetricKey(data: try AES.GCM.open(box, using: masterKey))
    }

    private static func write(length: UInt64,
                              to destination: URL,
                              masterKey: SymmetricKey,
                              chunkSize: Int,
                              protection: FileProtectionType,
                              read: (Int) throws -> Data) throws {
        precondition(chunkSize > 0, "chunkSize must be positive")
        let fileKey = SymmetricKey(size: .bits256)
        let header = VaultHeader(chunkSize: chunkSize,
                                 plaintextLength: length,
                                 wrappedKey: try wrap(fileKey, with: masterKey))
        let fm = FileManager.default
        let partial = destination.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        guard fm.createFile(atPath: partial.path, contents: nil, attributes: [.protectionKey: protection]) else {
            throw VaultCryptoError.io("Could not create a file in the vault.")
        }

        do {
            let out = try FileHandle(forWritingTo: partial)
            defer { try? out.close() }
            try out.write(contentsOf: header.encoded())

            let count = VaultFormat.chunkCount(plaintextLength: length, chunkSize: chunkSize)
            for index in 0..<count {
                try autoreleasepool {
                    let isFinal = index == count - 1
                    let expected = isFinal ? Int(length - index * UInt64(chunkSize)) : chunkSize
                    let plain = try read(expected)
                    guard plain.count == expected else {
                        throw VaultCryptoError.io("The source file changed while it was being imported.")
                    }
                    let box = try AES.GCM.seal(plain,
                                               using: fileKey,
                                               nonce: VaultFormat.nonce(for: index),
                                               authenticating: VaultFormat.aad(index: index, isFinal: isFinal))
                    try out.write(contentsOf: box.ciphertext)
                    try out.write(contentsOf: box.tag)
                }
            }
            try out.synchronize()
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }

        try? fm.removeItem(at: destination)
        try fm.moveItem(at: partial, to: destination)
    }
}

// MARK: - Random-access decryption

/// Thread-safe random-access reader. Keeps a small LRU of decrypted chunks so the
/// player's overlapping range requests never decrypt the same block twice.
final class VaultFileReader: @unchecked Sendable {
    let plaintextLength: UInt64
    let chunkSize: Int

    private let handle: FileHandle
    private let fileKey: SymmetricKey
    private let chunkCount: UInt64
    private let lock = NSLock()
    private var cache: [UInt64: Data] = [:]
    private var recency: [UInt64] = []
    private let cacheLimit = 12

    init(url: URL, masterKey: SymmetricKey) throws {
        handle = try FileHandle(forReadingFrom: url)
        do {
            let headerData = try handle.read(upToCount: VaultFormat.headerSize) ?? Data()
            let header = try VaultHeader(data: headerData)
            plaintextLength = header.plaintextLength
            chunkSize = header.chunkSize
            chunkCount = VaultFormat.chunkCount(plaintextLength: header.plaintextLength, chunkSize: header.chunkSize)
            fileKey = try VaultCrypto.unwrap(header.wrappedKey, with: masterKey)
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit { try? handle.close() }

    func read(offset: UInt64, length: Int) throws -> Data {
        guard length > 0, offset < plaintextLength else { return Data() }
        let end = min(offset + UInt64(length), plaintextLength)
        var output = Data()
        output.reserveCapacity(Int(end - offset))
        var position = offset
        while position < end {
            let index = position / UInt64(chunkSize)
            let block = try chunk(index)
            let start = Int(position - index * UInt64(chunkSize))
            let take = min(block.count - start, Int(end - position))
            guard take > 0 else { throw VaultCryptoError.corruptChunk(index) }
            output.append(block[(block.startIndex + start)..<(block.startIndex + start + take)])
            position += UInt64(take)
        }
        return output
    }

    func readAll() throws -> Data {
        try read(offset: 0, length: Int(plaintextLength))
    }

    private func chunk(_ index: UInt64) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        if let hit = cache[index] {
            touch(index)
            return hit
        }
        guard index < chunkCount else { throw VaultCryptoError.outOfRange }

        let isFinal = index == chunkCount - 1
        let plainLength = isFinal ? Int(plaintextLength - index * UInt64(chunkSize)) : chunkSize
        let offset = UInt64(VaultFormat.headerSize) + index * UInt64(chunkSize + VaultFormat.tagSize)
        try handle.seek(toOffset: offset)
        guard let encrypted = try handle.read(upToCount: plainLength + VaultFormat.tagSize),
              encrypted.count == plainLength + VaultFormat.tagSize else {
            throw VaultCryptoError.corruptChunk(index)
        }

        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: VaultFormat.nonce(for: index),
                                            ciphertext: encrypted.prefix(plainLength),
                                            tag: encrypted.suffix(VaultFormat.tagSize))
            plain = try AES.GCM.open(box, using: fileKey,
                                     authenticating: VaultFormat.aad(index: index, isFinal: isFinal))
        } catch {
            throw VaultCryptoError.corruptChunk(index)
        }

        cache[index] = plain
        touch(index)
        if recency.count > cacheLimit, let evict = recency.first {
            recency.removeFirst()
            cache[evict] = nil
        }
        return plain
    }

    private func touch(_ index: UInt64) {
        if let i = recency.firstIndex(of: index) { recency.remove(at: i) }
        recency.append(index)
    }
}
