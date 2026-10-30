import Foundation
import Observation
import Security

/// Logged-in state shared by the whole app. Token lives in the Keychain.
@MainActor
@Observable
public final class AppSession {
    public private(set) var user: UserDTO?
    public private(set) var isRestoring = true
    public var serverURLString: String {
        didSet { UserDefaults.standard.set(serverURLString, forKey: "serverURL") }
    }

    public let api: APIClient

    public var isLoggedIn: Bool { user != nil }

    public init() {
        let saved = UserDefaults.standard.string(forKey: "serverURL") ?? "https://"
        serverURLString = saved
        api = APIClient(baseURL: URL(string: saved) ?? URL(string: "http://localhost:8080")!, token: Keychain.read("token"))
    }

    public func restore() async {
        defer { isRestoring = false }
        guard api.token != nil else { return }
        do { user = try await api.me() } catch APIError.notLoggedIn { logout() } catch { /* offline: stay logged out of UI but keep token */ }
    }

    public func applyServerURL() throws {
        guard let url = URL(string: serverURLString.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true, url.host != nil
        else { throw APIError.invalidServerURL }
        api.baseURL = url
    }

    public func login(username: String, password: String) async throws {
        try applyServerURL()
        accept(try await api.login(username: username, password: password))
    }

    public func register(username: String, password: String) async throws {
        try applyServerURL()
        accept(try await api.register(username: username, password: password))
    }

    public func loginWithPasskey(username: String?) async throws {
        try applyServerURL()
        accept(try await PasskeyAuthenticator(api: api).login(username: username))
    }

    public func registerPasskey(name: String) async throws {
        try await PasskeyAuthenticator(api: api).register(name: name)
        await refreshUser()
    }

    public func refreshUser() async {
        if let u = try? await api.me() { user = u }
    }

    public func accept(_ auth: AuthResponse) {
        api.token = auth.accessToken
        Keychain.write("token", auth.accessToken)
        user = auth.user
    }

    public func logout() {
        api.token = nil
        Keychain.delete("token")
        user = nil
    }
}

enum Keychain {
    private static let service = "AnimeRoll"

    static func read(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}
