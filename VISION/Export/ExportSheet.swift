import SwiftUI
import UIKit

/// Step 1: explain + options. Step 2: decrypt with progress. Step 3: system share sheet.
struct ExportSheet: View {
    let items: [MediaItem]
    var onFinished: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @AppStorage("export.stripMetadata") private var stripMetadata = true
    @State private var phase: Phase = .confirm
    @State private var done = 0
    @State private var task: Task<Void, Never>?

    enum Phase: Equatable {
        case confirm
        case working
        case sharing([URL])
        case failed(String)
    }

    private var totalBytes: Int64 { items.reduce(0) { $0 + $1.byteSize } }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .confirm: confirmView
                case .working: workingView
                case .sharing(let urls):
                    ActivityView(items: urls) { _ in
                        ExportService.cleanup(urls)
                        onFinished()
                        dismiss()
                    }
                    .ignoresSafeArea()
                case .failed(let message): failedView(message)
                }
            }
            .background(Theme.background)
            .navigationTitle(phase == .confirm ? "Export" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if phase == .confirm || phase == .working {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            task?.cancel()
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents(phase == .confirm ? [.medium, .large] : [.large])
        .interactiveDismissDisabled(phase == .working)
    }

    private var confirmView: some View {
        Form {
            Section {
                Label {
                    Text("\(items.count) item\(items.count == 1 ? "" : "s") · \(Format.bytes(totalBytes))")
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            Section {
                Toggle("Remove location & camera data", isOn: $stripMetadata)
            } footer: {
                Text("Removes GPS location and camera details from the exported copy. The original in your vault is not changed.")
            }
            Section {
                Label("Exported copies are NOT encrypted. Wherever you save or send them, that app or person can keep them.",
                      systemImage: "lock.open.trianglebadge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(Theme.accent)
            }
            Section {
                Button {
                    start()
                } label: {
                    Text("Decrypt & Share")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var workingView: some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView(value: Double(done), total: Double(max(items.count, 1)))
                .tint(Theme.accent)
                .padding(.horizontal, 40)
            Text("Preparing \(min(done + 1, items.count)) of \(items.count)…")
                .font(.subheadline.weight(.semibold))
            Text("Large videos can take a moment.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
            Spacer()
        }
        .foregroundStyle(.white)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(Theme.accent)
            Text(message).multilineTextAlignment(.center).padding(.horizontal, 30)
            Button("Close") { dismiss() }.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
            Spacer()
        }
        .foregroundStyle(.white)
    }

    private func start() {
        let requests = items.map {
            ExportRequest(id: $0.id, title: $0.title, kind: $0.kind, contentTypeID: $0.contentTypeID, byteSize: $0.byteSize)
        }
        let strip = stripMetadata
        phase = .working
        done = 0
        task = Task {
            do {
                let urls = try await ExportService.export(requests, stripMetadata: strip) { finished in
                    Task { @MainActor in done = finished }
                }
                if Task.isCancelled {
                    ExportService.cleanup(urls)
                    return
                }
                phase = .sharing(urls)
            } catch ExportError.cancelled {
                // dismissed by the user
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

/// UIActivityViewController wrapper: Save to Files, Save Image/Video to Photos, AirDrop, apps.
struct ActivityView: UIViewControllerRepresentable {
    let items: [URL]
    let onComplete: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in onComplete(completed) }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ExportBatch: Identifiable {
    let id = UUID()
    let items: [MediaItem]
}

/// App-wide "export these items" request, so any context menu can trigger the sheet.
@MainActor
@Observable
final class ExportPresenter {
    var batch: ExportBatch?

    func export(_ items: [MediaItem]) {
        guard !items.isEmpty else { return }
        batch = ExportBatch(items: items)
    }
}
