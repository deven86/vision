import SwiftUI
import AVFoundation

struct PlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: any PlayerControlling
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var skipFlash: SkipFlash?

    // Swipe-to-scrub state
    @State private var scrubTarget: Double = 0
    @State private var scrubOrigin: Double = 0
    @State private var lastPanX: CGFloat = 0
    @State private var scrubSpeed: ScrubSpeed = .normal

    init(item: MediaItem) {
        let engine: any PlayerControlling = item.usesVLC ? VLCPlayerModel(item: item) : PlayerModel(item: item)
        _model = State(initialValue: engine)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            surface.ignoresSafeArea()

            PlayerGestureLayer(onSingleTap: toggleControls,
                               onDoubleTap: doubleTapSkip,
                               onPan: handlePan)
                .ignoresSafeArea()

            if model.isBuffering && model.errorMessage == nil && !model.isScrubbing {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }

            if let flash = skipFlash {
                SkipFlashView(flash: flash)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if controlsVisible {
                PlayerControls(model: model, onClose: close, onInteract: scheduleHide,
                               onBarScrub: { _ in showControls() })
                    .transition(.opacity)
            }

            if model.isScrubbing {
                ScrubPreviewBubble(model: model, origin: scrubOrigin, speed: scrubSpeed)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if let message = model.errorMessage {
                errorView(message)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .animation(.easeOut(duration: 0.15), value: model.isScrubbing)
        .onAppear {
            model.start()
            scheduleHide()
        }
        .onDisappear {
            model.stop()
            CloudSync.shared.scheduleSync()
        }
        .onChange(of: model.isPlaying) { _, playing in
            if playing { scheduleHide() } else { showControls() }
        }
    }

    @ViewBuilder
    private var surface: some View {
        if let av = model as? PlayerModel {
            PlayerLayerView(player: av.player, gravity: av.videoGravity) { layer in av.attach(layer: layer) }
        } else if let vlc = model as? VLCPlayerModel {
            VLCSurface(player: vlc.player)
        }
    }

    // MARK: Swipe anywhere to scrub (like the iOS player)

    private func handlePan(_ phase: PlayerPan) {
        switch phase {
        case .began:
            scrubOrigin = model.currentTime
            scrubTarget = model.currentTime
            lastPanX = 0
            scrubSpeed = .normal
            model.beginScrub()
            showControls()
            UISelectionFeedbackGenerator().selectionChanged()
        case .changed(let translation, let width):
            // Move your finger down while dragging for finer control (same idea as iOS).
            let speed = ScrubSpeed(verticalOffset: abs(translation.y))
            if speed != scrubSpeed {
                scrubSpeed = speed
                UISelectionFeedbackGenerator().selectionChanged()
            }
            // One screen-width ≈ 3 minutes (or the whole video if shorter).
            let span = min(max(model.duration, 1), 180)
            let delta = Double(translation.x - lastPanX) / Double(width) * span * speed.factor
            lastPanX = translation.x
            scrubTarget = model.clamped(scrubTarget + delta)
            model.scrub(to: scrubTarget)
        case .ended:
            model.endScrub(at: scrubTarget)
            scrubSpeed = .normal
            scheduleHide()
        }
    }

    // MARK: Double tap ±10 s (repeated double taps add up: 10, 20, 30…)

    private func doubleTapSkip(_ forward: Bool) {
        model.skip(by: forward ? 10 : -10)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let total = (skipFlash?.forward == forward ? skipFlash?.seconds ?? 0 : 0) + 10
        let flash = SkipFlash(forward: forward, seconds: total)
        withAnimation(.easeOut(duration: 0.12)) { skipFlash = flash }
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            if skipFlash?.id == flash.id { withAnimation(.easeIn(duration: 0.25)) { skipFlash = nil } }
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() }
    }

    private func showControls() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, model.isPlaying, !model.isScrubbing else { return }
            withAnimation(.easeOut(duration: 0.35)) { controlsVisible = false }
        }
    }

    private func close() {
        hideTask?.cancel()
        dismiss()
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accent)
            Text("Can't play this video").font(.title3.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Button("Close", action: close)
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
        }
        .padding(32)
        .foregroundStyle(.white)
    }
}

enum ScrubSpeed: Equatable {
    case normal, half, fine

    init(verticalOffset: CGFloat) {
        self = verticalOffset > 140 ? .fine : (verticalOffset > 70 ? .half : .normal)
    }

    var factor: Double {
        switch self {
        case .normal: return 1
        case .half: return 0.5
        case .fine: return 0.2
        }
    }

    var label: String? {
        switch self {
        case .normal: return nil
        case .half: return "Half-speed scrubbing"
        case .fine: return "Fine scrubbing"
        }
    }
}

// MARK: - Preview bubble shown while scrubbing

struct ScrubPreviewBubble: View {
    let model: any PlayerControlling
    let origin: Double
    let speed: ScrubSpeed

    var body: some View {
        GeometryReader { geo in
            let barInset: CGFloat = 20
            let barWidth = geo.size.width - barInset * 2 - 64
            let thumbWidth: CGFloat = min(220, geo.size.width * 0.5)
            let x = barInset + barWidth * model.fraction
            let clampedX = min(max(x, thumbWidth / 2 + 8), geo.size.width - thumbWidth / 2 - 8)
            let delta = model.currentTime - origin

            VStack(spacing: 8) {
                if let label = speed.label {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                if let image = model.previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: thumbWidth, height: thumbWidth * 9 / 16)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.85), lineWidth: 2))
                        .shadow(color: .black.opacity(0.6), radius: 12)
                }
                VStack(spacing: 2) {
                    Text(Format.clock(model.currentTime))
                        .font(.system(size: 22, weight: .bold).monospacedDigit())
                    Text((delta >= 0 ? "+" : "−") + Format.clock(abs(delta)))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
                .shadow(color: .black.opacity(0.8), radius: 6)
            }
            .foregroundStyle(.white)
            .position(x: clampedX, y: geo.size.height - 130 - (model.previewImage == nil ? 0 : thumbWidth * 9 / 32))
        }
        .ignoresSafeArea(.keyboard)
    }
}

