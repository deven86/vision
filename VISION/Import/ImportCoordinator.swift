import SwiftUI
import PhotosUI
import SwiftData
import CoreTransferable
import UniformTypeIdentifiers

struct StagedFile: Sendable {
    let url: URL
    let name: String
}

private func stage(_ received: ReceivedTransferredFile) throws -> StagedFile {
    let destination = VaultStore.shared.makeStagingURL(pathExtension: received.file.pathExtension)
    try FileManager.default.copyItem(at: received.file, to: destination)
    return StagedFile(url: destination, name: received.file.lastPathComponent)
}

struct StagedMovie: Transferable {
    let file: StagedFile
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { StagedMovie(file: try stage($0)) }
    }
}

struct StagedImage: Transferable {
    let file: StagedFile
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { StagedImage(file: try stage($0)) }
    }
}

enum ImportError: LocalizedError {
    case emptyItem
    var errorDescription: String? { "An item couldn't be loaded from Photos." }
}

/// Runs imports one item at a time (keeps memory flat for big batches) and reports progress.
/// Originals are never deleted — importing is a copy.
@MainActor
@Observable
final class ImportCoordinator {
    private(set) var isRunning = false
    private(set) var total = 0
    private(set) var completed = 0
    private(set) var failures: [String] = []
    private(set) var duplicates = 0
    @ObservationIgnored private var knownHashes: Set<String> = []
    private(set) var summary: String?

    var fractionComplete: Double { total == 0 ? 0 : Double(completed) / Double(total) }

    func importFromPhotos(_ items: [PhotosPickerItem], into folder: Folder, context: ModelContext) {
        guard !items.isEmpty, !isRunning else { return }
        begin(count: items.count, context: context)
        Task {
            for item in items {
                let hashes = knownHashes
                do {
                    let staged = try await Self.stage(item)
                    defer { try? FileManager.default.removeItem(at: staged.url) }
                    let result = try await Task.detached(priority: .userInitiated) {
                        try await MediaIngestor.ingest(fileAt: staged.url, displayName: staged.name, skipHashes: hashes)
                    }.value
                    insert(result, into: folder, context: context)
                } catch IngestError.duplicate {
                    duplicates += 1
                } catch {
                    failures.append(error.localizedDescription)
                }
                completed += 1
            }
            finish()
        }
    }

    func importFiles(_ urls: [URL], into folder: Folder, context: ModelContext) {
        guard !urls.isEmpty, !isRunning else { return }
        begin(count: urls.count, context: context)
        Task {
            for url in urls {
                let hashes = knownHashes
                let scoped = url.startAccessingSecurityScopedResource()
                do {
                    // Encrypt straight from the source — no plaintext copy is made.
                    let result = try await Task.detached(priority: .userInitiated) {
                        try await MediaIngestor.ingest(fileAt: url, displayName: url.lastPathComponent, skipHashes: hashes)
                    }.value
                    insert(result, into: folder, context: context)
                } catch IngestError.duplicate {
                    duplicates += 1
                } catch {
                    failures.append(error.localizedDescription)
                }
                if scoped { url.stopAccessingSecurityScopedResource() }
                completed += 1
            }
            finish()
        }
    }

    private static func stage(_ item: PhotosPickerItem) async throws -> StagedFile {
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            guard let movie = try await item.loadTransferable(type: StagedMovie.self) else { throw ImportError.emptyItem }
            return movie.file
        }
        guard let image = try await item.loadTransferable(type: StagedImage.self) else { throw ImportError.emptyItem }
        return image.file
    }

    /// Files items that the Share Extension already encrypted into the vault.
    func collectInbox(context: ModelContext) {
        guard !isRunning else { return }
        let pending = SharedInbox.pending()
        guard !pending.isEmpty else { return }
        let folders = (try? context.fetch(FetchDescriptor<Folder>())) ?? []
        let folder = folders.first { $0.name == Self.sharedFolderName }
            ?? Library.createFolder(named: Self.sharedFolderName, context: context)
        var added = 0
        knownHashes = Self.activeHashes(context)
        for entry in pending {
            let id = entry.result.id
            let exists = ((try? context.fetchCount(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.id == id }))) ?? 0) > 0
            if !exists, let hash = entry.result.contentHash, knownHashes.contains(hash) {
                VaultStore.shared.removeFiles(for: id)   // already in the vault: discard the shared copy
            } else if !exists {
                insert(entry.result, into: folder, context: context)
                added += 1
            }
            SharedInbox.remove(entry)   // only after the item is saved in the library
        }
        guard added > 0 else { return }
        summary = "Added \(added) item\(added == 1 ? "" : "s") shared from other apps to “\(Self.sharedFolderName)”"
        Task {
            try? await Task.sleep(for: .seconds(4))
            if !isRunning { summary = nil }
        }
    }

    static let sharedFolderName = "Shared to VISION"

    static func activeHashes(_ context: ModelContext) -> Set<String> {
        let items = (try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt == nil && $0.contentHash != nil }))) ?? []
        return Set(items.compactMap(\.contentHash))
    }

    private func insert(_ result: IngestResult, into folder: Folder, context: ModelContext) {
        let item = MediaItem(id: result.id, kind: result.kind, title: result.title,
                             contentTypeID: result.contentTypeID, byteSize: result.byteSize,
                             duration: result.duration, pixelWidth: result.pixelWidth, pixelHeight: result.pixelHeight)
        item.usesVLC = result.usesVLC
        item.contentHash = result.contentHash
        if let hash = result.contentHash { knownHashes.insert(hash) }
        context.insert(item)
        item.folder = folder
        Library.save(context)
    }

    private func begin(count: Int, context: ModelContext) {
        isRunning = true
        total = count
        completed = 0
        failures = []
        duplicates = 0
        knownHashes = Self.activeHashes(context)
        summary = nil
    }

    private func finish() {
        isRunning = false
        let imported = total - failures.count - duplicates
        var text = "Imported \(imported) of \(total)"
        if duplicates > 0 { text += " · \(duplicates) already in your vault, skipped" }
        if let first = failures.first {
            text += failures.count == 1 ? " — \(first)" : " — \(failures.count) failed. \(first)"
        }
        summary = text
        Task {
            try? await Task.sleep(for: .seconds(failures.isEmpty ? 3 : 8))
            if !isRunning { summary = nil }
        }
    }
}

struct ImportProgressBanner: View {
    @Environment(ImportCoordinator.self) private var importer

    var body: some View {
        Group {
            if importer.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill").foregroundStyle(Theme.accent)
                        Text("Encrypting \(min(importer.completed + 1, importer.total)) of \(importer.total)")
                            .font(.subheadline.weight(.semibold))
                    }
                    ProgressView(value: importer.fractionComplete).tint(Theme.accent)
                }
                .frame(maxWidth: 360)
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let summary = importer.summary {
                Label(summary, systemImage: importer.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(3)
                    .padding(14)
                    .frame(maxWidth: 360)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: importer.isRunning)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: importer.summary)
    }
}
