import SwiftUI

struct DownloadRequest: Identifiable {
    let id = UUID()
    let item: MediaItem
    let then: () -> Void
}

/// Shown when an item synced from another device isn't on this one yet.
struct CloudDownloadSheet: View {
    let request: DownloadRequest
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        VStack(spacing: 18) {
            VaultThumbnail(id: request.item.id, size: .large)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 24)
            Text(request.item.title).font(.headline).lineLimit(2)
            if let error {
                Label(error, systemImage: "exclamationmark.icloud")
                    .font(.footnote)
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
            } else {
                ProgressView(value: MediaTransfer.shared.downloadProgress[request.item.id] ?? 0)
                    .tint(Theme.accent)
                    .padding(.horizontal, 40)
                Text("Downloading from iCloud · \(Format.bytes(request.item.byteSize))")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                Text("Checked for damage before it opens.")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .presentationDetents([.medium])
        .interactiveDismissDisabled(error == nil)
        .task {
            do {
                try await MediaTransfer.shared.ensureLocal(request.item)
                dismiss()
                try? await Task.sleep(for: .milliseconds(450))
                request.then()
            } catch {
                self.error = CloudSync.describe(error)
            }
        }
    }
}
