import AnimeRollKit
import SwiftUI

struct LoginView: View {
    @Environment(AppSession.self) private var session
    @State private var username = ""
    @State private var password = ""
    @State private var isRegistering = false
    @State private var busy = false
    @Environment(OfflineDownloads.self) private var offline
    @State private var error: String?

    var body: some View {
        @Bindable var session = session
        ScrollView {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    (Text("Anime") + Text("Roll").foregroundStyle(DS.accent)).font(DS.display(44, 800)).tracking(-0.9)
                    Text("Il tuo catalogo anime sul NAS").font(DS.body(16)).foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, 72)

                VStack(spacing: 14) {
                    LoginField(label: "Indirizzo NAS", icon: "server.rack") {
                        TextField("https://…", text: $session.serverURLString)
                            .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    LoginField(label: "Username", icon: "person") {
                        TextField("", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    LoginField(label: "Password", icon: "lock") {
                        SecureField("••••••••", text: $password).textContentType(isRegistering ? .newPassword : .password)
                    }
                }
                .multilineTextAlignment(.leading)

                if let error { ErrorBanner(message: error).padding(.horizontal, -16) }

                VStack(spacing: 12) {
                    Button {
                        run { isRegistering ? try await session.register(username: username, password: password)
                                            : try await session.login(username: username, password: password) }
                    } label: {
                        Text(isRegistering ? "Crea account" : "Accedi")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(username.isEmpty || password.isEmpty || busy)
                    .opacity(username.isEmpty || password.isEmpty ? 0.5 : 1)

                    Button {
                        run { try await session.loginWithPasskey(username: username.isEmpty ? nil : username) }
                    } label: {
                        Label("Accedi con passkey", systemImage: "person.badge.key.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle(prominent: false)).disabled(busy)

                    if !offline.items.isEmpty {
                        Button { session.continueOffline() } label: { Label("Guarda i download offline", systemImage: "arrow.down.circle") }
                            .buttonStyle(PrimaryButtonStyle(prominent: false))
                    }
                    Button(isRegistering ? "Ho già un account" : "Primo avvio? Crea l'account") { isRegistering.toggle() }
                        .font(DS.body(14, 600)).foregroundStyle(DS.accent)
                }
                if busy { ProgressView() }
            }
            .padding(24)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
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

/// Labelled login field with a leading icon.
private struct LoginField<Field: View>: View {
    let label: String
    let icon: String
    @ViewBuilder let field: () -> Field
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(DS.body(12, 700)).tracking(1).foregroundStyle(DS.textTertiary)
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(DS.textTertiary).frame(width: 20)
                field().font(DS.body(16)).textFieldStyle(.plain)
            }
            .padding(.horizontal, 16).frame(height: 52)
            .background(DS.surface, in: .rect(cornerRadius: DS.rCard))
            .overlay(RoundedRectangle(cornerRadius: DS.rCard).strokeBorder(DS.hairline))
        }
    }
}
