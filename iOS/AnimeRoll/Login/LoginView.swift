import AnimeRollKit
import SwiftUI

struct LoginView: View {
    @Environment(AppSession.self) private var session
    @State private var username = ""
    @State private var password = ""
    @State private var isRegistering = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        @Bindable var session = session
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Image(systemName: "play.tv.fill").font(.system(size: 56)).foregroundStyle(Theme.accent)
                    Text("AnimeRoll").font(.largeTitle.bold())
                    Text("Il tuo catalogo anime sul NAS").foregroundStyle(.secondary)
                }
                .padding(.top, 48)

                VStack(spacing: 12) {
                    TextField("Indirizzo NAS (https://…)", text: $session.serverURLString)
                        .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Username", text: $username)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(isRegistering ? .newPassword : .password)
                }
                .textFieldStyle(.plain)
                .padding(14)
                .background(Theme.card, in: .rect(cornerRadius: 14))

                if let error { ErrorBanner(message: error).padding(.horizontal, -16) }

                VStack(spacing: 12) {
                    Button {
                        run { isRegistering ? try await session.register(username: username, password: password)
                                            : try await session.login(username: username, password: password) }
                    } label: {
                        Text(isRegistering ? "Crea account" : "Accedi").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(username.isEmpty || password.isEmpty || busy)

                    Button {
                        run { try await session.loginWithPasskey(username: username.isEmpty ? nil : username) }
                    } label: {
                        Label("Accedi con passkey", systemImage: "person.badge.key.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large).disabled(busy)

                    Button(isRegistering ? "Ho già un account" : "Primo avvio? Crea l'account") { isRegistering.toggle() }
                        .font(.footnote)
                }
                if busy { ProgressView() }
            }
            .padding(24)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
