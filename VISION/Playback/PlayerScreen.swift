import SwiftUI
import AVFoundation

struct PlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: PlayerModel
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var skipFlash: SkipFlash?

    init(item: MediaItem) {
        _model = State(initialValue: PlayerModel(item: item))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerLayerView(player: model.player, gravity: model.videoGravity)
                .ignoresSafeArea()

            gestureLayer

            if model.isBuffering && model.errorMessage == nil && !model.isScrubbing {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }

            if let flash = skipFlash {
                SkipFlashView(flash: flash)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if controlsVisible {
                PlayerControls(model: model, onClose: close, onInteract: scheduleHide)
                    .transition(.opacity)
            }

            if let message = model.errorMessage {
                errorView(message)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            model.start()
            scheduleHide()
        }
        .onDisappear { model.stop() }
        .onChange(of: model.isPlaying) { _, playing in
            if playing { scheduleHide() } else { showControls() }
        }
    }

    // MARK: Gestures — single tap toggles chrome, double tap left/right skips 10s

    private var gestureLayer: some View {
        HStack(spacing: 0) {
            tapZone(direction: -1)
            tapZone(direction: 1)
        }
        .ignoresSafeArea()
    }

    private func tapZone(direction: Double) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                TapGesture(count: 2).onEnded { doubleTapSkip(direction) }
                    .exclusively(before: TapGesture().onEnded { toggleControls() })
            )
    }

    private func doubleTapSkip(_ direction: Double) {
        model.skip(by: 10 * direction)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let flash = SkipFlash(forward: direction > 0)
        withAnimation(.easeOut(duration: 0.15)) { skipFlash = flash }
        Task {
            try? await Task.sleep(for: .milliseconds(650))
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

// MARK: - Controls overlay

struct PlayerControls: View {
    let model: PlayerModel
    let onClose: () -> Void
    let onInteract: () -> Void

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
                centerButtons
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

            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    model.videoGravity = model.videoGravity == .resizeAspect ? .resizeAspectFill : .resizeAspect
                }
                onInteract()
            } label: {
                Image(systemName: model.videoGravity == .resizeAspect
                      ? "arrow.up.left.and.arrow.down.right"
                      : "arrow.down.right.and.arrow.up.left")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(model.videoGravity == .resizeAspect ? "Fill screen" : "Fit to screen")
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
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ScrubBar(fraction: model.fraction,
                         onBegin: { model.beginScrub() },
                         onChange: { model.scrub(toFraction: $0) },
                         onEnd: { model.endScrub(atFraction: $0); onInteract() })
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
                Text("\(Format.clock(model.currentTime)) / \(Format.clock(model.duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    static func label(for speed: Float) -> String {
        String(format: "%gx", Double(speed))
    }
}

// MARK: - Scrub bar (thin at rest, grows while dragging)

struct ScrubBar: View {
    let fraction: Double
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: (Double) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let knob: CGFloat = dragging ? 22 : 14
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.28))
                    .frame(height: dragging ? 7 : 4)
                Capsule().fill(Theme.accent)
                    .frame(width: width * fraction, height: dragging ? 7 : 4)
                Circle().fill(Theme.accent)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 4)
                    .offset(x: width * fraction - knob / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            onBegin()
                        }
                        onChange(min(1, max(0, value.location.x / width)))
                    }
                    .onEnded { value in
                        dragging = false
                        onEnd(min(1, max(0, value.location.x / width)))
                    }
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragging)
        }
        .frame(height: 32)
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
}

struct SkipFlashView: View {
    let flash: SkipFlash
    var body: some View {
        HStack {
            if flash.forward { Spacer() }
            VStack(spacing: 6) {
                Image(systemName: flash.forward ? "goforward.10" : "gobackward.10")
                    .font(.system(size: 30, weight: .semibold))
                Text("10 seconds").font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(28)
            .background(Circle().fill(Color.white.opacity(0.14)))
            .padding(.horizontal, 40)
            if !flash.forward { Spacer() }
        }
    }
}
