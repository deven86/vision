import UIKit
import SwiftUI
import AVFoundation
import Observation
import MobileVLCKit

/// Second playback engine for formats Apple's player can't open (MKV, AVI, WebM, WMV, FLV…).
/// Apple's player stays the default because it decodes in hardware and is the smoothest;
/// VLC is used only for items imported with `usesVLC == true`.
enum VLCSupport {
    static func register() {
        MediaIngestor.fallbackInspector = { url in try await VLCInspector.inspect(url) }
    }
}

// MARK: - Import-time inspection

enum VLCInspector {
    static func inspect(_ url: URL) async throws -> FallbackVideoInfo {
        let media = VLCMedia(url: url)
        // Parses the file (blocking, so off the main thread). 0 = unknown length.
        let milliseconds = await Task.detached(priority: .userInitiated) { () -> Int32 in
            media.lengthWait(until: Date().addingTimeInterval(10)).intValue
        }.value

        var width = 0, height = 0
        for case let track as [String: Any] in media.tracksInformation {
            guard (track[VLCMediaTracksInformationType] as? String) == VLCMediaTracksInformationTypeVideo else { continue }
            width = (track[VLCMediaTracksInformationVideoWidth] as? NSNumber)?.intValue ?? 0
            height = (track[VLCMediaTracksInformationVideoHeight] as? NSNumber)?.intValue ?? 0
            if width > 0 { break }
        }

        let frame = await VLCThumbnailGrabber.grab(media, width: width, height: height)
        guard milliseconds > 0 || frame != nil else {
            throw IngestError.unplayable(url.lastPathComponent)
        }
        if width == 0, let frame { width = frame.width; height = frame.height }
        let jpeg = frame.flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.82) }
        return FallbackVideoInfo(duration: Double(max(0, milliseconds)) / 1000,
                                 pixelWidth: width, pixelHeight: height, thumbnailJPEG: jpeg)
    }
}

@MainActor
final class VLCThumbnailGrabber: NSObject, VLCMediaThumbnailerDelegate {
    private static var running = Set<VLCThumbnailGrabber>()
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var thumbnailer: VLCMediaThumbnailer?

    static func grab(_ media: VLCMedia, width: Int, height: Int) async -> CGImage? {
        let grabber = VLCThumbnailGrabber()
        running.insert(grabber)
        defer { running.remove(grabber) }
        return await withCheckedContinuation { continuation in
            grabber.continuation = continuation
            let thumbnailer = VLCMediaThumbnailer(media: media, andDelegate: grabber)
            let targetWidth: CGFloat = 1280
            thumbnailer.thumbnailWidth = targetWidth
            thumbnailer.thumbnailHeight = width > 0 && height > 0
                ? targetWidth * CGFloat(height) / CGFloat(width)
                : targetWidth * 9 / 16
            thumbnailer.snapshotPosition = 0.1
            grabber.thumbnailer = thumbnailer
            thumbnailer.fetchThumbnail()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                grabber.finish(nil)
            }
        }
    }

    private func finish(_ image: CGImage?) {
        continuation?.resume(returning: image)
        continuation = nil
        thumbnailer = nil
    }

    nonisolated func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer, didFinishThumbnail thumbnail: CGImage) {
        Task { @MainActor in self.finish(thumbnail) }
    }
}

// MARK: - Player

@MainActor
@Observable
final class VLCPlayerModel: PlayerControlling {
    @ObservationIgnored let player = VLCMediaPlayer()
    let item: MediaItem

    private(set) var isPlaying = false
    private(set) var isBuffering = true
    private(set) var errorMessage: String?
    private(set) var isScrubbing = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double
    private(set) var rate: Float = 1
    let supportsFill = false
    var fillsScreen = false
    let previewImage: UIImage? = nil   // VLC: the video frame itself follows the finger instead
    let supportsPictureInPicture = false
    private(set) var audioTracks: [TrackOption] = []
    private(set) var subtitleTracks: [TrackOption] = []
    private(set) var selectedAudio: String?
    private(set) var selectedSubtitle: String?
    @ObservationIgnored private var tracksLoaded = false

    @ObservationIgnored private var server: LoopbackMediaServer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pendingResume: Double?
    @ObservationIgnored private var lastScrubSeek = Date.distantPast
    @ObservationIgnored private var started = false
    @ObservationIgnored private var hasPlayed = false

