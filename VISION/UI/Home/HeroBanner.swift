import SwiftUI

struct HeroBanner: View {
    let item: MediaItem
    let height: CGFloat
    let previewEnabled: Bool
    let onPlay: () -> Void
    let onToggleFavorite: () -> Void

    @State private var previewVisible = false
    @State private var showInfo = false

    var body: some View {
        GeometryReader { geo in
            let pull = max(0, geo.frame(in: .named("home")).minY)   // stretchy header on pull-down
            ZStack(alignment: .bottom) {
                ZStack {
                    VaultThumbnail(id: item.id, size: .large)
                    if previewEnabled && item.kind == .video && !item.usesVLC {
                        HeroPreview(item: item) {
                            withAnimation(.easeInOut(duration: 0.8)) { previewVisible = true }
                        }
                        .opacity(previewVisible ? 1 : 0)
                    }
                }
                .frame(width: geo.size.width, height: height + pull)
                .clipped()
                .offset(y: -pull)

                LinearGradient(stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .clear, location: 0.22),
                    .init(color: .clear, location: 0.45),
                    .init(color: Theme.background.opacity(0.85), location: 0.82),
                    .init(color: Theme.background, location: 1)
                ], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

                info
            }
        }
        .frame(height: height)
        .onChange(of: item.id) { _, _ in previewVisible = false }
        .onChange(of: previewEnabled) { _, enabled in if !enabled { previewVisible = false } }
        .sheet(isPresented: $showInfo) { MediaInfoSheet(item: item) }
    }

    private var metadata: [String] {
        var parts = [item.kind == .video ? "Video" : "Photo"]
        if item.kind == .video, !Format.runtime(item.duration).isEmpty { parts.append(Format.runtime(item.duration)) }
        if let quality = item.qualityLabel { parts.append(quality) }
        return parts
    }

    private var info: some View {
        VStack(spacing: 12) {
            Text((item.folder?.name ?? "VISION").uppercased())
                .font(.caption.weight(.heavy))
                .tracking(3)
                .foregroundStyle(Theme.accent)

            Text(item.title)
                .font(.system(size: 32, weight: .heavy))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(0.6), radius: 8)
                .padding(.horizontal, 28)

            Text(metadata.joined(separator: "  •  "))
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.secondaryText)

            HStack(spacing: 14) {
                iconButton(item.isFavorite ? "checkmark" : "plus", label: "Favorites", action: onToggleFavorite)

                Button(action: onPlay) {
                    Label(primaryTitle, systemImage: item.kind == .video ? "play.fill" : "eye.fill")
                        .font(.headline)
                        .frame(width: 150, height: 46)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .foregroundStyle(.black)
                }
                .buttonStyle(CardPressStyle())

                iconButton("info.circle", label: "Info") { showInfo = true }
            }
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .padding(.bottom, 22)
    }

    private var primaryTitle: String {
        guard item.kind == .video else { return "View" }
        return item.watchPosition > 5 ? "Resume" : "Play"
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(label).font(.caption2.weight(.medium))
            }
            .frame(width: 72, height: 46)
        }
        .buttonStyle(CardPressStyle())
    }
}
