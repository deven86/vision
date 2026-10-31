import SwiftUI
import AVFoundation

final class PlayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// A bare AVPlayerLayer — no system chrome, so we can draw our own controls.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect
    var onLayer: ((AVPlayerLayer) -> Void)? = nil

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.backgroundColor = .clear
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        onLayer?(view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        if view.playerLayer.videoGravity != gravity { view.playerLayer.videoGravity = gravity }
    }
}

/// Muted, looping autoplay preview used behind the Home hero.
@MainActor
@Observable
final class HeroPreviewModel {
    let player = AVPlayer()
    @ObservationIgnored private var prepared: PreparedPlayback?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init() {
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    func start(item: MediaItem) async -> Bool {
        stop()
        guard let ready = try? VaultPlayback.prepare(id: item.id, contentType: item.contentTypeID) else { return false }
        prepared = ready
        player.replaceCurrentItem(with: ready.item)
        if item.duration > 30 {
            _ = await player.seek(to: CMTime(seconds: item.duration * 0.2, preferredTimescale: 600))
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: ready.item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player.seek(to: .zero)
                self?.player.play()
            }
        }
        player.play()
        return true
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        prepared = nil
    }
}

struct HeroPreview: View {
    let item: MediaItem
    var onStarted: () -> Void
    @State private var model = HeroPreviewModel()

    var body: some View {
        PlayerLayerView(player: model.player, gravity: .resizeAspectFill)
            .allowsHitTesting(false)
            .task(id: item.id) {
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                if await model.start(item: item) {
                    try? await Task.sleep(for: .milliseconds(450))   // let the first frames land before fading in
                    if !Task.isCancelled { onStarted() }
                }
            }
            .onDisappear { model.stop() }
    }
}
