import SwiftUI
import SwiftData

enum FolderSort: String, CaseIterable, Identifiable {
    case newest = "Newest", oldest = "Oldest", name = "Name", largest = "Largest"
    var id: String { rawValue }
}

struct FolderDetailView: View {
    let folder: Folder

    @Environment(\.modelContext) private var context
    @Environment(ExportPresenter.self) private var exporter
    @Query(sort: \Folder.sortIndex) private var folders: [Folder]

    @State private var sort: FolderSort = .newest
    @State private var filter: MediaFilter = .all
    @State private var selecting = false
    @State private var selection = Set<UUID>()
    @State private var playing: MediaItem?
    @State private var viewer: PhotoViewerContext?
    @State private var downloadRequest: DownloadRequest?
    @State private var showImport = false
    @State private var showMove = false
    @State private var confirmDelete = false

    private let columns = [GridItem(.adaptive(minimum: 112), spacing: 3)]

    private var items: [MediaItem] {
        let list = filter.apply(folder.activeItems)
        switch sort {
        case .newest: return list
        case .oldest: return list.reversed()
        case .name: return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .largest: return list.sorted { $0.byteSize > $1.byteSize }
        }
    }

    private var selectedItems: [MediaItem] { items.filter { selection.contains($0.id) } }

    var body: some View {
        ScrollView {
            if items.isEmpty {
                ContentUnavailableView("No media here",
                                       systemImage: "photo.stack",
                                       description: Text("Tap + to import photos and videos into \(folder.name)."))
                    .padding(.top, 80)
            }
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(items) { item in
                    GridCell(item: item, selecting: selecting, selected: selection.contains(item.id))
                        .onTapGesture { tap(item) }
                        .contextMenu {
                            if !selecting { MediaContextMenu(item: item, folders: folders) }
                        }
                }
            }
        }
        .background(Theme.background)
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) {
            if selecting { selectionBar }
        }
        .sheet(isPresented: $showImport) { ImportSheet(preselected: folder) }
        .sheet(isPresented: $showMove) {
            MoveSheet(folders: folders.filter { $0.id != folder.id }) { destination in
                Library.move(selectedItems, to: destination, context: context)
                endSelection()
            }
        }
        .confirmationDialog("Move \(selection.count) items to the Bin?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Move to Bin", role: .destructive) {
                Library.moveToBin(selectedItems, context: context)
                endSelection()
            }
        }
        .fullScreenCover(item: $playing) { PlayerScreen(item: $0) }
        .fullScreenCover(item: $viewer) { PhotoViewer(context: $0) }
        .sheet(item: $downloadRequest) { CloudDownloadSheet(request: $0) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if !selecting {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(FolderSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Show", selection: $filter) {
                        ForEach(MediaFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                Button { showImport = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Import into this folder")
            }
            Button(selecting ? "Done" : "Select") {
                if selecting { endSelection() } else { selecting = true }
            }
        }
    }

    private var selectionBar: some View {
        HStack {
            Button {
                for item in selectedItems { item.isFavorite = true }
                Library.save(context)
                endSelection()
            } label: { Label("Favorite", systemImage: "heart") }
            Spacer()
            Button {
                exporter.export(selectedItems)
                endSelection()
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
            Spacer()
            Button { showMove = true } label: { Label("Move", systemImage: "folder") }
            Spacer()
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .font(.subheadline.weight(.semibold))
        .disabled(selection.isEmpty)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private func tap(_ item: MediaItem) {
        if selecting {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            UISelectionFeedbackGenerator().selectionChanged()
        } else if !VaultStore.shared.hasMedia(item.id) {
            downloadRequest = DownloadRequest(item: item) { tap(item) }
        } else if item.kind == .video {
            playing = item
        } else {
            viewer = PhotoViewerContext(items: items.filter { $0.kind == .photo }, startID: item.id)
        }
    }

    private func endSelection() {
        selecting = false
        selection.removeAll()
    }
}

struct GridCell: View {
    let item: MediaItem
    let selecting: Bool
    let selected: Bool

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { VaultThumbnail(id: item.id, size: .small) }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if item.kind == .video {
                    Text(Format.clock(item.duration))
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.isFavorite {
                    Image(systemName: "heart.fill").font(.caption2).foregroundStyle(Theme.accent).padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(selected ? Color.black : Color.white, selected ? Theme.accent : Color.black.opacity(0.3))
                        .padding(6)
                }
            }
            .overlay {
                if selecting && selected { Rectangle().stroke(Theme.accent, lineWidth: 3) }
            }
            .foregroundStyle(.white)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.kind == .video ? "Video" : "Photo"), \(item.title)")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
