import AnimeRollKit
import SwiftUI

/// "Who's watching?" on the Apple TV: one avatar per profile of the server.
struct TVProfilePicker: View {
    @Environment(AppSession.self) private var session
    @State private var profiles: [ProfileDTO] = []
    @State private var locked: ProfileDTO?
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 60) {
            Text("Who's watching?").font(DS.display(64, 800))
            if let error { Text(error).font(DS.body(26)).foregroundStyle(DS.pink) }
            ScrollView(.horizontal) {
                HStack(spacing: 50) {
                    ForEach(profiles) { p in
                        Button { pick(p) } label: {
                            VStack(spacing: 18) {
                                AvatarView(name: p.name, index: p.avatar, size: 200)
                                HStack(spacing: 8) {
                                    Text(p.name).font(DS.body(30, 600)).lineLimit(1)
                                    if p.hasPasscode { Image(systemName: "lock.fill") }
                                }
                            }
                            .padding(20)
                        }
                        .buttonStyle(.card)
                    }
                    Button { adding = true } label: {
                        VStack(spacing: 18) {
                            Image(systemName: "plus").font(.system(size: 70, weight: .semibold))
                                .frame(width: 200, height: 200).background(DS.surface, in: .circle)
                            Text("Add profile").font(DS.body(30, 600))
                        }
                        .padding(20)
                    }
                    .buttonStyle(.card)
                }
                .padding(40)
            }
            .scrollClipDisabled()
            if session.profilePicked {
                Button("Cancel") { session.showProfilePicker = false }
            }
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background)
        .task { await load() }
        .sheet(item: $locked) { p in TVPasscodeAsk(profile: p) { code in try await enter(p, code) } }
        .sheet(isPresented: $adding) { TVNewProfile { adding = false; Task { await load() } } }
    }

    private func load() async {
        do { profiles = try await session.api.profiles() } catch { self.error = error.localizedDescription }
    }

    private func pick(_ p: ProfileDTO) {
        if p.hasPasscode && !p.isCurrent { locked = p } else { Task { try? await enter(p, nil) } }
    }

    private func enter(_ p: ProfileDTO, _ code: String?) async throws {
        do {
            try await session.enterProfile(p.id, passcode: code)
            session.showProfilePicker = false
        } catch { self.error = error.localizedDescription; throw error }
    }
}

struct TVPasscodeAsk: View {
    let profile: ProfileDTO
    let submit: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 30) {
            AvatarView(name: profile.name, index: profile.avatar, size: 140)
            Text(profile.name).font(DS.display(40, 700))
            SecureField("Passcode", text: $code).frame(width: 700)
            if let error { Text(error).foregroundStyle(DS.pink) }
            Button("Enter") {
                Task { do { try await submit(code); dismiss() } catch { self.error = error.localizedDescription } }
            }
            .disabled(code.count < 4)
        }
        .padding(80)
    }
}

struct TVNewProfile: View {
    let done: () -> Void
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var avatar = Int.random(in: 0..<8)
    @State private var passcode = ""
    @State private var error: String?

    private var valid: Bool { name.trimmingCharacters(in: .whitespaces).count >= 2 && (passcode.isEmpty || passcode.count >= 4) }

