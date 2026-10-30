import Foundation
import AVFoundation
import UniformTypeIdentifiers
import ImageIO
import UIKit

enum IngestError: LocalizedError {
    case unsupportedType(String)
    case unplayable(String)
    case unreadableImage(String)
    case unsupportedHere(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let name): return "\(name): not a photo or video."
        case .unplayable(let name): return "\(name): this video couldn't be read. The file may be damaged or use a very rare format."
        case .unreadableImage(let name): return "\(name): the image couldn't be read."
        case .unsupportedHere(let name): return "\(name): open VISION and import this format from Files (it needs VISION's full video player)."
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
    /// true = needs the VLC engine (MKV, AVI, WebM, WMV…); false = Apple's hardware player.
    let usesVLC: Bool
}

/// Result of inspecting a video Apple's player can't open (filled in by the VLC engine in the app).
struct FallbackVideoInfo: Sendable {
    let duration: Double
    let pixelWidth: Int
    let pixelHeight: Int
    let thumbnailJPEG: Data?
}

enum VideoFormats {
    /// Containers recognised by extension even when iOS has no type for them.
    static let extensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "mkv", "mk3d", "webm", "avi", "divx", "xvid", "wmv", "asf",
        "flv", "f4v", "ts", "mts", "m2ts", "m2t", "tp", "trp", "mpg", "mpeg", "mpe", "m1v", "m2v",
        "mpv", "vob", "3gp", "3g2", "ogv", "ogm", "rm", "rmvb", "mxf", "dv", "hevc", "h264", "264", "265"
    ]

    static func isVideo(_ url: URL, type: UTType) -> Bool {
        type.conforms(to: .movie) || type.conforms(to: .video)
            || extensions.contains(url.pathExtension.lowercased())
    }
}

/// Inspects a plaintext file, builds thumbnails, then encrypts everything into the vault.
/// Unplayable videos are rejected here, at import, rather than failing later in the player.
enum MediaIngestor {

    /// Set by the main app at launch (VLC engine). Nil in the Share Extension, which then
    /// only accepts formats Apple's player handles.
    nonisolated(unsafe) static var fallbackInspector: (@Sendable (URL) async throws -> FallbackVideoInfo)?

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
        var usesVLC = false

        if VideoFormats.isVideo(url, type: type) {
            kind = .video
            if let native = await inspectNative(url) {
                (duration, width, height, largeThumb) = native
            } else if let fallback = fallbackInspector {
                let info = try await fallback(url)
                (duration, width, height, largeThumb) = (info.duration, info.pixelWidth, info.pixelHeight, info.thumbnailJPEG)
                usesVLC = true
            } else {
                throw IngestError.unsupportedHere(displayName)
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
                            byteSize: Int64(size), duration: duration, pixelWidth: width, pixelHeight: height,
                            usesVLC: usesVLC)
    }

    /// Apple's hardware player — used whenever it can play EVERY track (otherwise e.g. an MP4
    /// with DTS audio would play silently), because it is the smoothest and most efficient.
    private static func inspectNative(_ url: URL) async -> (Double, Int, Int, Data?)? {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true,
              let tracks = try? await asset.load(.tracks),
              tracks.contains(where: { $0.mediaType == .video }) else { return nil }
        for track in tracks where track.mediaType == .video || track.mediaType == .audio {
            guard (try? await track.load(.isPlayable)) == true else { return nil }
        }
        let time = (try? await asset.load(.duration)) ?? .zero
        let duration = time.isNumeric ? time.seconds : 0
        var width = 0, height = 0
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let rect = CGRect(origin: .zero, size: natural).applying(transform)
            width = Int(abs(rect.width).rounded())
            height = Int(abs(rect.height).rounded())
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let at = CMTime(seconds: min(max(duration * 0.1, 0), 8), preferredTimescale: 600)
        var thumb: Data?
        if let frame = try? await generator.image(at: at).image {
            thumb = UIImage(cgImage: frame).jpegData(compressionQuality: 0.82)
        }
        return (duration, width, height, thumb)
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
