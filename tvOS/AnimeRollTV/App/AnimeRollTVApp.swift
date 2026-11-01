import AnimeRollKit
import SwiftUI

@main
struct AnimeRollTVApp: App {
    @State private var session = AppSession()

    init() {
        DispatchQueue.global(qos: .userInitiated).async { PlayerModel.configureAudioSession() }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if session.isRestoring {
                    ProgressView()
                } else if session.isLoggedIn {
                    TVMainView()
                } else {
                    TVLoginView()
                }
            }
            .modifier(OfflineErrorAlert())
            .preferredColorScheme(.dark)
            .tint(DS.accent)
            .environment(session)
            .environment(OfflineDownloads.shared)
            .task {
                DS.registerFonts()
                await session.restore()
                #if DEBUG
                let env = ProcessInfo.processInfo.environment
                if !session.isLoggedIn, let u = env["AR_DEBUG_USER"], let p = env["AR_DEBUG_PASS"] {
                    try? await session.login(username: u, password: p)
                }
                #endif
            }
        }
    }
}

enum TVTheme {
    static let accent = DS.accent
}

struct TVMainView: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") { NavigationStack { TVHomeView() } }
            Tab("Esplora", systemImage: "safari") { NavigationStack { TVExploreView() } }
            Tab("Cerca", systemImage: "magnifyingglass") { NavigationStack { TVSearchView() } }
            Tab("Libreria", systemImage: "books.vertical") { NavigationStack { TVLibraryView() } }
            Tab("Download", systemImage: "arrow.down.to.line") { NavigationStack { TVDownloadsView() } }
            Tab("Profilo", systemImage: "person") { NavigationStack { TVSettingsView() } }
        }
    }
}

struct TVLoginView: View {
    @Environment(AppSession.self) private var session
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        @Bindable var session = session
        HStack(spacing: 80) {
            VStack(alignment: .leading, spacing: 16) {
                (Text("Anime") + Text("Roll").foregroundStyle(DS.accent)).font(DS.display(96, 800))
                Text("Il tuo catalogo anime sul NAS").font(DS.body(32)).foregroundStyle(DS.textSecondary)
            }
            VStack(spacing: 24) {
                TextField("Indirizzo NAS (https://…)", text: $session.serverURLString).keyboardType(.URL)
                TextField("Username", text: $username).textContentType(.username)
                SecureField("Password", text: $password).textContentType(.password)
                Button("Accedi") { run { try await session.login(username: username, password: password) } }
                    .disabled(username.isEmpty || password.isEmpty || busy)
                Button("Accedi con passkey (iPhone)") { run { try await session.loginWithPasskey(username: username) } }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .frame(width: 760)
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [Color(hex: 0x4A1F0C), DS.background, DS.background], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            busy = false
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
