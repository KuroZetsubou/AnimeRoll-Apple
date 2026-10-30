import AuthenticationServices
import AnimeRollKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var passkeys: [PasskeyInfo] = []
    @State private var message: String?

    var body: some View {
        Form {
            if let user = session.user {
                Section("Account") {
                    LabeledContent("Utente", value: user.username)
                    LabeledContent("Server", value: session.api.baseURL.host() ?? "")
                }

                Section {
                    if user.aniListConnected {
                        LabeledContent("AniList", value: user.aniListUserName ?? "Collegato")
                        Button("Scollega AniList", role: .destructive) {
                            Task { try? await session.api.aniListDisconnect(); await session.refreshUser() }
                        }
                    } else {
                        Button("Collega AniList", systemImage: "link") { Task { await connectAniList() } }
                    }
                } header: { Text("AniList") } footer: {
                    Text("Gli episodi visti oltre l'85% aggiornano automaticamente il tuo progresso su AniList.")
                }

                Section("Passkey") {
                    ForEach(passkeys) { p in
                        LabeledContent(p.name, value: p.lastUsedAt?.formatted(date: .abbreviated, time: .omitted) ?? "mai usata")
                            .swipeActions {
                                Button("Elimina", role: .destructive) {
                                    Task { try? await session.api.deletePasskey(p.id); await loadPasskeys() }
                                }
                            }
                    }
                    Button("Aggiungi passkey", systemImage: "person.badge.key") {
                        Task {
                            do { try await session.registerPasskey(name: UIDevice.current.name); await loadPasskeys(); message = "Passkey creata" }
                            catch { message = error.localizedDescription }
                        }
                    }
                }

                Section("Fonti") {
                    NavigationLink("Canali Telegram") { TelegramSettingsView() }
                }

                if let message { Section { Text(message).font(.footnote) } }

                Section { Button("Esci", role: .destructive) { session.logout() } }
            }
        }
        .navigationTitle("Profilo")
        .task { await loadPasskeys() }
    }

    private func loadPasskeys() async { passkeys = (try? await session.api.passkeys()) ?? [] }

    private func connectAniList() async {
        do {
            let url = try await session.api.aniListConnectURL()
            _ = try await webAuth.authenticate(using: url, callbackURLScheme: "animeroll", preferredBrowserSession: .shared)
            await session.refreshUser()
            message = "AniList collegato"
        } catch { message = error.localizedDescription }
    }
}

/// Telegram login (code sent by Telegram) + choose which channels to search.
struct TelegramSettingsView: View {
    @Environment(AppSession.self) private var session
    @State private var status: TelegramStatus?
    @State private var next: String?
    @State private var code = ""
    @State private var channels: [TelegramChannel] = []
    @State private var error: String?

    var body: some View {
        Form {
            if let status {
                if !status.configured {
                    Text("Configura ApiId, ApiHash e numero nel file .env del server.").foregroundStyle(.secondary)
                } else if !status.loggedIn {
                    Section("Accesso Telegram") {
                        if let next {
                            SecureField(next == "password" ? "Password 2FA" : "Codice ricevuto su Telegram", text: $code)
                            Button("Invia") { Task { await login(code) } }
                        } else {
                            Button("Invia codice di accesso") { Task { await login(nil) } }
                        }
                    }
                } else {
                    Section("Canali da usare come fonte") {
                        ForEach($channels) { $c in Toggle(c.title, isOn: $c.enabled) }
                    }
                    Button("Salva") { Task { try? await session.api.saveTelegramChannels(channels) } }
                }
            } else { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Telegram")
        .task { await refresh() }
    }

    private func refresh() async {
        status = try? await session.api.telegramStatus()
        if status?.loggedIn == true { channels = (try? await session.api.telegramChannels()) ?? [] }
    }

    private func login(_ input: String?) async {
        do { next = try await session.api.telegramLogin(code: input); code = ""; await refresh() }
        catch { self.error = error.localizedDescription }
    }
}
