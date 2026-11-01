import AuthenticationServices
import AnimeRollKit
import SwiftUI

/// Profilo: account, AniList, passkeys, NAS queue, Telegram sources, logout.
struct SettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var passkeys: [PasskeyInfo] = []
    @State private var message: String?
    @State private var queue: QueueSettings?
    @State private var storage: StorageInfo?
    @State private var tg: TelegramStatus?
    @State private var tgNext: String?
    @State private var code = ""
    @State private var channels: [TelegramChannel] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenTitle("Profilo")
                if let user = session.user {
                    group("Account") {
                        row("person", "Utente", value: user.username)
                        row("server.rack", "Server", value: session.api.baseURL.host() ?? "")
                    }
                    group("AniList", note: "Oltre l'85% di un episodio il server aggiorna AniList. Il progresso non torna mai indietro e l'ultimo episodio imposta Completato.") {
                        row("link", user.aniListConnected ? "Collegato come \(user.aniListUserName ?? "AniList")" : "Non collegato")
                        Group {
                            if user.aniListConnected {
                                Button("Scollega") { Task { try? await session.api.aniListDisconnect(); await session.refreshUser() } }
                                    .buttonStyle(PrimaryButtonStyle(prominent: false, small: true))
                            } else {
                                Button("Collega AniList") { Task { await connectAniList() } }.buttonStyle(PrimaryButtonStyle(small: true))
                            }
                        }
                        .padding(.horizontal, 16).padding(.bottom, 14)
                    }
                    group("Passkey") {
                        ForEach(passkeys) { p in
                            HStack(spacing: 14) {
                                Image(systemName: "key").foregroundStyle(DS.textSecondary).frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).font(DS.body(15, 500))
                                    Text(p.lastUsedAt.map { "Ultimo uso: \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Mai usata")
                                        .font(DS.body(12)).foregroundStyle(DS.textTertiary)
                                }
                                Spacer()
                                Button { Task { try? await session.api.deletePasskey(p.id); await loadPasskeys() } } label: {
                                    Image(systemName: "trash").foregroundStyle(DS.textSecondary).frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain).accessibilityLabel("Elimina \(p.name)")
                            }
                            .padding(.leading, 16).padding(.trailing, 6).frame(minHeight: 56)
                        }
                        action("plus", "Aggiungi passkey") {
                            do { try await session.registerPasskey(name: UIDevice.current.name); await loadPasskeys(); message = "Passkey creata" }
                            catch { message = error.localizedDescription }
                        }
                    }
                    group("Spazio sul NAS", note: "Sotto la riserva il NAS rifiuta nuovi download e import. Per liberare spazio elimina episodi o serie dalla pagina del titolo.") {
                        if let storage { storageCard(storage) } else { ProgressView().padding(16) }
                    }
                    group("Download sul NAS", note: "Quanti lavori il NAS esegue insieme. Gli altri aspettano in coda in ordine di priorità.") {
                        HStack {
                            Text("Download contemporanei").font(DS.body(15, 500))
                            Spacer()
                            if let queue {
                                Stepper(value: Binding(get: { queue.maxConcurrentDownloads },
                                                       set: { v in Task { self.queue = (try? await session.api.setQueueSettings(QueueSettings(maxConcurrentDownloads: v))) ?? self.queue } }),
                                        in: QueueSettings.range) {
                                    Text("\(queue.maxConcurrentDownloads)").font(DS.display(17, 700))
                                }
                                .fixedSize()
                            } else { ProgressView() }
                        }
                        .padding(.horizontal, 16).frame(minHeight: 56)
                    }
                    group("Fonti · Telegram") { telegram }
                    if let message { Text(message).font(DS.body(13)).foregroundStyle(DS.accent).padding(.top, 16) }
                    group(nil) {
                        Button { session.logout() } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "rectangle.portrait.and.arrow.right").frame(width: 24)
                                Text("Esci").font(DS.body(15, 500))
                                Spacer()
                            }
                            .foregroundStyle(DS.pink).padding(.horizontal, 16).frame(minHeight: 52).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal).padding(.top, 8).padding(.bottom, 120)
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await loadPasskeys()
            queue = try? await session.api.queueSettings()
            storage = try? await session.api.storageInfo()
            await loadTelegram()
        }
    }

    // MARK: Storage

    private func storageCard(_ s: StorageInfo) -> some View {
        let used = s.totalBytes > 0 ? Double(s.usedBytes) / Double(s.totalBytes) : 0
        let low = s.freeBytes < s.reserveBytes * 2
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(s.freeBytes.fileSize) liberi").font(DS.display(20, 700)).foregroundStyle(low ? DS.pink : .white)
                Spacer()
                Text("su \(s.totalBytes.fileSize)").font(DS.body(14)).foregroundStyle(DS.textTertiary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule().fill(low ? DS.pink : DS.accent).frame(width: g.size.width * min(1, used))
                }
            }
            .frame(height: 6)
            HStack {
                Label("Libreria \(s.libraryBytes.fileSize)", systemImage: "film.stack").font(DS.body(13)).foregroundStyle(DS.textSecondary)
                Spacer()
                Text("Riserva \(s.reserveBytes.fileSize)").font(DS.body(13)).foregroundStyle(DS.textTertiary)
            }
        }
        .padding(16)
    }

    // MARK: Telegram

    @ViewBuilder private var telegram: some View {
        if let tg {
            if !tg.configured {
                Text("Configura ApiId, ApiHash e numero nel file .env del server.").font(DS.body(14)).foregroundStyle(DS.textSecondary).padding(16)
            } else if !tg.loggedIn {
                VStack(alignment: .leading, spacing: 10) {
                    if let tgNext {
                        SecureField(tgNext == "password" ? "Password 2FA" : "Codice ricevuto su Telegram", text: $code)
                            .font(DS.body(16)).padding(.horizontal, 14).frame(height: 48)
                            .background(DS.surfaceRaised, in: .rect(cornerRadius: DS.rCard))
                        Button("Verifica") { Task { await telegramLogin(code) } }.buttonStyle(PrimaryButtonStyle(small: true))
                    } else {
                        Text("Collega il tuo account per cercare episodi nei canali.").font(DS.body(14)).foregroundStyle(DS.textSecondary)
                        Button("Invia codice") { Task { await telegramLogin(nil) } }.buttonStyle(PrimaryButtonStyle(small: true))
                    }
                }
                .padding(16)
            } else {
                ForEach($channels) { $c in
                    Toggle(isOn: $c.enabled) { Text(c.title).font(DS.body(15, 500)) }
                        .tint(DS.accent).padding(.horizontal, 16).frame(minHeight: 52)
                }
                if channels.isEmpty { Text("Nessun canale trovato.").font(DS.body(14)).foregroundStyle(DS.textSecondary).padding(16) }
                Button("Salva") {
                    Task {
                        do { try await session.api.saveTelegramChannels(channels); message = "Canali salvati" }
                        catch { message = error.localizedDescription }
                    }
                }
                .buttonStyle(PrimaryButtonStyle(small: true)).padding(.horizontal, 16).padding(.bottom, 14)
            }
        } else {
            ProgressView().padding(16)
        }
    }

    private func loadTelegram() async {
        tg = try? await session.api.telegramStatus()
        if tg?.loggedIn == true { channels = (try? await session.api.telegramChannels()) ?? [] }
    }

    private func telegramLogin(_ input: String?) async {
        do { tgNext = try await session.api.telegramLogin(code: input) ?? (input == nil ? "code" : nil); code = ""; await loadTelegram() }
        catch { message = error.localizedDescription }
    }

    // MARK: Pieces

    private func group(_ title: String?, note: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased()).font(DS.body(12, 700)).tracking(1).foregroundStyle(DS.textTertiary).padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.surface, in: .rect(cornerRadius: DS.rCard))
            if let note { Text(note).font(DS.body(12)).foregroundStyle(DS.textTertiary).padding(.horizontal, 4) }
        }
        .padding(.top, 24)
    }

    private func row(_ icon: String, _ label: String, value: String? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundStyle(DS.textSecondary).frame(width: 24)
            Text(label).font(DS.body(15, 500))
            Spacer()
            if let value { Text(value).font(DS.body(14)).foregroundStyle(DS.textTertiary).lineLimit(1) }
        }
        .padding(.horizontal, 16).frame(minHeight: 52)
    }

    private func action(_ icon: String, _ label: String, _ work: @escaping () async -> Void) -> some View {
        Button { Task { await work() } } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).foregroundStyle(DS.textSecondary).frame(width: 24)
                Text(label).font(DS.body(15, 500))
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(DS.textTertiary)
            }
            .padding(.horizontal, 16).frame(minHeight: 52).contentShape(.rect)
        }
        .buttonStyle(.plain)
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
