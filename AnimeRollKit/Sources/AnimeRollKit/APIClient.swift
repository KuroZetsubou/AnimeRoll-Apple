import Foundation

public enum APIError: LocalizedError {
    case notLoggedIn
    case http(Int, String?)
    case invalidServerURL

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Sessione scaduta, accedi di nuovo."
        case .invalidServerURL: "Indirizzo del NAS non valido."
        case .http(401, _): "Credenziali non valide."
        case .http(409, let msg): msg ?? "Conflitto."
        case .http(let code, let msg): msg ?? "Errore del server (\(code))."
        }
    }
}

/// Async/await client for AnimeRoll.Server.
public final class APIClient: @unchecked Sendable {
    public var baseURL: URL
    public var token: String?
    private let session: URLSession

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            // Older builds saved offline metadata with JSONEncoder's default (seconds since 2001).
            if let seconds = try? c.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: seconds) }
            let s = try c.decode(String.self)
            if let date = APIClient.parseDate(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Data non valida: \(s)"))
        }
        return d
    }()

    /// Dates as ISO 8601 strings: what the server expects and what `decoder` reads back
    /// (offline metadata and index.json round-trip through both).
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = encoder.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        return e
    }()

    /// .NET writes "2026-10-30T18:31:00.1234567Z" or without the trailing Z (SQLite values are UTC).
    static func parseDate(_ raw: String) -> Date? {
        var s = raw
        if !s.hasSuffix("Z") && !s.contains("+") && s.count >= 19 { s += "Z" }
        if let dot = s.firstIndex(of: "."), let end = s.lastIndex(where: { $0 == "Z" || $0 == "+" }) {
            // ISO8601DateFormatter supports at most 3 fraction digits
            let frac = s[s.index(after: dot)..<end].prefix(3)
            s = String(s[..<dot]) + "." + frac + s[end...]
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    // MARK: Core

    private func request(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil,
                         contentType: String = "application/json", auth: Bool = true) async throws -> Data {
        var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.httpBody = body
        if body != nil { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth {
            guard let token else { throw APIError.notLoggedIn }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { $0["error"] as? String ?? $0["detail"] as? String ?? $0["title"] as? String }
            if code == 401 && auth { throw APIError.notLoggedIn }
            throw APIError.http(code, msg)
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], auth: Bool = true) async throws -> T {
        try Self.decoder.decode(T.self, from: try await request("GET", path, query: query, auth: auth))
    }

    private func send<T: Decodable>(_ method: String, _ path: String, json: some Encodable, auth: Bool = true) async throws -> T {
        try Self.decoder.decode(T.self, from: try await request(method, path, body: try Self.encoder.encode(json), auth: auth))
    }

    private func sendNoContent(_ method: String, _ path: String, json: (some Encodable)? = Optional<String>.none) async throws {
        _ = try await request(method, path, body: try json.map { try Self.encoder.encode($0) })
    }

    // MARK: Auth

    public func status() async throws -> AuthStatus { try await get("api/auth/status", auth: false) }

    public func login(username: String, password: String) async throws -> AuthResponse {
        try await send("POST", "api/auth/login", json: ["username": username, "password": password], auth: false)
    }

    public func register(username: String, password: String) async throws -> AuthResponse {
        try await send("POST", "api/auth/register", json: ["username": username, "password": password], auth: false)
    }

    public func me() async throws -> UserDTO { try await get("api/auth/me") }

    /// Raw JSON so the passkey layer can read WebAuthn options without duplicating every Fido2 type.
    public func rawPost(_ path: String, json: [String: Any], auth: Bool) async throws -> [String: Any] {
        let data = try await request("POST", path, body: try JSONSerialization.data(withJSONObject: json), auth: auth)
        if data.isEmpty { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    public func passkeys() async throws -> [PasskeyInfo] { try await get("api/auth/passkeys") }
    public func deletePasskey(_ id: Int) async throws { _ = try await request("DELETE", "api/auth/passkeys/\(id)") }

    // MARK: AniList

    public func aniListConnectURL() async throws -> URL {
        let r: [String: String] = try await get("api/anilist/connect")
        guard let url = URL(string: r["url"] ?? "") else { throw APIError.http(500, "URL AniList mancante") }
        return url
    }
    public func aniListDisconnect() async throws { _ = try await request("DELETE", "api/anilist/connect") }
    public func aniListSearch(_ q: String) async throws -> [AniListMedia] { try await get("api/anilist/search", query: ["q": q]) }
    /// Esplora: one season (WINTER, SPRING, SUMMER, FALL) of a year, optionally one genre.
    public func aniListBrowse(season: String, year: Int, genre: String? = nil) async throws -> [AniListMedia] {
        var q = ["season": season, "year": String(year)]
        if let genre { q["genre"] = genre }
        return try await get("api/anilist/browse", query: q)
    }
    /// "Simili": what AniList recommends to people who liked this title.
    public func aniListRecommendations(_ id: Int) async throws -> [AniListMedia] { try await get("api/anilist/media/\(id)/recommendations") }
    public func aniListRelations(_ id: Int) async throws -> [RelatedDTO] { try await get("api/anilist/media/\(id)/relations") }

    /// Moves episodes to another series (by AniList id), e.g. when they were filed under the wrong season.
    /// `numberOffset` is added to every episode number. Returns the id of the target series.
    public func moveEpisodes(_ ids: [Int], toAniListId: Int, numberOffset: Double) async throws -> Int {
        struct Body: Encodable { let episodeIds: [Int]; let aniListId: Int; let numberOffset: Double }
        struct Reply: Decodable { let seriesId: Int }
        let r: Reply = try await send("POST", "api/library/episodes/move", json: Body(episodeIds: ids, aniListId: toAniListId, numberOffset: numberOffset))
        return r.seriesId
    }
    public func aniListMedia(_ id: Int) async throws -> AniListMedia { try await get("api/anilist/media/\(id)") }
    public func aniListList(_ status: String) async throws -> [AniListEntry] { try await get("api/anilist/list/\(status)") }
    public func aniListEntry(_ mediaId: Int) async throws -> AniListEntry? {
        let data = try await request("GET", "api/anilist/entry/\(mediaId)")
        return try? Self.decoder.decode(AniListEntry.self, from: data)
    }
    public func aniListSetProgress(_ mediaId: Int, progress: Int) async throws {
        try await sendNoContent("PUT", "api/anilist/entry/\(mediaId)/progress", json: ["progress": progress])
    }
    public func aniListSetStatus(_ mediaId: Int, status: String) async throws {
        try await sendNoContent("PUT", "api/anilist/entry/\(mediaId)/status", json: ["status": status])
    }

    // MARK: Library

    public func home() async throws -> HomeDTO { try await get("api/library/home") }
    public func library(query: String? = nil) async throws -> [SeriesDTO] {
        try await get("api/library/series", query: query.map { ["q": $0] } ?? [:])
    }
    public func series(_ id: Int) async throws -> SeriesDTO { try await get("api/library/series/\(id)") }
    public func series(aniListId: Int) async throws -> SeriesDTO? {
        do { return try await get("api/library/by-anilist/\(aniListId)") } catch APIError.http(404, _) { return nil }
    }
    public func episodes(seriesId: Int) async throws -> [EpisodeDTO] { try await get("api/library/series/\(seriesId)/episodes") }
    public func stream(episodeId: Int) async throws -> StreamInfo { try await get("api/library/episodes/\(episodeId)/stream") }

    @discardableResult
    public func saveProgress(episodeId: Int, position: Double, duration: Double?) async throws -> Bool {
        struct Body: Encodable { let positionSeconds: Double; let durationSeconds: Double? }
        struct Res: Decodable { let completed: Bool }
        let r: Res = try await send("PUT", "api/library/episodes/\(episodeId)/progress", json: Body(positionSeconds: position, durationSeconds: duration))
        return r.completed
    }
    /// Deletes the file, subtitles and progress of an episode from the NAS (the series goes with its last episode).
    public func deleteEpisode(_ id: Int) async throws { _ = try await request("DELETE", "api/library/episodes/\(id)") }
    /// Deletes a whole series from the NAS to free space.
    public func deleteSeries(_ id: Int) async throws { _ = try await request("DELETE", "api/library/series/\(id)") }
    /// Disk space on the NAS.
    public func storageInfo() async throws -> StorageInfo { try await get("api/settings/storage") }

    /// Asks the NAS to run the episode file through the import pipeline again (timestamps, A/V sync,
    /// fast start, subtitles). Shows up in the NAS download list as "Riparazione".
    public func repairEpisode(_ id: Int) async throws { _ = try await request("POST", "api/library/episodes/\(id)/repair") }
    public func repairSeries(_ id: Int) async throws { _ = try await request("POST", "api/library/series/\(id)/repair") }
    /// Queues, for every episode of the series in the library, the original (ASS) subtitles from a source; no video is downloaded.
    /// Returns how many episodes were queued and which numbers the source doesn't have.
    public func refreshSubtitles(seriesId: Int, source: String, seriesRef: String) async throws -> (queued: Int, notFound: [Double]) {
        struct Body: Encodable { let source: String; let seriesRef: String }
        struct Reply: Decodable { let queued: Int; let notFound: [Double] }
        let r: Reply = try await send("POST", "api/library/series/\(seriesId)/subtitles", json: Body(source: source, seriesRef: seriesRef))
        return (r.queued, r.notFound)
    }
    public func scanInbox() async throws -> Int {
        let r: [String: Int] = try await send("POST", "api/library/scan-inbox", json: [String: String]())
        return r["imported"] ?? 0
    }

    // MARK: Sources & NAS downloads

    public func providers() async throws -> [ProviderInfo] { try await get("api/sources") }
    public func search(source: String, query: String) async throws -> [SourceSearchResult] {
        try await get("api/sources/\(source)/search", query: ["q": query])
    }
    public func sourceEpisodes(source: String, ref: String) async throws -> [SourceEpisode] {
        try await get("api/sources/\(source)/episodes", query: ["ref": ref])
    }
    public func sourceStreamURL(source: String, ref: String) async throws -> URL {
        let r: [String: String] = try await get("api/sources/\(source)/stream", query: ["ref": ref])
        guard let u = URL(string: r["url"] ?? "") else { throw APIError.http(404, "Stream non trovato") }
        return u
    }

    /// Tells the NAS to download; the NAS does the work, the device can be closed.
    @discardableResult
    public func requestNASDownload(_ req: DownloadRequest) async throws -> [DownloadJob] { try await send("POST", "api/downloads", json: req) }
    public func nasDownloads(activeOnly: Bool = false) async throws -> [DownloadJob] {
        try await get("api/downloads", query: activeOnly ? ["active": "true"] : [:])
    }
    public func cancelNASDownload(_ id: UUID) async throws { _ = try await request("POST", "api/downloads/\(id)/cancel") }
    public func retryNASDownload(_ id: UUID) async throws { _ = try await request("POST", "api/downloads/\(id)/retry") }
    public func clearFinishedNASDownloads() async throws { _ = try await request("DELETE", "api/downloads/finished") }

    // Queue control
    public func pauseNASDownload(_ id: UUID) async throws { _ = try await request("POST", "api/downloads/\(id)/pause") }
    public func resumeNASDownload(_ id: UUID) async throws { _ = try await request("POST", "api/downloads/\(id)/resume") }
    /// Top of the queue; if every slot is busy the lowest-priority job steps back and resumes later.
    public func startNASDownloadNow(_ id: UUID) async throws { _ = try await request("POST", "api/downloads/\(id)/start-now") }
    public func setNASDownloadPriority(_ id: UUID, _ priority: DownloadPriority) async throws {
        try await sendNoContent("PUT", "api/downloads/\(id)/priority", json: ["priority": priority.rawValue])
    }
    public func pauseAllNASDownloads() async throws { _ = try await request("POST", "api/downloads/pause-all") }
    public func resumeAllNASDownloads() async throws { _ = try await request("POST", "api/downloads/resume-all") }
    public func queueSettings() async throws -> QueueSettings { try await get("api/settings/queue") }
    @discardableResult
    public func setQueueSettings(_ s: QueueSettings) async throws -> QueueSettings { try await send("PUT", "api/settings/queue", json: s) }

    // MARK: Telegram

    public func telegramStatus() async throws -> TelegramStatus { try await get("api/telegram/status") }
    public func telegramLogin(code: String?) async throws -> String? {
        struct Res: Decodable { let next: String? }
        let r: Res = try await send("POST", "api/telegram/login", json: ["code": code])
        return r.next
    }
    public func telegramChannels() async throws -> [TelegramChannel] { try await get("api/telegram/channels") }
    public func saveTelegramChannels(_ channels: [TelegramChannel]) async throws {
        try await sendNoContent("PUT", "api/telegram/channels", json: channels)
    }
}
