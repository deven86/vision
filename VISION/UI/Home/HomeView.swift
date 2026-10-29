import SwiftUI
import SwiftData

enum MediaFilter: String, CaseIterable, Identifiable {
    case all = "All", videos = "Videos", photos = "Photos", favorites = "Favorites"
    var id: String { rawValue }

    func apply(_ items: [MediaItem]) -> [MediaItem] {
        switch self {
        case .all: return items
        case .videos: return items.filter { $0.kind == .video }
        case .photos: return items.filter { $0.kind == .photo }
        case .favorites: return items.filter(\.isFavorite)
        }
    }
}

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(AuthService.self) private var auth
    @Environment(\.horizontalSizeClass) private var hSize

    @Query(filter: #Predicate<MediaItem> { $0.deletedAt == nil },
           sort: \MediaItem.importedAt, order: .reverse)
    private var items: [MediaItem]
    @Query(sort: \Folder.sortIndex) private var folders: [Folder]

    @AppStorage(SettingsKeys.heroPreview) private var heroPreviewEnabled = true
    @State private var filter: MediaFilter = .all
    @State private var scrollY: CGFloat = 0
    @State private var playing: MediaItem?
    @State private var viewer: PhotoViewerContext?
    @State private var showImport = false
    @State private var path = NavigationPath()

    private var filtered: [MediaItem] { filter.apply(items) }
    private var isWide: Bool { hSize == .regular }
    private var cardWidth: CGFloat { isWide ? 270 : 172 }
    private var heroHeight: CGFloat { isWide ? 600 : 520 }

    private var hero: MediaItem? {
        let pool = filtered
        return pool.first { $0.kind == .video && $0.isFavorite }
            ?? pool.first { $0.kind == .video }
            ?? pool.first
    }

    private var continueWatching: [MediaItem] {
        filtered
            .filter { $0.kind == .video && $0.watchPosition > 5 && $0.progress < 0.95 }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .top) {
                Theme.background.ignoresSafeArea()
                if items.isEmpty {
                    EmptyVaultView { showImport = true }
                } else {
                    content
                }
                topBar
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Folder.self) { FolderDetailView(folder: $0) }
        }
        .sheet(isPresented: $showImport) { ImportSheet() }
        .fullScreenCover(item: $playing) { PlayerScreen(item: $0) }
        .fullScreenCover(item: $viewer) { PhotoViewer(context: $0) }
    }

    // MARK: Content

    private var content: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                if let hero {
                    HeroBanner(item: hero,
                               height: heroHeight,
                               previewEnabled: heroPreviewEnabled && playing == nil && viewer == nil,
                               onPlay: { open(hero, in: filtered) },
                               onToggleFavorite: { Library.toggleFavorite(hero, context: context) })
                } else {
                    Color.clear.frame(height: 150)
                    Text("Nothing here yet").font(.title3.bold()).padding(.horizontal, 16)
                }

                if !continueWatching.isEmpty {
                    MediaRow(title: "Continue Watching", items: continueWatching, cardWidth: cardWidth,
                             showProgress: true, folders: folders) { open($0, in: continueWatching) }
                }

                let recent = Array(filtered.prefix(24))
                if !recent.isEmpty {
                    MediaRow(title: "Recently Added", items: recent, cardWidth: cardWidth,
                             folders: folders) { open($0, in: recent) }
                }

                if filter != .favorites {
                    let favorites = filtered.filter(\.isFavorite)
                    if !favorites.isEmpty {
                        MediaRow(title: "Favorites", items: favorites, cardWidth: cardWidth,
                                 folders: folders) { open($0, in: favorites) }
                    }
                }

                ForEach(folders) { folder in
                    let rowItems = filtered.filter { $0.folder?.id == folder.id }
                    if !rowItems.isEmpty {
                        MediaRow(title: folder.name, items: rowItems, cardWidth: cardWidth, folders: folders,
                                 onSeeAll: { path.append(folder) }) { open($0, in: rowItems) }
                    }
                }
            }
            .padding(.bottom, 110)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ScrollOffsetKey.self, value: geo.frame(in: .named("home")).minY)
                }
            )
        }
        .coordinateSpace(name: "home")
        .onPreferenceChange(ScrollOffsetKey.self) { scrollY = $0 }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: Top bar — transparent over the hero, frosts in as you scroll

    private var topBar: some View {
        let solidity = min(1, max(0, -scrollY / 260))
        return VStack(spacing: 12) {
            HStack(spacing: 20) {
                Wordmark(size: 24)
                Spacer()
                Button { showImport = true } label: {
                    Image(systemName: "plus").font(.title3.weight(.semibold))
                }
                .accessibilityLabel("Import")
                Button { auth.lock() } label: {
                    Image(systemName: "lock.fill").font(.title3)
                }
                .accessibilityLabel("Lock vault")
            }
            .foregroundStyle(.white)
            if !items.isEmpty { filterChips }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Theme.background.opacity(0.7)
            }
            .opacity(solidity)
            .ignoresSafeArea(edges: .top)
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MediaFilter.allCases) { option in
                    let selected = filter == option
                    Button {
                        withAnimation(.snappy) { filter = option }
                    } label: {
                        Text(option.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 15)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.06)))
                            .overlay(Capsule().stroke(Color.white.opacity(selected ? 0 : 0.4), lineWidth: 1))
                            .foregroundStyle(selected ? Color.black : Color.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func open(_ item: MediaItem, in list: [MediaItem]) {
        if item.kind == .video {
            playing = item
        } else {
            viewer = PhotoViewerContext(items: list.filter { $0.kind == .photo }, startID: item.id)
        }
    }
}
