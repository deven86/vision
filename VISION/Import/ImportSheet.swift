import SwiftUI
import PhotosUI
import SwiftData

struct ImportSheet: View {
    var preselected: Folder?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ImportCoordinator.self) private var importer
    @Query(sort: \Folder.sortIndex) private var folders: [Folder]

    @State private var destinationID: UUID?
    @State private var newFolderName = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showFiles = false

    private var destination: Folder? {
        folders.first { $0.id == destinationID } ?? preselected ?? folders.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Save to") {
                    Picker("Folder", selection: $destinationID) {
                        ForEach(folders) { folder in
                            Text(folder.name).tag(Optional(folder.id))
                        }
                    }
                    HStack {
                        TextField("New folder name", text: $newFolderName)
                        Button("Create") {
                            let folder = Library.createFolder(named: newFolderName.trimmingCharacters(in: .whitespaces), context: context)
                            destinationID = folder.id
                            newFolderName = ""
                        }
                        .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section("Import from") {
                    PhotosPicker(selection: $pickerItems,
                                 matching: .any(of: [.images, .videos]),
                                 preferredItemEncoding: .current) {
                        Label("Photos Library", systemImage: "photo.on.rectangle.angled")
                    }
                    .disabled(destination == nil || importer.isRunning)

                    Button {
                        showFiles = true
                    } label: {
                        Label("Files", systemImage: "folder")
                    }
                    .disabled(destination == nil || importer.isRunning)
                }

                Section {
                    Label("Originals stay in Photos and Files. VISION stores an encrypted copy.",
                          systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .fileImporter(isPresented: $showFiles,
                          allowedContentTypes: [.image, .audiovisualContent, .data],
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result, let destination else { return }
                importer.importFiles(urls, into: destination, context: context)
                dismiss()
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty, let destination else { return }
                importer.importFromPhotos(items, into: destination, context: context)
                dismiss()
            }
            .onAppear {
                if folders.isEmpty { Library.createFolder(named: "My Vault", context: context) }
                destinationID = preselected?.id ?? folders.first?.id
            }
        }
        .presentationDetents([.medium, .large])
    }
}
