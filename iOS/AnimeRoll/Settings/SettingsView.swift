import AuthenticationServices
import AnimeRollKit
import SwiftUI

/// Profilo: account, AniList, passkeys, server queue, Telegram sources, logout.
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
    @AppStorage(PlayerModel.audioLanguageKey) private var audioLanguage = ""
    @AppStorage(PlayerModel.autoNextKey) private var autoNext = PlayerModel.autoNextDefault
    @State private var channels: [TelegramChannel] = []
    @State private var tracker: TrackerInfo?
    @State private var profileCount = 1
    @State private var confirmDelete = false
    @State private var sheet: ProfileSheet?

    private enum ProfileSheet: String, Identifiable { case editProfile, passcode; var id: String { rawValue } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenTitle("Profile")
                if let user = session.user {
                    group("Account") {
                        row("person", "User", value: user.username)
                        row("server.rack", "Server", value: session.api.baseURL.host() ?? "")
                    }
                    group("Profile") {
                        HStack(spacing: 14) {
                            AvatarView(name: user.username, index: user.avatar, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.username).font(DS.body(15, 600))
                                Text(user.hasPasscode ? "Locked with a passcode" : "Open to everyone using this server")
                                    .font(DS.body(12)).foregroundStyle(DS.textTertiary)
                            }
                            Spacer()
                            Button { sheet = .editProfile } label: {
                                Image(systemName: "pencil").foregroundStyle(DS.textSecondary).frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain).accessibilityLabel("Edit profile")
                        }
                        .padding(.leading, 16).padding(.trailing, 6).frame(minHeight: 64)
                        action("lock", user.hasPasscode ? "Change or remove passcode" : "Set a passcode") { sheet = .passcode }
                        action("person.2", "Switch profile") { session.showProfilePicker = true }
                        if profileCount > 1 {
                            Button { confirmDelete = true } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "trash").frame(width: 24)
                                    Text("Delete this profile").font(DS.body(15, 500))
                                    Spacer()
                                }
                                .foregroundStyle(DS.pink).padding(.horizontal, 16).frame(minHeight: 52).contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    group("Lists", note: "Each profile keeps its own list. Past 85% of an episode the server updates the list in use; progress never goes backwards and the last episode sets Completed. Titles and images always come from AniList.") {
                        if let tracker {
                            trackerRows(id: "anilist", name: "AniList", account: tracker.aniList, active: tracker.active == "anilist")
                            trackerRows(id: "mal", name: "MyAnimeList", account: tracker.mal, active: tracker.active == "mal")
                        } else { ProgressView().padding(16) }
                    }
                    group("Playback", note: "When an episode ends the next one starts after this time. The default dub applies when an episode has several audio tracks; choosing another in the player makes it the new default.") {
                        HStack(spacing: 14) {
                            Image(systemName: "waveform").foregroundStyle(DS.textSecondary).frame(width: 24)
                            Text("Dub").font(DS.body(15, 500))
                            Spacer()
                            Picker("Dub", selection: $audioLanguage) {
                                Text("First track").tag("")
                                Text("Japanese").tag("ja")
                                Text("Italian").tag("it")
                                Text("English").tag("en")
                            }
                            .tint(DS.accent)
                        }
                        .padding(.horizontal, 16).frame(minHeight: 52)
                        HStack(spacing: 14) {
                            Image(systemName: "forward.end").foregroundStyle(DS.textSecondary).frame(width: 24)
                            Text("Next episode").font(DS.body(15, 500))
                            Spacer()
                            Picker("Next episode", selection: $autoNext) {
                                Text("Off").tag(0)
                                ForEach([3, 5, 10, 15], id: \.self) { Text("\($0) seconds").tag($0) }
                            }
                            .tint(DS.accent)
                        }
                        .padding(.horizontal, 16).frame(minHeight: 52)
                    }
                    group("Passkey") {
                        ForEach(passkeys) { p in
                            HStack(spacing: 14) {
                                Image(systemName: "key").foregroundStyle(DS.textSecondary).frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).font(DS.body(15, 500))
                                    Text(p.lastUsedAt.map { String(localized: "Last used: \($0.formatted(date: .abbreviated, time: .omitted))") } ?? String(localized: "Never used"))
                                        .font(DS.body(12)).foregroundStyle(DS.textTertiary)
                                }
                                Spacer()
                                Button { Task { try? await session.api.deletePasskey(p.id); await loadPasskeys() } } label: {
                                    Image(systemName: "trash").foregroundStyle(DS.textSecondary).frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain).accessibilityLabel("Delete \(p.name)")
                            }
                            .padding(.leading, 16).padding(.trailing, 6).frame(minHeight: 56)
                        }
                        action("plus", "Add passkey") {
                            do { try await session.registerPasskey(name: UIDevice.current.name); await loadPasskeys(); message = String(localized: "Passkey created") }
                            catch { message = error.localizedDescription }
                        }
                    }
                    group("Server storage", note: "Below the reserve the server refuses new downloads and imports. To free space, delete episodes or series from the title page.") {
                        if let storage { storageCard(storage) } else { ProgressView().padding(16) }
                    }
                    group("Server downloads", note: "How many jobs the server runs at once. The others wait in the queue by priority.") {
                        HStack {
                            Text("Simultaneous downloads").font(DS.body(15, 500))
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
                    group("Sources · Telegram") { telegram }
                    if let message { Text(message).font(DS.body(13)).foregroundStyle(DS.accent).padding(.top, 16) }
                    group(nil) {
                        Button { session.logout() } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "rectangle.portrait.and.arrow.right").frame(width: 24)
                                Text("Sign out").font(DS.body(15, 500))
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
        .sheet(item: $sheet) { which in
            if let user = session.user {
                switch which {
                case .editProfile: ProfileFormSheet(mode: .edit(user)) {}
                case .passcode: PasscodeSheet(user: user) { message = String(localized: "Passcode updated") }
                }
            }
        }
        .confirmationDialog("Delete this profile?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete profile", role: .destructive) {
                Task {
                    guard let id = session.user?.id else { return }
                    do { try await session.api.deleteProfile(id); session.logout() } catch { message = error.localizedDescription }
                }
            }
        } message: { Text("Its watch history and passkeys are deleted. Anime it downloaded stay in the library. This cannot be undone.") }
        .task {
            await loadTracker()
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
                Text("\(s.freeBytes.fileSize) free").font(DS.display(20, 700)).foregroundStyle(low ? DS.pink : .white)
                Spacer()
                Text("of \(s.totalBytes.fileSize)").font(DS.body(14)).foregroundStyle(DS.textTertiary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule().fill(low ? DS.pink : DS.accent).frame(width: g.size.width * min(1, used))
                }
            }
            .frame(height: 6)
            HStack {
                Label("Library \(s.libraryBytes.fileSize)", systemImage: "film.stack").font(DS.body(13)).foregroundStyle(DS.textSecondary)
                Spacer()
                Text("Reserve \(s.reserveBytes.fileSize)").font(DS.body(13)).foregroundStyle(DS.textTertiary)
            }
        }
        .padding(16)
    }

    // MARK: Telegram

    @ViewBuilder private var telegram: some View {
        if let tg {
            if !tg.configured {
                Text("Set ApiId, ApiHash and phone number in the server's .env file.").font(DS.body(14)).foregroundStyle(DS.textSecondary).padding(16)
            } else if !tg.loggedIn {
                VStack(alignment: .leading, spacing: 10) {
                    if let tgNext {
                        SecureField(tgNext == "password" ? "2FA password" : "Code received on Telegram", text: $code)
                            .font(DS.body(16)).padding(.horizontal, 14).frame(height: 48)
                            .background(DS.surfaceRaised, in: .rect(cornerRadius: DS.rCard))
                        Button("Verify") { Task { await telegramLogin(code) } }.buttonStyle(PrimaryButtonStyle(small: true))
                    } else {
                        Text("Connect your account to search for episodes in channels.").font(DS.body(14)).foregroundStyle(DS.textSecondary)
                        Button("Send code") { Task { await telegramLogin(nil) } }.buttonStyle(PrimaryButtonStyle(small: true))
                    }
                }
                .padding(16)
            } else {
                ForEach($channels) { $c in
                    Toggle(isOn: $c.enabled) { Text(c.title).font(DS.body(15, 500)) }
                        .tint(DS.accent).padding(.horizontal, 16).frame(minHeight: 52)
                }
                if channels.isEmpty { Text("No channels found.").font(DS.body(14)).foregroundStyle(DS.textSecondary).padding(16) }
                Button("Save") {
                    Task {
                        do { try await session.api.saveTelegramChannels(channels); message = String(localized: "Channels saved") }
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

    private func group(_ title: LocalizedStringKey?, note: LocalizedStringKey? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).textCase(.uppercase).font(DS.body(12, 700)).tracking(1).foregroundStyle(DS.textTertiary).padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.surface, in: .rect(cornerRadius: DS.rCard))
            if let note { Text(note).font(DS.body(12)).foregroundStyle(DS.textTertiary).padding(.horizontal, 4) }
        }
        .padding(.top, 24)
    }

    private func row(_ icon: String, _ label: LocalizedStringKey, value: String? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundStyle(DS.textSecondary).frame(width: 24)
            Text(label).font(DS.body(15, 500))
            Spacer()
            if let value { Text(value).font(DS.body(14)).foregroundStyle(DS.textTertiary).lineLimit(1) }
        }
        .padding(.horizontal, 16).frame(minHeight: 52)
    }

    private func action(_ icon: String, _ label: LocalizedStringKey, _ work: @escaping () async -> Void) -> some View {
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

    private func loadTracker() async {
        tracker = try? await session.api.tracker()
        profileCount = (try? await session.api.profiles().count) ?? 1
    }

    @ViewBuilder private func trackerRows(id: String, name: String, account: TrackerAccount, active: Bool) -> some View {
        row("link", LocalizedStringKey(name), value: account.connected
            ? (active ? "\(account.userName ?? "") · \(String(localized: "in use"))" : account.userName ?? "")
            : account.configured ? String(localized: "Not connected") : String(localized: "Not set up on the server"))
        if account.connected || account.configured {
            HStack(spacing: 8) {
                if account.connected {
                    if !active {
                        Button("Use this list") { Task { try? await session.api.setActiveTracker(id); await refreshTracker() } }
                            .buttonStyle(PrimaryButtonStyle(small: true))
                    }
                    Button("Disconnect") {
                        Task {
                            if id == "anilist" { try? await session.api.aniListDisconnect() } else { try? await session.api.malDisconnect() }
                            await refreshTracker()
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(prominent: false, small: true))
                } else {
                    Button("Connect \(name)") { Task { await connect(id: id, name: name) } }.buttonStyle(PrimaryButtonStyle(small: true))
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
        }
    }

    private func refreshTracker() async {
        await loadTracker()
        await session.refreshUser()
    }

    private func connect(id: String, name: String) async {
        do {
            let url = id == "anilist" ? try await session.api.aniListConnectURL() : try await session.api.malConnectURL()
            _ = try await webAuth.authenticate(using: url, callbackURLScheme: "animeroll", preferredBrowserSession: .shared)
            await refreshTracker()
            message = String(localized: "\(name) connected")
        } catch { message = error.localizedDescription }
    }
}
