import AVFoundation
import Observation
import SwiftData

@MainActor
@Observable
final class PlayerModel {
    let player = AVPlayer()
    let item: MediaItem

    private(set) var isPlaying = false
    private(set) var isBuffering = true
    private(set) var isReady = false
    private(set) var duration: Double
    private(set) var currentTime: Double = 0
    private(set) var isScrubbing = false
    private(set) var rate: Float = 1
    private(set) var errorMessage: String?
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    @ObservationIgnored private var prepared: PreparedPlayback?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var seekInProgress = false
    @ObservationIgnored private var chaseTarget: CMTime = .invalid
    @ObservationIgnored private var resumeAfterScrub = false

    init(item: MediaItem) {
        self.item = item
        self.duration = item.duration
    }

    var fraction: Double { duration > 0 ? min(1, max(0, currentTime / duration)) : 0 }

    // MARK: Lifecycle

    func start() {
        guard prepared == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)

        do {
            prepared = try VaultPlayback.prepare(id: item.id, contentType: item.contentTypeID)
        } catch {
            errorMessage = "This video couldn't be opened. \(error.localizedDescription)"
            isBuffering = false
            return
        }
        guard let playerItem = prepared?.item else { return }

        // Data is local and decrypts far faster than real time, so don't let
        // AVPlayer hold back playback to "build a buffer" like it does for streaming.
        player.automaticallyWaitsToMinimizeStalling = false
        player.replaceCurrentItem(with: playerItem)
        observe(playerItem)

        let resume = item.watchPosition
        if resume > 5, resume < item.duration - 10 {
            currentTime = resume
            player.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
    }

    func stop() {
        saveProgress()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        player.replaceCurrentItem(with: nil)
        prepared = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func observe(_ playerItem: AVPlayerItem) {
        observations.append(playerItem.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let status = observed.status
            let seconds = observed.duration.seconds
            let message = observed.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    self.isReady = true
                    if seconds.isFinite, seconds > 0 { self.duration = seconds }
                case .failed:
                    self.errorMessage = message ?? "Playback failed."
                    self.isBuffering = false
                default: break
                }
            }
        })

        observations.append(player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] observed, _ in
            let status = observed.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = status != .paused
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate
            }
        })

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing, !self.seekInProgress else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = seconds }
            }
        }

        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: playerItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didFinish() }
        }
    }

    // MARK: Controls

    func togglePlayPause() {
        if player.timeControlStatus == .paused {
            if duration > 0, currentTime >= duration - 0.5 { seek(to: 0) }
            player.play()
        } else {
            player.pause()
            saveProgress()
        }
    }

    func skip(by seconds: Double) {
        let target = min(max(0, currentTime + seconds), max(0, duration - 0.1))
        currentTime = target
        chaseSeek(to: target)
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        chaseSeek(to: seconds)
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        player.defaultRate = newRate
        if player.timeControlStatus != .paused { player.rate = newRate }
    }

    func beginScrub() {
        guard !isScrubbing else { return }
        isScrubbing = true
        resumeAfterScrub = player.timeControlStatus != .paused
        player.pause()
    }

    func scrub(toFraction fraction: Double) {
        currentTime = fraction * duration
        chaseSeek(to: currentTime)   // live frame preview while dragging
    }

    func endScrub(atFraction fraction: Double) {
        currentTime = fraction * duration
        chaseSeek(to: currentTime)
        isScrubbing = false
        if resumeAfterScrub { player.play() }
    }

    /// Apple's "chase" seeking (QA1820): never stack seeks; always land on the
    /// latest requested time. Gives frame-accurate, jank-free scrubbing.
    private func chaseSeek(to seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        if chaseTarget.isValid, CMTimeCompare(target, chaseTarget) == 0 { return }
        chaseTarget = target
        if !seekInProgress { performChaseSeek() }
    }

    private func performChaseSeek() {
        seekInProgress = true
        let target = chaseTarget
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if CMTimeCompare(target, self.chaseTarget) == 0 {
                    self.seekInProgress = false
                } else {
                    self.performChaseSeek()
                }
            }
        }
    }

    private func didFinish() {
        currentTime = duration
        item.watchPosition = 0
        item.lastPlayedAt = Date()
        try? item.modelContext?.save()
    }

    private func saveProgress() {
        guard isReady, errorMessage == nil else { return }
        item.watchPosition = currentTime >= duration - 5 ? 0 : currentTime
        item.lastPlayedAt = Date()
        try? item.modelContext?.save()
    }
}