    var body: some View {
        VStack(spacing: 28) {
            Text("New profile").font(DS.display(40, 700))
            TextField("Name", text: $name).frame(width: 700)
            HStack(spacing: 20) {
                ForEach(0..<AvatarPalette.colors.count, id: \.self) { i in
                    Button { avatar = i } label: {
                        AvatarView(name: name.isEmpty ? "?" : name, index: i, size: 90)
                            .overlay(Circle().strokeBorder(.white, lineWidth: avatar == i ? 5 : 0))
                    }
                    .buttonStyle(.card)
                }
            }
            SecureField("Passcode (optional, 4-12 characters)", text: $passcode).frame(width: 700)
            Text("Each profile has its own watch history and its own AniList or MyAnimeList list. The library is shared. A passcode keeps others from entering this profile.")
                .font(DS.body(22)).foregroundStyle(DS.textTertiary).frame(width: 900)
            if let error { Text(error).foregroundStyle(DS.pink) }
            Button("Create profile") {
                Task {
                    do {
                        try await session.api.createProfile(name: name.trimmingCharacters(in: .whitespaces), avatar: avatar, passcode: passcode.isEmpty ? nil : passcode)
                        done(); dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
            .disabled(!valid)
        }
        .padding(60)
    }
}

/// Profile group of the Profilo screen: rename/recolour, passcode, switch, delete.
struct TVProfileGroups: View {
    @Environment(AppSession.self) private var session
    let user: UserDTO
    @State private var profileCount = 1
    @State private var edit = false
    @State private var passcodeSheet = false
    @State private var confirmDelete = false
    @State private var message: String?

    var body: some View {
        TVGroup(title: "Profile") {
            HStack(spacing: 20) {
                AvatarView(name: user.username, index: user.avatar, size: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.username).font(DS.body(28, 600))
                    Text(user.hasPasscode ? "Locked with a passcode" : "Open to everyone using this server").font(DS.body(22)).foregroundStyle(DS.textTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 28).frame(minHeight: 100)
            row("pencil", "Edit profile") { edit = true }
            row("lock", user.hasPasscode ? "Change or remove passcode" : "Set a passcode") { passcodeSheet = true }
            row("person.2", "Switch profile") { session.showProfilePicker = true }
            if profileCount > 1 { row("trash", "Delete this profile") { confirmDelete = true } }
            if let message { Text(message).font(DS.body(22)).foregroundStyle(DS.accent).padding(.horizontal, 28).padding(.bottom, 14) }
        }
        .task { profileCount = (try? await session.api.profiles().count) ?? 1 }
        .sheet(isPresented: $edit) { TVEditProfile(user: user) }
        .sheet(isPresented: $passcodeSheet) { TVPasscodeEdit(user: user) { message = String(localized: "Passcode updated") } }
        .confirmationDialog("Delete this profile?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete profile", role: .destructive) {
                Task { do { try await session.api.deleteProfile(user.id); session.logout() } catch { message = error.localizedDescription } }
            }
        } message: { Text("Its watch history and passkeys are deleted. Anime it downloaded stay in the library. This cannot be undone.") }
    }

    private func row(_ icon: String, _ label: LocalizedStringKey, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 20) {
                Image(systemName: icon).frame(width: 40)
                Text(label).font(DS.body(28, 500))
                Spacer()
            }
            .padding(.horizontal, 12).frame(minHeight: 70)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}

struct TVEditProfile: View {
    let user: UserDTO
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var avatar = 0
    @State private var error: String?

    var body: some View {
        VStack(spacing: 28) {
            Text("Edit profile").font(DS.display(40, 700))
            TextField("Name", text: $name).frame(width: 700)
            HStack(spacing: 20) {
                ForEach(0..<AvatarPalette.colors.count, id: \.self) { i in
                    Button { avatar = i } label: {
                        AvatarView(name: name.isEmpty ? "?" : name, index: i, size: 90)
                            .overlay(Circle().strokeBorder(.white, lineWidth: avatar == i ? 5 : 0))
                    }
                    .buttonStyle(.card)
                }
            }
            if let error { Text(error).foregroundStyle(DS.pink) }
            Button("Save") {
                Task {
                    do {
                        try await session.api.updateProfile(user.id, name: name.trimmingCharacters(in: .whitespaces), avatar: avatar)
                        await session.refreshUser(); dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
            .disabled(name.trimmingCharacters(in: .whitespaces).count < 2)
        }
        .padding(60)
        .onAppear { name = user.username; avatar = user.avatar }
    }
}

struct TVPasscodeEdit: View {
    let user: UserDTO
    let done: () -> Void
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var next = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 28) {
            Text("Passcode").font(DS.display(40, 700))
            if user.hasPasscode { SecureField("Current passcode", text: $current).frame(width: 700) }
            SecureField("New passcode (4-12 characters)", text: $next).frame(width: 700)
            Text("The passcode is asked when someone switches to this profile from another one. It does not replace the password or passkey used to sign in to the server.")
                .font(DS.body(22)).foregroundStyle(DS.textTertiary).frame(width: 900)
            if let error { Text(error).foregroundStyle(DS.pink) }
            Button("Save") { save(remove: false) }
                .disabled(next.count < 4 || next.count > 12 || (user.hasPasscode && current.isEmpty))
            if user.hasPasscode { Button("Remove passcode") { save(remove: true) }.disabled(current.isEmpty) }
        }
        .padding(60)
    }

    private func save(remove: Bool) {
        Task {
            do {
                try await session.api.setPasscode(current: user.hasPasscode ? current : nil, passcode: remove ? nil : next)
                await session.refreshUser(); done(); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Lists group: AniList / MyAnimeList status and which one is in use (connecting needs a browser: done from the iPhone app).
struct TVTrackerGroup: View {
    @Environment(AppSession.self) private var session
    @State private var info: TrackerInfo?

    var body: some View {
        TVGroup(title: "Lists", note: "Each profile keeps its own list. Past 85% of an episode the server updates the list in use; progress never goes backwards and the last episode sets Completed. Titles and images always come from AniList. To connect a list, use the AnimeRoll app on iPhone.") {
            if let info {
                account("anilist", "AniList", info.aniList, info.active == "anilist")
                account("mal", "MyAnimeList", info.mal, info.active == "mal")
            } else { ProgressView().padding(28) }
        }
        .task { info = try? await session.api.tracker() }
    }

    @ViewBuilder private func account(_ id: String, _ name: String, _ a: TrackerAccount, _ active: Bool) -> some View {
        TVRow(icon: "link", label: LocalizedStringKey(name), value: a.connected
              ? (active ? "\(a.userName ?? "") · \(String(localized: "in use"))" : a.userName ?? "")
              : a.configured ? String(localized: "Not connected") : String(localized: "Not set up on the server"))
        if a.connected {
            HStack(spacing: 20) {
                if !active {
                    Button("Use this list") { Task { try? await session.api.setActiveTracker(id); await refresh() } }
                }
                Button("Disconnect") {
                    Task {
                        if id == "anilist" { try? await session.api.aniListDisconnect() } else { try? await session.api.malDisconnect() }
                        await refresh()
                    }
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 16)
        }
    }

    private func refresh() async {
        info = try? await session.api.tracker()
        await session.refreshUser()
    }
}

/// Status, episodes watched and rating of a title on the list in use.
struct TVListStatusSheet: View {
    let total: Int?
    let save: (EntryUpdate) async throws -> AniListEntry?
    @State private var cur: AniListEntry?
    @State private var busy = false
    @State private var error: String?

    init(entry: AniListEntry?, total: Int?, save: @escaping (EntryUpdate) async throws -> AniListEntry?) {
        self.total = total; self.save = save
        _cur = State(initialValue: entry)
    }

    private var progress: Int { cur?.progress ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("List status").font(DS.display(40, 700))
                HStack(spacing: 30) {
                    Text("Episodes watched").font(DS.body(30))
                    if let total { Text("of \(total)").font(DS.body(24)).foregroundStyle(DS.textTertiary) }
                    Spacer()
                    Button { apply(EntryUpdate(progress: progress - 1)) } label: { Image(systemName: "minus") }
                        .disabled(busy || progress <= 0)
                    Text("\(progress)").font(DS.display(34, 700)).frame(minWidth: 70)
                    Button { apply(EntryUpdate(progress: progress + 1)) } label: { Image(systemName: "plus") }
                        .disabled(busy || progress >= (total ?? 9999))
                }
                Text("Status").font(DS.body(22, 700)).foregroundStyle(DS.textTertiary)
                ForEach(ListStatus.all, id: \.self) { s in
                    Button { apply(EntryUpdate(status: s)) } label: {
                        HStack {
                            Text(AniListStatusLabel.text(s)).font(DS.body(28))
                            Spacer()
                            if s == cur?.status { Image(systemName: "checkmark").foregroundStyle(DS.accent) }
                        }
                    }
                    .disabled(busy)
                }
                Text("Your rating").font(DS.body(22, 700)).foregroundStyle(DS.textTertiary)
                HStack(spacing: 14) {
                    ForEach(1...10, id: \.self) { n in
                        Button { apply(EntryUpdate(score: n)) } label: {
                            Text("\(n)").font(DS.display(28, 700)).foregroundStyle(Int((cur?.score ?? 0).rounded()) == n ? DS.accent : .white)
                        }
                        .disabled(busy || cur == nil)
                    }
                }
                if (cur?.score ?? 0) > 0 { Button("Remove rating") { apply(EntryUpdate(score: 0)) }.disabled(busy) }
                if cur == nil { Text("Choose a status first to add this title to your list, then you can rate it.").font(DS.body(22)).foregroundStyle(DS.textTertiary) }
                if let error { Text(error).foregroundStyle(DS.pink) }
            }
            .padding(60)
        }
    }

    private func apply(_ update: EntryUpdate) {
        busy = true; error = nil
        Task {
            do { cur = try await save(update) }
            catch {
                self.error = (error as? APIError).flatMap { if case .http(409, _) = $0 { String(localized: "Connect a list from Profile") } else { nil } } ?? error.localizedDescription
            }
            busy = false
        }
    }
}
