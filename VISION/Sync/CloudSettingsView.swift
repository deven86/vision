import SwiftUI
import SwiftData
import CryptoKit

struct CloudSettingsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKeys.syncLibrary) private var syncLibrary = false
    @AppStorage(SettingsKeys.syncMedia) private var syncMedia = false
    @AppStorage(SettingsKeys.syncWiFiOnly) private var wifiOnly = true
    @AppStorage(SettingsKeys.syncAutoDownload) private var autoDownload = false
    @AppStorage("sync.recoveryCodeMade") private var recoveryCodeMade = false

    @State private var showRecovery = false
    @State private var showJoin = false

    private var sync: CloudSync { .shared }
    private var transfer: MediaTransfer { .shared }

    var body: some View {
        Form {
            Section {
                Toggle("Sync library", isOn: $syncLibrary)
                    .onChange(of: syncLibrary) { _, on in
                        Task { on ? await sync.start(context: context) : sync.stop() }
                    }
            } footer: {
                Text("Keeps folders, covers, favorites, watch progress and the Recovery Bin the same on your iPhone and iPad (same Apple ID). Everything is encrypted on this device first — Apple can't read titles, folder names or thumbnails.")
            }

            if syncLibrary {
                Section("Status") {
                    statusRow
                    if sync.status == .keyMismatch {
                        Button("Join your iCloud vault…") { showJoin = true }
                            .foregroundStyle(Theme.accent)
                    }
                    if let last = sync.lastSync {
                        LabeledContent("Last sync", value: last.formatted(.relative(presentation: .named)))
                    }
                    Button("Sync Now") { Task { await sync.syncNow() } }
                        .disabled(!sync.isVaultKeyOK)
                }

                Section {
                    Toggle("Back up photos & videos", isOn: $syncMedia)
                        .onChange(of: syncMedia) { _, on in if on { transfer.kick() } }
                    Toggle("Use Wi-Fi only", isOn: $wifiOnly)
                    Toggle("Download everything to this device", isOn: $autoDownload)
                        .onChange(of: autoDownload) { _, on in if on { transfer.kick() } }
                    if syncMedia { transferRows }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Uploads VISION's encrypted files to your iCloud storage, so you can restore after losing a device and open items on your other devices. Large videos use a lot of iCloud space. Interrupted uploads continue where they stopped. Permanently deleting an item also deletes its iCloud copy.")
                }

                Section {
                    Button(recoveryCodeMade ? "Make a New Recovery Code" : "Create Recovery Code") { showRecovery = true }
                        .disabled(!sync.isVaultKeyOK)
                } header: {
                    Text("Recovery")
                } footer: {
                    Text("Your vault key also syncs through iCloud Keychain. The recovery code is your backup if you ever lose access to your Apple ID or iCloud Keychain. Without the key, backups can't be opened by anyone — including you.")
                }
            }

            if !CloudConfig.isProvisioned {
                Section {
                    Label("iCloud isn't enabled in this build yet.", systemImage: "icloud.slash")
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("iCloud Sync & Backup")
        .sheet(isPresented: $showRecovery) { RecoveryCodeView { recoveryCodeMade = true } }
        .sheet(isPresented: $showJoin) { JoinVaultView() }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch sync.status {
        case .off: Label("Off", systemImage: "icloud.slash")
        case .notProvisioned: Label("Not available in this build", systemImage: "icloud.slash")
        case .starting, .syncing: Label("Syncing…", systemImage: "arrow.triangle.2.circlepath.icloud")
        case .idle: Label("Up to date", systemImage: "checkmark.icloud").foregroundStyle(.green)
        case .noAccount: Label("Sign in to iCloud in iPhone Settings", systemImage: "person.crop.circle.badge.exclamationmark")
        case .keyMismatch: Label("This device has a different vault key", systemImage: "key.slash").foregroundStyle(Theme.accent)
        case .error(let message): Label(message, systemImage: "exclamationmark.icloud").foregroundStyle(Theme.accent)
        }
    }

    @ViewBuilder
    private var transferRows: some View {
        if transfer.waitingForWiFi {
            Label("Waiting for Wi-Fi", systemImage: "wifi.exclamationmark")
        } else if let title = transfer.activeTitle {
            VStack(alignment: .leading, spacing: 6) {
                Text("Uploading “\(title)”").font(.subheadline).lineLimit(1)
                ProgressView(value: transfer.activeProgress).tint(Theme.accent)
                Text("\(transfer.pendingUploads) item\(transfer.pendingUploads == 1 ? "" : "s") left")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
            }
        } else if transfer.pendingUploads == 0 {
            Label("All backed up", systemImage: "checkmark.icloud").foregroundStyle(.green)
        }
        if let error = transfer.lastError {
            Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.accent)
        }
    }
}

// MARK: - Recovery code

struct RecoveryCodeView: View {
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var code = RecoveryCode.generate()
    @State private var step = 0
    @State private var confirmation = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                if step == 0 {
                    Section {
                        Text(code)
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    } footer: {
                        Text("Write this down on paper and keep it somewhere safe. Don't screenshot it or keep it in Notes, Photos or email. VISION can't show it again or reset it.")
                    }
                    Section {
                        Button("I've written it down") { step = 1 }
                    }
                } else {
                    Section {
                        TextField("Type the whole code", text: $confirmation, axis: .vertical)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    } footer: {
                        if let error { Text(error).foregroundStyle(.red) } else { Text("This checks that the code you wrote down is right.") }
                    }
                    Section {
                        Button(saving ? "Saving…" : "Confirm & Save") { confirm() }.disabled(saving)
                        Button("Show the code again") { step = 0; confirmation = "" }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Recovery Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func confirm() {
        guard let typed = RecoveryCode.parse(confirmation), let original = RecoveryCode.parse(code), typed == original else {
            error = "That doesn't match. Check each group of 4 characters."
            return
        }
        saving = true
        Task {
            do {
                try await CloudSync.shared.saveRecoveryEscrow(code: original)
                onSaved()
                dismiss()
            } catch {
                self.error = CloudSync.describe(error)
            }
            saving = false
        }
    }
}

// MARK: - Join the iCloud vault (device with a different key)

struct JoinVaultView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var working = false
    @State private var progress: (Int, Int) = (0, 0)
    @State private var message: String?

    private var keychainKey: SymmetricKey? {
        guard let key = MasterKey.readSynced(), MasterKey.identifier(of: key) == CloudSync.shared.remoteKeyID else { return nil }
        return key
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Your iCloud already has a VISION vault from another device, using a different key. Joining converts this device's files to that key (nothing is re-downloaded or lost), then syncs both libraries together.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
                if working {
                    Section {
                        ProgressView(value: Double(progress.0), total: Double(max(progress.1, 1)))
                            .tint(Theme.accent)
                        Text("Converting \(progress.0) of \(progress.1) files… keep VISION open.").font(.footnote)
                    }
                } else {
                    if let key = keychainKey {
                        Section {
                            Button("Join using iCloud Keychain") { join(with: key) }
                        } footer: {
                            Text("The vault key is already on this device through iCloud Keychain.")
                        }
                    }
                    if CloudSync.shared.remoteEscrow != nil {
                        Section {
                            TextField("Recovery code", text: $code, axis: .vertical)
                                .font(.system(.body, design: .monospaced))
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                            Button("Join using Recovery Code") { joinWithCode() }
                        }
                    } else if keychainKey == nil {
                        Section {
                            Text("Turn on iCloud Keychain on this device (iPhone Settings → your name → iCloud → Passwords and Keychain), or create a recovery code on your other device first.")
                                .font(.footnote)
                        }
                    }
                }
                if let message {
                    Section { Text(message).font(.footnote).foregroundStyle(Theme.accent) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Join iCloud Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(working) } }
            .interactiveDismissDisabled(working)
        }
    }

    private func joinWithCode() {
        guard let data = RecoveryCode.parse(code), let escrow = CloudSync.shared.remoteEscrow else {
            message = "Enter all 32 characters of the code."
            return
        }
        do { join(with: try KeyEscrow.open(escrow, code: data)) } catch { message = error.localizedDescription }
    }

    private func join(with key: SymmetricKey) {
        working = true
        message = nil
        Task {
            do {
                let report = try await CloudSync.shared.join(using: key) { done, total in progress = (done, total) }
                if report.failed.isEmpty {
                    dismiss()
                } else {
                    message = "\(report.failed.count) file(s) couldn't be converted, so nothing was changed. Your vault is untouched."
                }
            } catch {
                message = error.localizedDescription
            }
            working = false
        }
    }
}
