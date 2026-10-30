import AnimeRollKit
import SwiftUI

@main
struct AnimeRollTVApp: App {
    @State private var session = AppSession()

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
            .environment(session)
            .environment(OfflineDownloads.shared)
            .task {
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
    static let accent = Color(red: 1.0, green: 0.45, blue: 0.2)
}

struct TVMainView: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") { NavigationStack { TVHomeView() } }
            Tab("Cerca", systemImage: "magnifyingglass") { NavigationStack { TVSearchView() } }
            Tab("Libreria", systemImage: "square.grid.2x2") { NavigationStack { TVLibraryView() } }
            Tab("Download", systemImage: "arrow.down.circle") { NavigationStack { TVDownloadsView() } }
            Tab("Impostazioni", systemImage: "gear") { NavigationStack { TVSettingsView() } }
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
                Image(systemName: "play.tv.fill").font(.system(size: 120)).foregroundStyle(TVTheme.accent)
                Text("AnimeRoll").font(.system(size: 76, weight: .bold))
                Text("Il tuo catalogo anime sul NAS").font(.title3).foregroundStyle(.secondary)
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
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
