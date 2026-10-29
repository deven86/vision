import SwiftUI
import SwiftData

@main
struct VISIONApp: App {
    @State private var auth = AuthService()
    @State private var importer = ImportCoordinator()
    @State private var exporter = ExportPresenter()
    private let container: ModelContainer

    init() {
        VaultStore.shared.prepareDirectories()
        ExportService.purgeAll()   // leftovers from an export interrupted by a crash or kill
        do {
            // CloudKit stays OFF until Phase 2 adds opt-in sync explicitly.
            let configuration = ModelConfiguration("VISIONLibrary",
                                                   schema: Schema([Folder.self, MediaItem.self]),
                                                   cloudKitDatabase: .none)
            container = try ModelContainer(for: Folder.self, MediaItem.self, configurations: configuration)
        } catch {
            fatalError("Could not open the VISION library: \(error)")
        }
        Appearance.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(importer)
                .environment(exporter)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .modelContainer(container)
    }
}

enum Appearance {
    static func configure() {
        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        tab.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        tab.backgroundColor = UIColor(white: 0.03, alpha: 0.72)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        nav.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        let edge = UINavigationBarAppearance()
        edge.configureWithTransparentBackground()
        edge.largeTitleTextAttributes = nav.largeTitleTextAttributes
        edge.titleTextAttributes = nav.titleTextAttributes
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = edge
    }
}
