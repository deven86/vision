import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// "Save to VISION" in the iOS share sheet.
///
/// Write-only drop box: it encrypts shared photos/videos straight into the vault and
/// leaves an encrypted note for the app. It never shows or lists vault contents, so it
/// doesn't need Face ID / PIN.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let host = UIHostingController(rootView: ShareView(model: model, onDone: { [weak self] in self?.finish() }))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        model.start(providers)
    }

    private func finish() {
        model.cancel()
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@MainActor
@Observable
final class ShareModel {
    enum State: Equatable { case working, done, failed(String) }

    private(set) var state: State = .working
    private(set) var total = 0
    private(set) var saved = 0
    private(set) var failures: [String] = []
    private var task: Task<Void, Never>?

    func start(_ providers: [NSItemProvider]) {
        let media = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        total = media.count
        guard total > 0 else {
            state = .failed("Only photos and videos can be saved to VISION.")
            return
        }
        task = Task {
            VaultStore.shared.prepareDirectories(purgeStaging: false)
            for provider in media {
                if Task.isCancelled { break }
                do {
                    let staged = try await Self.stage(provider)
                    defer { try? FileManager.default.removeItem(at: staged.url) }
                    let result = try await MediaIngestor.ingest(fileAt: staged.url, displayName: staged.name)
                    do {
                        try SharedInbox.deposit(result)
                        saved += 1
                    } catch {
                        VaultStore.shared.removeFiles(for: result.id)   // no orphaned vault files
                        throw error
                    }
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            state = saved > 0 ? .done : .failed(failures.first ?? "Nothing could be saved.")
        }
    }

    func cancel() { task?.cancel() }

    private struct Staged { let url: URL; let name: String }

    /// Copies the shared file into our private, protected temp folder (the system deletes
    /// its own copy as soon as the callback returns). Deleted right after encryption.
    private static func stage(_ provider: NSItemProvider) async throws -> Staged {
        let type: UTType = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ? .movie : .image
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                if let url {
                    do {
                        let destination = VaultStore.shared.makeStagingURL(pathExtension: url.pathExtension)
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                                withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: url, to: destination)
                        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                                               ofItemAtPath: destination.path)
                        let name = provider.suggestedName.map { $0 + "." + url.pathExtension } ?? url.lastPathComponent
                        continuation.resume(returning: Staged(url: destination, name: name))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                // Some apps share images only as in-memory data, not as a file.
                guard type == .image else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                    guard let data else {
                        continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                        return
                    }
                    let ext = provider.registeredContentTypes.first { $0.conforms(to: .image) }?
                        .preferredFilenameExtension ?? "jpg"
                    let destination = VaultStore.shared.makeStagingURL(pathExtension: ext)
                    do {
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                                withIntermediateDirectories: true)
                        try data.write(to: destination, options: [.completeFileProtection])
                        continuation.resume(returning: Staged(url: destination,
                                                              name: (provider.suggestedName ?? "Shared photo") + "." + ext))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}

struct ShareView: View {
    let model: ShareModel
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 18) {
                Wordmark(size: 26)
                switch model.state {
                case .working:
                    ProgressView(value: Double(model.saved), total: Double(max(model.total, 1)))
                        .tint(Theme.accent)
                    Text("Encrypting \(min(model.saved + 1, model.total)) of \(model.total)…")
                        .font(.subheadline.weight(.semibold))
                    Text("Keep this open until it finishes.")
                        .font(.footnote).foregroundStyle(Theme.secondaryText)
                    Button("Cancel", role: .cancel, action: onDone)
                        .foregroundStyle(Theme.secondaryText)
                case .done:
                    Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(Theme.accent)
                    Text("Saved \(model.saved) of \(model.total) to VISION")
                        .font(.headline)
                    Text(model.failures.isEmpty
                         ? "Encrypted. You'll find them in “Shared to VISION” next time you unlock the app. The originals were not deleted."
                         : "\(model.failures.count) couldn't be saved: \(model.failures.first ?? "")")
                        .font(.footnote).foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                    doneButton
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 30)).foregroundStyle(Theme.accent)
                    Text(message).font(.subheadline).multilineTextAlignment(.center)
                    doneButton
                }
            }
            .padding(24)
            .frame(maxWidth: 420)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.08)))
            .padding(16)
            .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
    }

    private var doneButton: some View {
        Button(action: onDone) {
            Text("Done").font(.headline).frame(maxWidth: .infinity).frame(height: 48)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.black)
        }
    }
}
