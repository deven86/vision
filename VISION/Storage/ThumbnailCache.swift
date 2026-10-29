import UIKit

/// Decrypted thumbnails live only in memory (never on disk) and are purged on lock.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.totalCostLimit = 160 * 1024 * 1024
        cache.countLimit = 600
    }

    private func key(_ id: UUID, _ size: ThumbnailSize) -> NSString {
        "\(id.uuidString)-\(size.rawValue)" as NSString
    }

    func cached(_ id: UUID, _ size: ThumbnailSize) -> UIImage? {
        cache.object(forKey: key(id, size))
    }

    func load(_ id: UUID, _ size: ThumbnailSize) async -> UIImage? {
        if let hit = cached(id, size) { return hit }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let store = VaultStore.shared
            var url = store.thumbnailURL(for: id, size: size)
            if !FileManager.default.fileExists(atPath: url.path) {
                url = store.thumbnailURL(for: id, size: .large)
            }
            guard let reader = try? store.openFile(at: url),
                  let data = try? reader.readAll(),
                  let decoded = UIImage(data: data) else { return nil }
            // Decode now, off the main thread, so scrolling never stutters on first draw.
            return decoded.preparingForDisplay() ?? decoded
        }.value
        if let image {
            cache.setObject(image, forKey: key(id, size), cost: Self.cost(of: image))
        }
        return image
    }

    func remove(_ id: UUID) {
        cache.removeObject(forKey: key(id, .small))
        cache.removeObject(forKey: key(id, .large))
    }

    func purge() {
        cache.removeAllObjects()
    }

    private static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }
}
