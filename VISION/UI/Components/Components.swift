import SwiftUI
import SwiftData

// MARK: - Encrypted thumbnail

struct VaultThumbnail: View {
    let id: UUID
    var size: ThumbnailSize = .small
    @State private var image: UIImage?

    init(id: UUID, size: ThumbnailSize = .small) {
        self.id = id
        self.size = size
        _image = State(initialValue: ThumbnailCache.shared.cached(id, size))
    }

    var body: some View {
        Rectangle()
            .fill(LinearGradient(colors: [Theme.surfaceRaised, Theme.surface], startPoint: .top, endPoint: .bottom))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: "\(id.uuidString)-\(size.rawValue)") {
                guard image == nil else { return }
                let loaded = await ThumbnailCache.shared.load(id, size)
                withAnimation(.easeOut(duration: 0.22)) { image = loaded }
            }
    }
}

// MARK: - Scroll tracking

struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Progress strip

struct ProgressStrip: View {
    let progress: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.25))
                Rectangle().fill(Theme.accent).frame(width: geo.size.width * progress)
            }
        }
        .frame(height: 3)
    }
}

// MARK: - Shared item context menu

struct MediaContextMenu: View {
    let item: MediaItem
    let folders: [Folder]
    @Environment(\.modelContext) private var context
    @Environment(ExportPresenter.self) private var exporter

    var body: some View {
        Button {
            exporter.export([item])
        } label: {
            Label("Export…", systemImage: "square.and.arrow.up")
        }
        Button {
            Library.toggleFavorite(item, context: context)
        } label: {
            Label(item.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                  systemImage: item.isFavorite ? "heart.slash" : "heart")
        }
        if let folder = item.folder {
            Button {
                Library.setCover(item, for: folder, context: context)
            } label: {
                Label("Use as Folder Cover", systemImage: "photo.on.rectangle")
            }
        }
        Menu {
            ForEach(folders.filter { $0.id != item.folder?.id }) { folder in
                Button(folder.name) { Library.move([item], to: folder, context: context) }
            }
        } label: {
            Label("Move to…", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) {
            Library.moveToBin([item], context: context)
        } label: {
            Label("Move to Bin", systemImage: "trash")
        }
    }
}

// MARK: - Move sheet

struct MoveSheet: View {
    let folders: [Folder]
    let onPick: (Folder) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(folders) { folder in
                Button {
                    onPick(folder)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Group {
                            if let cover = folder.coverItem {
                                VaultThumbnail(id: cover.id)
                            } else {
                                Rectangle().fill(Theme.surface)
                                    .overlay(Image(systemName: "folder.fill").foregroundStyle(Theme.tertiaryText))
                            }
                        }
                        .frame(width: 64, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        Text(folder.name).foregroundStyle(.white)
                        Spacer()
                        Text("\(folder.activeItems.count)").foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Move to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Details sheet

struct MediaInfoSheet: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VaultThumbnail(id: item.id, size: .large)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    LabeledContent("Title", value: item.title)
                    LabeledContent("Type", value: item.kind == .video ? "Video" : "Photo")
                    if item.kind == .video { LabeledContent("Length", value: Format.clock(item.duration)) }
                    if item.pixelWidth > 0 { LabeledContent("Resolution", value: "\(item.pixelWidth) × \(item.pixelHeight)") }
                    LabeledContent("Size", value: Format.bytes(item.byteSize))
                    LabeledContent("Folder", value: item.folder?.name ?? "—")
                    LabeledContent("Imported", value: item.importedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Section {
                    Label("Encrypted on this device (AES-256-GCM)", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Empty state

struct EmptyVaultView: View {
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().fill(Theme.accent.opacity(0.12)).frame(width: 150, height: 150)
                Image(systemName: "play.rectangle.on.rectangle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.accentGradient)
            }
            Text("Your private screen")
                .font(.system(size: 28, weight: .heavy))
            Text("Import photos and videos. They're encrypted on this device and only open after Face ID or your PIN.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button(action: onImport) {
                Label("Import Photos & Videos", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .frame(height: 50)
                    .background(Color.white, in: Capsule())
                    .foregroundStyle(.black)
            }
            .buttonStyle(CardPressStyle())
            Spacer()
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Viewer routing

struct PhotoViewerContext: Identifiable {
    let id = UUID()
    let items: [MediaItem]
    let startID: UUID
}
