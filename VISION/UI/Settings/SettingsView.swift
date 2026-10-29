import SwiftUI

struct SettingsView: View {
    @Environment(AuthService.self) private var auth
    @AppStorage(SettingsKeys.biometricsEnabled) private var biometrics = true
    @AppStorage(SettingsKeys.autoLockSeconds) private var autoLock = 0
    @AppStorage(SettingsKeys.heroPreview) private var heroPreview = true
    @AppStorage(SettingsKeys.binRetentionDays) private var retention = 30

    @State private var showChangePIN = false
    @State private var mediaBytes: Int64 = 0
    @State private var thumbnailBytes: Int64 = 0

    var body: some View {
        Form {
            Section("Security") {
                if auth.canUseBiometrics {
                    Toggle(auth.biometryType == .faceID ? "Unlock with Face ID" : "Unlock with Touch ID",
                           isOn: $biometrics)
                }
                Picker("Auto-Lock", selection: $autoLock) {
                    Text("Immediately").tag(0)
                    Text("After 1 minute").tag(60)
                    Text("After 5 minutes").tag(300)
                    Text("After 15 minutes").tag(900)
                }
                Button("Change PIN") { showChangePIN = true }
                Button("Lock Now") { auth.lock() }
            }

            Section {
                Toggle("Autoplay previews on Home", isOn: $heroPreview)
            } header: {
                Text("Playback")
            } footer: {
                Text("Plays a muted preview of the featured video after a moment.")
            }

            Section("Recovery Bin") {
                Picker("Keep deleted items", selection: $retention) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("60 days").tag(60)
                }
            }

            Section("Storage") {
                LabeledContent("Vault", value: Format.bytes(mediaBytes))
                LabeledContent("Thumbnails", value: Format.bytes(thumbnailBytes))
                Button("Clear Memory Cache") { ThumbnailCache.shared.purge() }
            }

            Section {
                Text("Videos: MP4, MOV, M4V (H.264 and HEVC, up to 4K). Photos: HEIC, JPEG, PNG, GIF (first frame), TIFF, RAW supported by iOS.")
                Text("Not yet: MKV, AVI, WMV, FLV. These are rejected at import with a clear message.")
                    .foregroundStyle(Theme.secondaryText)
            } header: {
                Text("Supported Formats")
            }
            .font(.footnote)

            Section("About") {
                LabeledContent("Version", value: Bundle.main.versionString)
                Text("Media is encrypted on this device with AES-256-GCM using a key that never leaves it. iCloud backup and sync are not enabled yet, so keep originals elsewhere until they are.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Settings")
        .task {
            let usage = await Task.detached { VaultStore.shared.diskUsage() }.value
            mediaBytes = usage.media
            thumbnailBytes = usage.thumbnails
        }
        .sheet(isPresented: $showChangePIN) { ChangePINView() }
    }
}

struct ChangePINView: View {
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Current PIN", text: $current).keyboardType(.numberPad)
                    SecureField("New 6-digit PIN", text: $new).keyboardType(.numberPad)
                    SecureField("Confirm new PIN", text: $confirm).keyboardType(.numberPad)
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Change PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(saving)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard PINHasher.isValidPIN(new) else { error = "The new PIN must be exactly 6 digits."; return }
        guard new == confirm else { error = "The new PINs don't match."; return }
        saving = true
        Task {
            let ok = await auth.changePIN(current: current, new: new)
            saving = false
            if ok { dismiss() } else { error = "Current PIN is wrong, or you're in a timeout."; current = "" }
        }
    }
}
