import AnimeRollKit
import SwiftUI

@main
struct AnimeRollApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(OfflineDownloads.shared)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task {
                    await session.restore()
                    #if DEBUG
                    // Dev only: SIMCTL_CHILD_AR_DEBUG_USER / AR_DEBUG_PASS log in automatically in the simulator.
                    let env = ProcessInfo.processInfo.environment
                    if !session.isLoggedIn, let u = env["AR_DEBUG_USER"], let p = env["AR_DEBUG_PASS"] {
                        try? await session.login(username: u, password: p)
                    }
                    #endif
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Lets offline downloads finish while the app is suspended.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated { OfflineDownloads.shared.backgroundCompletionHandler = completionHandler }
    }
}

struct RootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        Group {
            if session.isRestoring {
                ProgressView().controlSize(.large)
            } else if session.isLoggedIn {
                MainView()
            } else {
                LoginView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .trackingFoldPosture()
    }
}

/// Compact width (iPhone, iPhone Duo folded): tab bar.
/// Regular width (iPhone Duo unfolded, iPad): sidebar + two-pane browsing.
struct MainView: View {
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.foldPosture) private var posture
    @State private var tab: AppTab = .home
    @State private var width: CGFloat = 0

    /// Two panes when the screen is wide enough for both (iPad, landscape, an open
    /// iPhone Duo turned sideways). Never on the folded outer screen.
    private var twoPanes: Bool {
        if posture == .closed { return false }
        return hSize == .regular || width >= 640
    }

    enum AppTab: Hashable { case home, search, library, downloads, profile }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: .home) {
                if twoPanes { DualPaneHome() } else { NavigationStack { HomeView() } }
            }
            Tab("Cerca", systemImage: "magnifyingglass", value: .search) {
                NavigationStack { SearchView() }
            }
            Tab("Libreria", systemImage: "square.grid.2x2.fill", value: .library) {
                NavigationStack { LibraryView() }
            }
            Tab("Download", systemImage: "arrow.down.circle.fill", value: .downloads) {
                NavigationStack { DownloadsView() }
            }
            Tab("Profilo", systemImage: "person.crop.circle", value: .profile) {
                NavigationStack { SettingsView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
    }
}
