import SwiftUI

struct MediaRow: View {
    let title: String
    let items: [MediaItem]
    let cardWidth: CGFloat
    var showProgress = false
    let folders: [Folder]
    var onSeeAll: (() -> Void)? = nil
    let onSelect: (MediaItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header.padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(items) { item in
                        Button { onSelect(item) } label: {
                            PosterCard(item: item, width: cardWidth, showProgress: showProgress)
                        }
                        .buttonStyle(CardPressStyle())
                        .contextMenu { MediaContextMenu(item: item, folders: folders) }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
        }
    }

    @ViewBuilder
    private var header: some View {
        let label = HStack(spacing: 6) {
            Text(title).font(.title3.weight(.bold))
            if onSeeAll != nil {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(Theme.accent)
            }
        }
        .foregroundStyle(.white)

        if let onSeeAll {
            Button(action: onSeeAll) { label }.buttonStyle(.plain)
        } else {
            label
        }
    }
}

struct PosterCard: View {
    let item: MediaItem
    let width: CGFloat
    var showProgress = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VaultThumbnail(id: item.id, size: .small)
                .frame(width: width, height: width * 9 / 16)
                .overlay(alignment: .bottomTrailing) {
                    if item.kind == .video && !showProgress {
                        Text(Format.clock(item.duration))
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if item.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                            .shadow(color: .black.opacity(0.6), radius: 3)
                            .padding(7)
                    }
                }
                .overlay {
                    if showProgress {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 34))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.45))
                    }
                }
                .overlay(alignment: .bottom) {
                    if showProgress { ProgressStrip(progress: item.progress) }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))

            if showProgress {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.kind == .video ? "Video" : "Photo"), \(item.title)")
    }
}
