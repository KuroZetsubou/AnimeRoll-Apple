import AnimeRollKit
import SwiftUI

/// "Who's watching?": one avatar per profile of the server; a profile with a passcode asks for it.
struct ProfilePickerView: View {
    @Environment(AppSession.self) private var session
    @State private var profiles: [ProfileDTO] = []
    @State private var locked: ProfileDTO?
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Text("Who's watching?").font(DS.display(30, 800)).padding(.top, 72)
                if let error { Text(error).font(DS.body(13)).foregroundStyle(DS.pink) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 20)], spacing: 24) {
                    ForEach(profiles) { p in
                        Button { pick(p) } label: {
                            VStack(spacing: 10) {
                                AvatarView(name: p.name, index: p.avatar, size: 96)
                                HStack(spacing: 4) {
                                    Text(p.name).font(DS.body(15, 600)).lineLimit(1)
                                    if p.hasPasscode { Image(systemName: "lock.fill").font(.caption) }
                                }
                                .foregroundStyle(p.isCurrent ? DS.accent : DS.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Button { adding = true } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "plus").font(.system(size: 34, weight: .semibold)).foregroundStyle(DS.textSecondary)
                                .frame(width: 96, height: 96).background(DS.surface, in: .circle)
                            Text("Add profile").font(DS.body(15, 600)).foregroundStyle(DS.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                if session.profilePicked {
                    Button("Cancel") { session.showProfilePicker = false }
                        .buttonStyle(PrimaryButtonStyle(prominent: false, small: true))
                }
            }
            .frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .task { await load() }
        .sheet(item: $locked) { p in
            PasscodeAskSheet(profile: p) { code in try await enter(p, code) }
        }
        .sheet(isPresented: $adding) {
            ProfileFormSheet(mode: .create) { adding = false; Task { await load() } }
        }
    }

    private func load() async {
        do { profiles = try await session.api.profiles() } catch { self.error = error.localizedDescription }
    }

    private func pick(_ p: ProfileDTO) {
        if p.hasPasscode && !p.isCurrent { locked = p }
        else { Task { try? await enter(p, nil) } }
    }

    private func enter(_ p: ProfileDTO, _ code: String?) async throws {
        do {
            try await session.enterProfile(p.id, passcode: code)
            session.showProfilePicker = false
        } catch { self.error = error.localizedDescription; throw error }
    }
}

struct PasscodeAskSheet: View {
    let profile: ProfileDTO
    let submit: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 18) {
            AvatarView(name: profile.name, index: profile.avatar, size: 64).padding(.top, 28)
            Text(profile.name).font(DS.display(20, 700))
            SecureField("Passcode", text: $code)
                .textContentType(.oneTimeCode).font(DS.body(16)).padding(.horizontal, 14).frame(height: 48)
                .background(DS.surface, in: .rect(cornerRadius: DS.rCard))
            if let error { Text(error).font(DS.body(13)).foregroundStyle(DS.pink) }
            Button("Enter") {
                busy = true; error = nil
                Task {
                    do { try await submit(code); dismiss() } catch { self.error = error.localizedDescription; busy = false }
                }
            }
            .buttonStyle(PrimaryButtonStyle()).disabled(code.count < 4 || busy)
            Spacer()
        }
        .padding(.horizontal, 24)
        .presentationDetents([.height(380)]).presentationBackground(DS.surfaceRaised)
    }
}

/// Colour swatches: the avatar is the chosen colour plus the initial of the name.
struct AvatarColorPicker: View {
    @Binding var selection: Int
    let name: String
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
            ForEach(0..<AvatarPalette.colors.count, id: \.self) { i in
                Button { selection = i } label: {
                    AvatarView(name: name.isEmpty ? "?" : name, index: i, size: 52)
                        .overlay(Circle().strokeBorder(.white, lineWidth: selection == i ? 3 : 0).padding(-4))
                }
                .buttonStyle(.plain).accessibilityLabel("Avatar \(i + 1)")
            }
        }
        .padding(.vertical, 6)
    }
}

