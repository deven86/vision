import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(AuthService.self) private var auth
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKeys.autoLockSeconds) private var autoLockSeconds = 0
    @State private var backgroundedAt: Date?

    var body: some View {
        ZStack {
            if auth.isUnlocked {
                MainTabView().transition(.opacity)
            } else {
                LockView().transition(.opacity)
            }
            // Covers the app-switcher snapshot so private media never shows there.
            if scenePhase != .active {
                PrivacyCover().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: auth.isUnlocked)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                backgroundedAt = Date()
                if autoLockSeconds == 0 { auth.lock() }
            case .active:
                if let since = backgroundedAt, Date().timeIntervalSince(since) >= Double(autoLockSeconds) {
                    auth.lock()
                }
                backgroundedAt = nil
            default:
                break
            }
        }
    }
}

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            Wordmark(size: 34)
        }
    }
}

struct MainTabView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKeys.binRetentionDays) private var retentionDays = 30

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
            NavigationStack { FoldersView() }
                .tabItem { Label("Folders", systemImage: "square.grid.2x2.fill") }
            NavigationStack { RecoveryBinView() }
                .tabItem { Label("Bin", systemImage: "trash") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .overlay(alignment: .bottom) {
            ImportProgressBanner().padding(.bottom, 64)
        }
        .task { Library.bootstrap(context: context, retentionDays: retentionDays) }
    }
}
