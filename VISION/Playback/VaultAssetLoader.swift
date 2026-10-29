import AVFoundation
import UniformTypeIdentifiers

/// Feeds AVPlayer decrypted bytes on demand.
///
/// AVPlayer asks for byte ranges of a custom-scheme URL; we decrypt exactly those
/// chunks from the vault file and hand them over. Nothing decrypted touches disk,
/// seeking is instant (random-access chunks), and decoding stays on Apple's
/// hardware H.264/HEVC path — that is where the smoothness comes from.
final class VaultAssetLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "vision-vault"

    let delegateQueue = DispatchQueue(label: "vision.player.loader", qos: .userInitiated)
    private let workQueue = DispatchQueue(label: "vision.player.decrypt", qos: .userInitiated, attributes: .concurrent)
    private let reader: VaultFileReader
    private let contentType: String
    private let sliceSize = 256 * 1024

    init(reader: VaultFileReader, contentType: String) {
        self.reader = reader
        self.contentType = contentType
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(reader.plaintextLength)
            info.isByteRangeAccessSupported = true
            if #available(iOS 16.0, *) {
                info.isEntireLengthAvailableOnDemand = true   // tells AVFoundation this behaves like a local file
            }
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        serve(loadingRequest, dataRequest)
        return true
    }

    private func serve(_ request: AVAssetResourceLoadingRequest, _ dataRequest: AVAssetResourceLoadingDataRequest) {
        let total = Int64(reader.plaintextLength)
        let start = dataRequest.currentOffset
        let end = dataRequest.requestsAllDataToEndOfResource
            ? total
            : min(total, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))
        let reader = self.reader
        let slice = sliceSize
        let delegateQueue = self.delegateQueue

        workQueue.async {
            var offset = start
            while offset < end {
                if request.isCancelled || request.isFinished { return }
                let length = Int(min(Int64(slice), end - offset))
                let data: Data
                do {
                    data = try reader.read(offset: UInt64(offset), length: length)
                } catch {
                    delegateQueue.async {
                        if !request.isCancelled && !request.isFinished { request.finishLoading(with: error) }
                    }
                    return
                }
                if data.isEmpty { break }
                var stop = false
                delegateQueue.sync {
                    if request.isCancelled || request.isFinished { stop = true } else { dataRequest.respond(with: data) }
                }
                if stop { return }
                offset += Int64(data.count)
            }
            delegateQueue.async {
                if !request.isCancelled && !request.isFinished { request.finishLoading() }
            }
        }
    }
}

/// Keeps the loader alive for as long as the item plays (the resource loader holds its delegate weakly).
struct PreparedPlayback {
    let item: AVPlayerItem
    let loader: VaultAssetLoader
}

enum VaultPlayback {
    static func prepare(id: UUID, contentType: String) throws -> PreparedPlayback {
        let reader = try VaultStore.shared.openMedia(id)
        let loader = VaultAssetLoader(reader: reader, contentType: contentType)
        let ext = UTType(contentType)?.preferredFilenameExtension ?? "mp4"
        guard let url = URL(string: "\(VaultAssetLoader.scheme)://media/\(id.uuidString).\(ext)") else {
            throw URLError(.badURL)
        }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
        return PreparedPlayback(item: AVPlayerItem(asset: asset), loader: loader)
    }
}