    init(item: MediaItem) {
        self.item = item
        self.duration = item.duration
    }

    func start() {
        guard !started else { return }
        started = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)

        let resume = item.watchPosition
        if resume > 5, resume < item.duration - 10 {
            pendingResume = resume
            currentTime = resume
        }
        let id = item.id
        Task {
            do {
                let reader = try VaultStore.shared.openMedia(id)
                let server = LoopbackMediaServer(reader: reader)
                self.server = server
                let url = try await server.start()
                guard started else { server.stop(); return }
                player.media = VLCMedia(url: url)
                player.play()
                timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
            } catch {
                errorMessage = "This video couldn't be opened. \(error.localizedDescription)"
                isBuffering = false
            }
        }
    }

    func stop() {
        saveProgress()
        started = false
        timer?.invalidate()
        timer = nil
        player.stop()
        server?.stop()
        server = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func tick() {
        let state = player.state
        if state == .error {
            errorMessage = "VISION couldn't decode this video."
            isBuffering = false
            return
        }
        if state == .ended {
            didFinish()
            return
        }
        isPlaying = player.isPlaying
        if isPlaying { hasPlayed = true }
        isBuffering = !player.isPlaying && (state == .opening || state == .buffering) && !hasPlayed
        let length = player.media?.length.intValue ?? 0
        if length > 0 { duration = Double(length) / 1000 }
        if let resume = pendingResume, player.isPlaying, player.isSeekable {
            seek(resume)
            pendingResume = nil
        }
        if !isScrubbing, pendingResume == nil {
            currentTime = Double(player.time.intValue) / 1000
        }
        if !tracksLoaded, player.isPlaying { loadTracks() }
    }

    private func loadTracks() {
        tracksLoaded = true
        func options(_ indexes: [Any], _ names: [Any]) -> [TrackOption] {
            zip(indexes, names).compactMap { index, name in
                guard let index = index as? NSNumber, index.int32Value >= 0 else { return nil }   // -1 = "Disable"
                return TrackOption(id: index.stringValue, title: (name as? String) ?? "Track \(index)")
            }
        }
        audioTracks = options(player.audioTrackIndexes, player.audioTrackNames)
        subtitleTracks = options(player.videoSubTitlesIndexes, player.videoSubTitlesNames)
        selectedAudio = player.currentAudioTrackIndex >= 0 ? "\(player.currentAudioTrackIndex)" : nil
        selectedSubtitle = player.currentVideoSubTitleIndex >= 0 ? "\(player.currentVideoSubTitleIndex)" : nil
    }

    func selectAudio(_ id: String) {
        guard let index = Int32(id) else { return }
        player.currentAudioTrackIndex = index
        selectedAudio = id
    }

    func selectSubtitle(_ id: String?) {
        player.currentVideoSubTitleIndex = id.flatMap(Int32.init) ?? -1
        selectedSubtitle = id
    }

    func startPictureInPicture() {}

    func togglePlayPause() {
        if player.isPlaying {
            player.pause()
            saveProgress()
        } else {
            if duration > 0, currentTime >= duration - 0.5 { seek(0) }
            player.play()
        }
    }

    func skip(by seconds: Double) {
        seek(clamped(currentTime + seconds))
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        player.rate = newRate
    }

    func beginScrub() {
        isScrubbing = true
    }

    func scrub(to seconds: Double) {
        currentTime = clamped(seconds)
        // VLC seeks are heavier than AVPlayer's; ~7 per second keeps the picture following the finger.
        if Date().timeIntervalSince(lastScrubSeek) > 0.15 {
            lastScrubSeek = Date()
            seek(currentTime)
        }
    }

    func endScrub(at seconds: Double) {
        seek(clamped(seconds))
        isScrubbing = false
    }

    private func seek(_ seconds: Double) {
        currentTime = seconds
        player.time = VLCTime(int: Int32(max(0, seconds) * 1000))
    }

    private func didFinish() {
        isPlaying = false
        currentTime = duration
        item.watchPosition = 0
        item.lastPlayedAt = Date()
        try? item.modelContext?.save()
    }

    private func saveProgress() {
        guard hasPlayed, errorMessage == nil else { return }
        item.watchPosition = currentTime >= duration - 5 ? 0 : currentTime
        item.lastPlayedAt = Date()
        try? item.modelContext?.save()
    }
}

struct VLCSurface: UIViewRepresentable {
    let player: VLCMediaPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        player.drawable = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}