// MARK: - Controls overlay

struct PlayerControls: View {
    let model: any PlayerControlling
    let onClose: () -> Void
    let onInteract: () -> Void
    let onBarScrub: (Bool) -> Void

    private let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 150)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 200)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                if !model.isScrubbing { centerButtons }
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close player")

            Spacer(minLength: 0)
            Text(model.item.title)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 0)

            if model.supportsFill {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) { model.fillsScreen.toggle() }
                    onInteract()
                } label: {
                    Image(systemName: model.fillsScreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(model.fillsScreen ? "Fit to screen" : "Fill screen")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
    }

    private var centerButtons: some View {
        HStack(spacing: 56) {
            Button { model.skip(by: -10); onInteract() } label: {
                Image(systemName: "gobackward.10").font(.system(size: 34, weight: .medium))
            }
            .accessibilityLabel("Back 10 seconds")

            Button { model.togglePlayPause(); onInteract() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 54))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 76, height: 76)
            }
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

            Button { model.skip(by: 10); onInteract() } label: {
                Image(systemName: "goforward.10").font(.system(size: 34, weight: .medium))
            }
            .accessibilityLabel("Forward 10 seconds")
        }
        .shadow(color: .black.opacity(0.4), radius: 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ScrubBar(fraction: model.fraction,
                         onBegin: { model.beginScrub(); onBarScrub(true) },
                         onChange: { model.scrub(to: $0 * model.duration) },
                         onEnd: { model.endScrub(at: $0 * model.duration); onInteract() })
                Text("-" + Format.clock(max(0, model.duration - model.currentTime)))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 52, alignment: .trailing)
            }
            HStack {
                Menu {
                    ForEach(speeds, id: \.self) { speed in
                        Button {
                            model.setRate(speed)
                            onInteract()
                        } label: {
                            if speed == model.rate {
                                Label(Self.label(for: speed), systemImage: "checkmark")
                            } else {
                                Text(Self.label(for: speed))
                            }
                        }
                    }
                } label: {
                    Label("Speed (\(Self.label(for: model.rate)))", systemImage: "speedometer")
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                if !model.audioTracks.isEmpty || !model.subtitleTracks.isEmpty {
                    Menu {
                        if !model.subtitleTracks.isEmpty {
                            Section("Subtitles") {
                                trackButton("Off", selected: model.selectedSubtitle == nil) { model.selectSubtitle(nil) }
                                ForEach(model.subtitleTracks) { track in
                                    trackButton(track.title, selected: model.selectedSubtitle == track.id) { model.selectSubtitle(track.id) }
                                }
                            }
                        }
                        if model.audioTracks.count > 1 {
                            Section("Audio") {
                                ForEach(model.audioTracks) { track in
                                    trackButton(track.title, selected: model.selectedAudio == track.id) { model.selectAudio(track.id) }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "captions.bubble").font(.title3).frame(width: 40, height: 32)
                    }
                    .accessibilityLabel("Subtitles and audio")
                }
                if model.supportsPictureInPicture {
                    Button {
                        model.startPictureInPicture()
                        onInteract()
                    } label: {
                        Image(systemName: "pip.enter").font(.title3).frame(width: 40, height: 32)
                    }
                    .accessibilityLabel("Picture in Picture")
                }
                Text("\(Format.clock(model.currentTime)) / \(Format.clock(model.duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func trackButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onInteract()
        } label: {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    static func label(for speed: Float) -> String {
        String(format: "%gx", Double(speed))
    }
}

// MARK: - Scrub bar: drag anywhere on it, it moves relative to where you started

struct ScrubBar: View {
    let fraction: Double
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: (Double) -> Void
    @State private var dragging = false
    @State private var startFraction: Double = 0

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let knob: CGFloat = dragging ? 22 : 14
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.28))
                    .frame(height: dragging ? 8 : 4)
                Capsule().fill(Theme.accent)
                    .frame(width: width * fraction, height: dragging ? 8 : 4)
                Circle().fill(Theme.accent)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 4)
                    .offset(x: width * fraction - knob / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            startFraction = fraction
                            onBegin()
                        }
                        onChange(min(1, max(0, startFraction + value.translation.width / width)))
                    }
                    .onEnded { value in
                        dragging = false
                        onEnd(min(1, max(0, startFraction + value.translation.width / width)))
                    }
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragging)
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(fraction * 100)) percent")
        .accessibilityAdjustableAction { direction in
            onBegin()
            let step = direction == .increment ? 0.05 : -0.05
            onEnd(min(1, max(0, fraction + step)))
        }
    }
}

// MARK: - Double-tap feedback

struct SkipFlash: Equatable {
    let id = UUID()
    let forward: Bool
    let seconds: Int
}

struct SkipFlashView: View {
    let flash: SkipFlash
    var body: some View {
        HStack {
            if flash.forward { Spacer() }
            VStack(spacing: 6) {
                Image(systemName: flash.forward ? "goforward" : "gobackward")
                    .font(.system(size: 30, weight: .semibold))
                Text("\(flash.seconds) seconds").font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 120, height: 120)
            .background(Circle().fill(Color.white.opacity(0.16)))
            .padding(.horizontal, 36)
            if !flash.forward { Spacer() }
        }
    }
}
