import Foundation
import AVFoundation
import UniformTypeIdentifiers
import ImageIO
import UIKit

enum IngestError: LocalizedError {
    case unsupportedType(String)
    case unplayable(String)
    case unreadableImage(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let name): return "\(name): not a photo or video."
        case .unplayable(let name): return "\(name): this video format isn't supported on iPhone/iPad (try MP4 or MOV)."
        case .unreadableImage(let name): return "\(name): the image couldn't be read."
        }
    }
}

struct IngestResult: Codable, Sendable {
    let id: UUID
    let kind: MediaKind
    let title: String
    let contentTypeID: String
    let byteSize: Int64
    let duration: Double
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Inspects a plaintext file, builds thumbnails, then encrypts everything into the vault.
/// Unplayable videos are rejected here, at import, rather than failing later in the player.
enum MediaIngestor {

    static func ingest(fileAt url: URL, displayName: String) async throws -> IngestResult {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
            ?? .data
        let title = (displayName as NSString).deletingPathExtension
        let id = UUID()

        var kind: MediaKind
        var duration = 0.0
        var width = 0
        var height = 0
        var largeThumb: Data?

        if type.conforms(to: .movie) {
            kind = .video
            let asset = AVURLAsset(url: url)
            guard try await asset.load(.isPlayable) else { throw IngestError.unplayable(displayName) }
            let time = try await asset.load(.duration)
            duration = time.isNumeric ? time.seconds : 0
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
                let rect = CGRect(origin: .zero, size: natural).applying(transform)
                width = Int(abs(rect.width).rounded())
                height = Int(abs(rect.height).rounded())
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1280, height: 1280)
            let at = CMTime(seconds: min(max(duration * 0.1, 0), 8), preferredTimescale: 600)
            if let frame = try? await generator.image(at: at).image {
                largeThumb = UIImage(cgImage: frame).jpegData(compressionQuality: 0.82)
            }
        } else if type.conforms(to: .image) {
            kind = .photo
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw IngestError.unreadableImage(displayName)
            }
            if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
                height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
                if let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation >= 5 {
                    swap(&width, &height)
                }
            }
            largeThumb = thumbnail(from: source, maxPixel: 1280)
            guard largeThumb != nil else { throw IngestError.unreadableImage(displayName) }
        } else {
            throw IngestError.unsupportedType(displayName)
        }

        let store = VaultStore.shared
        let key = try store.masterKey()
        let size = try VaultCrypto.encryptFile(at: url, to: store.mediaURL(for: id), masterKey: key)
        do {
            if let largeThumb {
                try VaultCrypto.encrypt(data: largeThumb, to: store.thumbnailURL(for: id, size: .large), masterKey: key)
                if let source = CGImageSourceCreateWithData(largeThumb as CFData, nil),
                   let small = thumbnail(from: source, maxPixel: 480) {
                    try VaultCrypto.encrypt(data: small, to: store.thumbnailURL(for: id, size: .small), masterKey: key)
                }
            }
        } catch {
            store.removeFiles(for: id)
            throw error
        }

        return IngestResult(id: id, kind: kind, title: title, contentTypeID: type.identifier,
                            byteSize: Int64(size), duration: duration, pixelWidth: width, pixelHeight: height)
    }

    private static func thumbnail(from source: CGImageSource, maxPixel: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.82)
    }
}