/// New profile (name, colour, optional passcode) or edit of the current one (name, colour).
struct ProfileFormSheet: View {
    enum Mode { case create, edit(UserDTO) }
    let mode: Mode
    let done: () -> Void
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var avatar = Int.random(in: 0..<8)
    @State private var passcode = ""
    @State private var error: String?
    @State private var busy = false

    private var creating: Bool { if case .create = mode { true } else { false } }
    private var valid: Bool { name.trimmingCharacters(in: .whitespaces).count >= 2 && (!creating || passcode.isEmpty || passcode.count >= 4) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(creating ? "New profile" : "Edit profile").font(DS.display(20, 700)).padding(.top, 28)
                field("Name") { TextField("", text: $name).autocorrectionDisabled().onChange(of: name) { _, v in if v.count > 24 { name = String(v.prefix(24)) } } }
                AvatarColorPicker(selection: $avatar, name: name)
                if creating {
                    field("Passcode (optional, 4-12 characters)") { SecureField("", text: $passcode).textContentType(.oneTimeCode) }
                    Text("Each profile has its own watch history and its own AniList or MyAnimeList list. The library is shared. A passcode keeps others from entering this profile.")
                        .font(DS.body(12)).foregroundStyle(DS.textTertiary)
                }
                if let error { Text(error).font(DS.body(13)).foregroundStyle(DS.pink) }
                Button(creating ? "Create profile" : "Save") { save() }
                    .buttonStyle(PrimaryButtonStyle()).disabled(!valid || busy).opacity(valid ? 1 : 0.5)
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
        .presentationDetents([.large]).presentationBackground(DS.surfaceRaised)
        .onAppear { if case .edit(let u) = mode { name = u.username; avatar = u.avatar } }
    }

    private func field<F: View>(_ label: LocalizedStringKey, @ViewBuilder _ f: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(DS.body(12, 700)).tracking(0.5).foregroundStyle(DS.textTertiary)
            f().font(DS.body(16)).padding(.horizontal, 14).frame(height: 48).background(DS.surface, in: .rect(cornerRadius: DS.rCard))
        }
    }

    private func save() {
        busy = true; error = nil
        let n = name.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                switch mode {
                case .create: try await session.api.createProfile(name: n, avatar: avatar, passcode: passcode.isEmpty ? nil : passcode)
                case .edit(let u): try await session.api.updateProfile(u.id, name: n, avatar: avatar); await session.refreshUser()
                }
                done(); dismiss()
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
}

/// Set, change or remove the passcode of the current profile.
struct PasscodeSheet: View {
    let user: UserDTO
    let done: () -> Void
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var next = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Passcode").font(DS.display(20, 700)).padding(.top, 28)
            if user.hasPasscode { secure("Current passcode", $current) }
            secure("New passcode (4-12 characters)", $next)
            Text("The passcode is asked when someone switches to this profile from another one. It does not replace the password or passkey used to sign in to the server.")
                .font(DS.body(12)).foregroundStyle(DS.textTertiary)
            if let error { Text(error).font(DS.body(13)).foregroundStyle(DS.pink) }
            Button("Save") { save(remove: false) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy || next.count < 4 || next.count > 12 || (user.hasPasscode && current.isEmpty))
            if user.hasPasscode {
                Button("Remove passcode") { save(remove: true) }
                    .buttonStyle(PrimaryButtonStyle(prominent: false)).disabled(busy || current.isEmpty)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .presentationDetents([.large]).presentationBackground(DS.surfaceRaised)
    }

    private func secure(_ label: LocalizedStringKey, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(DS.body(12, 700)).tracking(0.5).foregroundStyle(DS.textTertiary)
            SecureField("", text: text).textContentType(.oneTimeCode).font(DS.body(16))
                .padding(.horizontal, 14).frame(height: 48).background(DS.surface, in: .rect(cornerRadius: DS.rCard))
        }
    }

    private func save(remove: Bool) {
        busy = true; error = nil
        Task {
            do {
                try await session.api.setPasscode(current: user.hasPasscode ? current : nil, passcode: remove ? nil : next)
                await session.refreshUser()
                done(); dismiss()
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
}
