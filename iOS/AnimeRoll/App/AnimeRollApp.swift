import AnimeRollKit
import SwiftUI

@main
struct AnimeRollApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .modifier(OfflineErrorAlert())
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
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Off the main thread and once: doing it when the player opens freezes the UI for hundreds of ms.
        DispatchQueue.global(qos: .userInitiated).async { PlayerModel.configureAudioSession() }
        return true
    }

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

/// Five tabs: Home, Esplora, Libreria, Download, Profilo. On iOS 26+ the system tab bar is the floating
/// glass bar; on wide screens (iPad, unfolded iPhone Duo) it becomes a sidebar and Home is two-pane.
/// Title pages open as a sheet over everything (TitleSheetHost).
struct MainView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.foldPosture) private var posture
    @State private var tab: AppTab = .home
    @State private var tabBarHidden = false

    /// Two panes only on a half-open iPhone Duo, split on the fold. Everywhere else (iPad, iPhone,
    /// Duo open or closed) the catalog takes the whole screen and a title opens as a modal over it.
    private var twoPanes: Bool { posture == .book || posture == .tabletop }

    enum AppTab: Hashable { case home, explore, library, downloads, profile }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: .home) {
                if twoPanes { DualPaneHome() }
                else {
                    HomeView(onScrollDirection: { down in
                        guard down != tabBarHidden else { return }
                        withAnimation(DS.base) { tabBarHidden = down }
                    })
                    .toolbarVisibility(tabBarHidden ? .hidden : .visible, for: .tabBar)
                }
            }
            Tab("Esplora", systemImage: "safari", value: .explore) { NavigationStack { ExploreView() } }
            Tab("Libreria", systemImage: "books.vertical.fill", value: .library) { NavigationStack { LibraryView() } }
            Tab("Download", systemImage: "arrow.down.to.line", value: .downloads) { NavigationStack { DownloadsView() } }
            Tab("Profilo", systemImage: "person.fill", value: .profile) { NavigationStack { SettingsView() } }
        }
        .tabViewStyle(.sidebarAdaptable)
        .onChange(of: tab) { _, _ in Haptics.tick(); tabBarHidden = false }
        .modifier(TitleSheetHost())
        .onAppear { DS.registerFonts(); if session.isOffline { tab = .downloads } }
        .onReceive(NotificationCenter.default.publisher(for: .showDownloads)) { _ in tab = .downloads }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await session.retryIfOffline() } }
        }
    }
}

/// Shows why a download to this device failed (before, failures were silent).
struct OfflineErrorAlert: ViewModifier {
    @Environment(OfflineDownloads.self) private var offline

    func body(content: Content) -> some View {
        content.alert("Download non riuscito", isPresented: Binding(
            get: { offline.lastError != nil },
            set: { if !$0 { offline.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(offline.lastError ?? "") }
    }
}
