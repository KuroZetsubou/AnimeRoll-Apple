import Foundation
import Observation
import Security

/// Logged-in state shared by the whole app. Token lives in the Keychain.
@MainActor
@Observable
public final class AppSession {
    public private(set) var user: UserDTO?
    public private(set) var isRestoring = true
    /// The server could not be reached at launch: the app opens with the last known user so
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
            // Away from home the server can hang instead of refusing: give up after a few seconds and open offline.
            setUser(try await Self.withTimeout(seconds: 8) { try await self.api.me() })
            isOffline = false
        } catch APIError.notLoggedIn {
            logout()
        } catch APIError.http(let code, _) where code == 401 || code == 403 {
            logout()   // the server answered: the saved login is no longer valid
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

    /// Opens the app without a login, only to play what is saved on this device (the server is unreachable
    /// and there is no remembered user, e.g. right after a reinstall of the server-side account).
    public func continueOffline() {
        let json = #"{"id":"00000000-0000-0000-0000-000000000000","username":"Offline","aniListConnected":false,"passkeyCount":0}"#
        user = try? APIClient.decoder.decode(UserDTO.self, from: Data(json.utf8))
        isOffline = user != nil
    }

    /// Called when the app comes back to the foreground: leaves offline mode once the server answers.
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

    /// Switches to another profile ("Who's watching?"); throws when the passcode is wrong.
    public func enterProfile(_ id: UUID, passcode: String?) async throws {
        accept(try await api.enterProfile(id, passcode: passcode))
        profilePicked = true
    }

    /// The profile picker is shown once per launch after sign-in, when the server has more than one profile.
    public var profilePicked = false
    public var showProfilePicker = false

    /// After sign-in: with more than one profile on the server, asks "Who's watching?" once.
    public func checkProfilePicker() async {
        guard isLoggedIn, !isOffline, !profilePicked else { return }
        let count = (try? await api.profiles().count) ?? 0
        if count > 1 { showProfilePicker = true } else { profilePicked = true }
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
        profilePicked = false
        showProfilePicker = false
        api.token = nil
        Keychain.delete("token")
        setUser(nil)
        isOffline = false
    }
}

enum Keychain {
    #if DEBUG
    private static let service = ProcessInfo.processInfo.environment["AR_KEYCHAIN_SERVICE"] ?? "AnimeRoll"
    /// AR_KEYCHAIN_SERVICE=memory keeps tokens in RAM only: automated test runs never touch the real keychain.
    private static let inMemory = service == "memory"
    nonisolated(unsafe) private static var memory: [String: String] = [:]
    #else
    private static let service = "AnimeRoll"
    #endif

    #if os(macOS)
    /// The file-based login keychain asks for the user's password whenever the app's signature changes (every
    /// development build); the data-protection keychain does not. Falls back to the login keychain when the
    /// build is not allowed to use it (ad-hoc signed).
    private static let dataProtection: [String: Any] = [kSecUseDataProtectionKeychain as String: true]
    #endif

    static func read(_ key: String) -> String? {
        #if DEBUG
        if inMemory { return memory[key] }
        #endif
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: AnyObject?
        #if os(macOS)
        if SecItemCopyMatching(q.merging(dataProtection) { $1 } as CFDictionary, &out) == errSecSuccess, let data = out as? Data {
            return String(data: data, encoding: .utf8)
        }
        #endif
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        #if DEBUG
        if inMemory { memory[key] = value; return }
        #endif
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        #if os(macOS)
        if SecItemAdd(q.merging(dataProtection) { $1 } as CFDictionary, nil) == errSecSuccess { return }
        #endif
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        #if DEBUG
        if inMemory { memory[key] = nil; return }
        #endif
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        #if os(macOS)
        SecItemDelete(q.merging(dataProtection) { $1 } as CFDictionary)
        #endif
        SecItemDelete(q as CFDictionary)
    }
}
