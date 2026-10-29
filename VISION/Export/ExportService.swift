import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum ExportError: LocalizedError {
    case notEnoughSpace(needed: Int64)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed):
            return "Not enough free space on this device. Exporting needs about \(Format.bytes(needed)) free."
        case .cancelled:
            return "Export was cancelled."
        }
    }
}

struct ExportRequest: Sendable {
    let id: UUID
    let title: String
    let kind: MediaKind
    let contentTypeID: String
    let byteSize: Int64
}

/// Creates decrypted copies for sharing. These copies live OUTSIDE the vault's protection
/// once handed to another app, so the UI always warns first. Our own temp copies are
/// written with complete file protection and deleted as soon as the share sheet closes
/// (and again on every launch, in case the app was killed mid-export).
enum ExportService {

    static var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("VISIONExport", isDirectory: true)
    }

    static func purgeAll() {
        try? FileManager.default.removeItem(at: exportDirectory)
    }

    static func cleanup(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    /// Exports items one at a time; `progress` reports items finished.
    static func export(_ requests: [ExportRequest],
                       stripMetadata: Bool,
                       progress: @escaping @Sendable (Int) -> Void) async throws -> [URL] {
        try ensureSpace(for: requests)
        var results: [URL] = []
        do {
            for (index, request) in requests.enumerated() {
                try Task.checkCancellation()
                results.append(try await exportOne(request, stripMetadata: stripMetadata))
                progress(index + 1)
            }
        } catch {
            cleanup(results)
            throw error is CancellationError ? ExportError.cancelled : error
        }
        return results
    }

    private static func ensureSpace(for requests: [ExportRequest]) throws {
        // Worst case: decrypted copy + metadata-stripped copy of the largest item, plus everything else once.
        let total = requests.reduce(Int64(0)) { $0 + $1.byteSize }
        let largest = requests.map(\.byteSize).max() ?? 0
        let needed = total + largest + 50 * 1024 * 1024
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free < needed {
            throw ExportError.notEnoughSpace(needed: needed)
        }
    }

    private static func exportOne(_ request: ExportRequest, stripMetadata: Bool) async throws -> URL {
        let folder = exportDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        let ext = UTType(request.contentTypeID)?.preferredFilenameExtension
            ?? (request.kind == .video ? "mov" : "jpg")
        let name = sanitize(request.title)
        let decrypted = folder.appendingPathComponent("\(name).\(ext)")

        try await Task.detached(priority: .userInitiated) {
            try decrypt(request.id, to: decrypted)
        }.value

        guard stripMetadata else { return decrypted }

        let cleaned = folder.appendingPathComponent("clean-\(name).\(ext)")
        let ok: Bool
        switch request.kind {
        case .photo: ok = await Task.detached { stripImageMetadata(from: decrypted, to: cleaned) }.value
        case .video: ok = await stripVideoLocation(from: decrypted, to: cleaned, typeID: request.contentTypeID)
        }
        guard ok else { return decrypted }   // fall back to the original rather than failing the export
        try? FileManager.default.removeItem(at: decrypted)
        try FileManager.default.moveItem(at: cleaned, to: decrypted)
        return decrypted
    }

    /// Streams chunk by chunk so multi-GB videos never load fully into memory.
    private static func decrypt(_ id: UUID, to url: URL) throws {
        let reader = try VaultStore.shared.openMedia(id)
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.protectionKey: FileProtectionType.complete]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        var offset: UInt64 = 0
        let step = 4 * 1024 * 1024
        while offset < reader.plaintextLength {
            try Task.checkCancellation()
            try autoreleasepool {
                let data = try reader.read(offset: offset, length: step)
                try out.write(contentsOf: data)
                offset += UInt64(data.count)
            }
        }
    }

    /// Removes GPS, EXIF (camera/lens/serial) and maker notes; keeps orientation and pixels untouched.
    private static func stripImageMetadata(from source: URL, to destination: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let type = CGImageSourceGetType(src),
              let dest = CGImageDestinationCreateWithURL(destination as CFURL, type, CGImageSourceGetCount(src), nil)
        else { return false }
        let remove: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: kCFNull as Any,
            kCGImagePropertyExifDictionary: kCFNull as Any,
            kCGImagePropertyExifAuxDictionary: kCFNull as Any,
            kCGImagePropertyMakerAppleDictionary: kCFNull as Any,
            kCGImagePropertyIPTCDictionary: kCFNull as Any,
            kCGImageMetadataShouldExcludeGPS: true
        ]
        for index in 0..<CGImageSourceGetCount(src) {
            CGImageDestinationAddImageFromSource(dest, src, index, remove as CFDictionary)
        }
        return CGImageDestinationFinalize(dest)
    }

    /// Passthrough re-mux (no quality loss) dropping location metadata.
    private static func stripVideoLocation(from source: URL, to destination: URL, typeID: String) async -> Bool {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return false
        }
        let metadata = (try? await asset.load(.metadata)) ?? []
        let locationIDs: Set<AVMetadataIdentifier> = [
            .quickTimeMetadataLocationISO6709, .commonIdentifierLocation,
            .quickTimeUserDataLocationISO6709, .quickTimeMetadataLocationName,
            .quickTimeMetadataLocationBody, .quickTimeMetadataLocationNote
        ]
        session.metadata = metadata.filter { item in
            guard let id = item.identifier else { return true }
            return !locationIDs.contains(id)
        }
        let fileType: AVFileType = UTType(typeID)?.conforms(to: .mpeg4Movie) == true ? .mp4 : .mov
        if #available(iOS 18.0, *) {
            do {
                try await session.export(to: destination, as: fileType)
                return true
            } catch {
                try? FileManager.default.removeItem(at: destination)
                return false
            }
        } else {
            session.outputURL = destination
            session.outputFileType = fileType
            await session.export()
            if session.status == .completed { return true }
            try? FileManager.default.removeItem(at: destination)
            return false
        }
    }

    private static func sanitize(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        let cleaned = title.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "VISION Export" : String(cleaned.prefix(80))
    }
}
