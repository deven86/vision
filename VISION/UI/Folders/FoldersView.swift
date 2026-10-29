import SwiftUI
import SwiftData

struct FoldersView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Folder.sortIndex) private var folders: [Folder]

    @State private var showNew = false
    @State private var newName = ""
    @State private var renaming: Folder?
    @State private var renameText = ""
    @State private var deleting: Folder?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(folders) { folder in
                    NavigationLink(value: folder) {
                        FolderTile(folder: folder)
                    }
                    .buttonStyle(CardPressStyle())
                    .contextMenu {
                        Button {
                            renameText = folder.name
                            renaming = folder
                        } label: { Label("Rename", systemImage: "pencil") }
                        if folder.coverItemID != nil {
                            Button {
                                folder.coverItemID = nil
                                Library.save(context)
                            } label: { Label("Reset Cover", systemImage: "photo.badge.arrow.down") }
                        }
                        Button(role: .destructive) { deleting = folder } label: {
                            Label("Delete Folder", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Folders")
        .navigationDestination(for: Folder.self) { FolderDetailView(folder: $0) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newName = ""
                    showNew = true
                } label: { Image(systemName: "folder.badge.plus") }
                .accessibilityLabel("New folder")
            }
        }
        .alert("New Folder", isPresented: $showNew) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { Library.createFolder(named: name, context: context) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let renaming { Library.rename(renaming, to: renameText, context: context) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this folder?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible,
                            presenting: deleting) { folder in
            Button("Delete and Move \(folder.activeItems.count) Items to Bin", role: .destructive) {
                Library.deleteFolder(folder, context: context)
            }
        } message: { _ in
            Text("The folder is removed. Its photos and videos stay recoverable in the Bin.")
        }
    }
}

struct FolderTile: View {
    let folder: Folder

    var body: some View {
        let items = folder.activeItems
        let videos = items.filter { $0.kind == .video }.count
        ZStack(alignment: .bottomLeading) {
            Group {
                if let cover = folder.coverItem {
                    VaultThumbnail(id: cover.id, size: .large)
                } else {
                    Rectangle()
                        .fill(LinearGradient(colors: [Theme.surfaceRaised, Theme.surface], startPoint: .top, endPoint: .bottom))
                        .overlay(Image(systemName: "folder.fill").font(.system(size: 34)).foregroundStyle(Theme.tertiaryText))
                }
            }
            LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).font(.headline).lineLimit(1)
                Text("\(items.count) items" + (videos > 0 ? " • \(videos) videos" : ""))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(10)
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.06)))
        .foregroundStyle(.white)
    }
}
