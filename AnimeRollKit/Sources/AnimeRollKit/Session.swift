import Foundation
import Observation
import Security

/// Logged-in state shared by the whole app. Token lives in the Keychain.
@MainActor
@Observable
public final class AppSession {
    public private(set) var user: UserDTO?
    public private(set) var isRestoring = true
    /// The NAS could not be reached at launch: the app opens with the last known user so
    /// episodes saved on the device stay playable (away from home, no network).
    public private(set) var isOffline = false
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
        do {
            // Away from home the NAS can hang instead of refusing: give up after a few seconds and open offline.
            setUser(try await Self.withTimeout(seconds: 8) { try await self.api.me() })
            isOffline = false
        } catch APIError.notLoggedIn {
            logout()
        } catch APIError.http(let code, _) where code == 401 || code == 403 {
            logout()   // the NAS answered: the saved login is no longer valid
        } catch {
            user = Self.cachedUser
            isOffline = user != nil
        }
    }

    private struct TimedOut: Error {}

    private static func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw TimedOut() }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Opens the app without a login, only to play what is saved on this device (the NAS is unreachable
    /// and there is no remembered user, e.g. right after a reinstall of the NAS-side account).
    public func continueOffline() {
        let json = #"{"id":"00000000-0000-0000-0000-000000000000","username":"Offline","aniListConnected":false,"passkeyCount":0}"#
        user = try? APIClient.decoder.decode(UserDTO.self, from: Data(json.utf8))
        isOffline = user != nil
    }

    /// Called when the app comes back to the foreground: leaves offline mode once the NAS answers.
    public func retryIfOffline() async {
        guard isOffline, let u = try? await api.me() else { return }
        setUser(u)
        isOffline = false
    }

    private static let userKey = "cachedUser"
    private static var cachedUser: UserDTO? {
        UserDefaults.standard.data(forKey: userKey).flatMap { try? APIClient.decoder.decode(UserDTO.self, from: $0) }
    }

    private func setUser(_ u: UserDTO?) {
        user = u
        if let u, let data = try? APIClient.encoder.encode(u) { UserDefaults.standard.set(data, forKey: Self.userKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.userKey) }
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
        if let u = try? await api.me() { setUser(u); isOffline = false }
    }

    public func accept(_ auth: AuthResponse) {
        api.token = auth.accessToken
        Keychain.write("token", auth.accessToken)
        setUser(auth.user)
        isOffline = false
    }

    public func logout() {
        api.token = nil
        Keychain.delete("token")
        setUser(nil)
        isOffline = false
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
