import Foundation

// Mirrors the JSON of AnimeRoll.Server (camelCase).

public struct UserDTO: Codable, Hashable, Sendable {
    public let id: UUID
    public let username: String
    public let aniListConnected: Bool
    public let aniListUserName: String?
    public let passkeyCount: Int
}

public struct AuthResponse: Codable, Sendable {
    public let accessToken: String
    public let user: UserDTO
}

public struct AuthStatus: Codable, Sendable {
    public let needsSetup: Bool
    public let registrationOpen: Bool
}

public struct AniListMedia: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let titleRomaji: String?
    public let description: String?
    public let coverUrl: String?
    public let bannerUrl: String?
    public let episodes: Int?
    public let year: Int?
    public let status: String?
    public let format: String?
    public let genres: [String]
    public let averageScore: Int?
    public let nextAiringEpisode: Int?

    public var plainDescription: String {
        (description ?? "")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}

public struct AniListEntry: Codable, Hashable, Sendable {
    public let media: AniListMedia
    public let status: String
    public let progress: Int
    public let score: Double?
}

public struct SeriesDTO: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let aniListId: Int?
    public let title: String
    public let titleRomaji: String?
    public let description: String?
    public let posterUrl: String?
    public let bannerUrl: String?
    public let totalEpisodes: Int?
    public let genres: String?
    public let year: Int?
    public let episodeCount: Int
    public let updatedAt: Date
}

public struct EpisodeDTO: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let seriesId: Int
    public let number: Double
    public let title: String?
    public let sizeBytes: Int64
    public let durationSeconds: Double?
    public let source: String
    public let positionSeconds: Double?
    public let completed: Bool

    public var numberLabel: String {
        number.rounded() == number ? String(Int(number)) : String(number)
    }

    public var progressFraction: Double? {
        guard let p = positionSeconds, let d = durationSeconds, d > 0 else { return nil }
        return min(1, p / d)
    }
}

public struct ContinueWatching: Codable, Hashable, Sendable {
    public let series: SeriesDTO
    public let episode: EpisodeDTO
}

public struct HomeDTO: Codable, Sendable {
    public let continueWatching: [ContinueWatching]
    public let recentlyAdded: [SeriesDTO]
    public let aniListWatching: [AniListEntry]
    public let trending: [AniListMedia]
    public let seasonal: [AniListMedia]
}

public struct StreamInfo: Codable, Sendable {
    public let url: URL
    public let downloadUrl: URL
    public let durationSeconds: Double?
    public let resumeAt: Double?
    /// WebVTT tracks next to the episode (nil from servers older than sidecar subtitles).
    public let subtitles: [SubtitleInfo]?
}

public struct ProviderInfo: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let enabled: Bool
    public let canSearch: Bool
    public let canListEpisodes: Bool
    public let canStream: Bool
    /// Can fetch only the subtitle files of an episode ("Aggiorna sottotitoli").
    public let canSubtitles: Bool?
    public let hint: String?
    /// Regex a pasted reference must match (download-only plugins).
    public let refPattern: String?
    public let isPlugin: Bool?
}

public struct SourceSearchResult: Codable, Hashable, Identifiable, Sendable {
    public let ref: String
    public let title: String
    public let posterUrl: String?
    public let subtitle: String?
    public let aniListId: Int?
    public let extra: [String: String]?
    public var id: String { ref }
}

public struct SourceEpisode: Codable, Hashable, Identifiable, Sendable {
    public let ref: String
    public let number: Double?
    public let title: String
    public let extra: [String: String]?
    public var id: String { ref }
}

public enum DownloadStatus: String, Codable, Sendable {
    case queued = "Queued", running = "Running", postProcessing = "PostProcessing"
    case completed = "Completed", failed = "Failed", cancelled = "Cancelled", paused = "Paused"
    case unknown

    /// A status added by a newer server must not break the whole list.
    public init(from decoder: Decoder) throws {
        self = DownloadStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    public var label: String {
        switch self {
        case .queued: "In coda"
        case .running: "In corso"
        case .postProcessing: "Post-elaborazione"
        case .completed: "Completato"
        case .failed: "Fallito"
        case .cancelled: "Annullato"
        case .paused: "In pausa"
        case .unknown: "—"
        }
    }
    /// Occupies or waits for a slot.
    public var isActive: Bool { [.queued, .running, .postProcessing].contains(self) }
    public var isRunning: Bool { self == .running || self == .postProcessing }
    public var canPause: Bool { isActive }
    public var canResume: Bool { self == .paused }
    public var canCancel: Bool { isActive || self == .paused }
    public var canRetry: Bool { self == .failed || self == .cancelled }
}

/// Queue order: higher runs first.
public enum DownloadPriority: Int, CaseIterable, Identifiable, Sendable {
    case low = -1, normal = 0, high = 1
    public var id: Int { rawValue }
    public var label: String {
        switch self { case .low: "Bassa"; case .normal: "Normale"; case .high: "Alta" }
    }
}

public struct QueueSettings: Codable, Sendable, Equatable {
    public var maxConcurrentDownloads: Int
    public static let range = 1...10
    public init(maxConcurrentDownloads: Int) { self.maxConcurrentDownloads = maxConcurrentDownloads }
}

public struct DownloadJob: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let source: String
    public let sourceRef: String
    public let seriesTitle: String
    public let aniListId: Int?
    public let episodeNumber: Double?
    public let status: DownloadStatus
    public let priority: Int?
    public let progress: Double
    public let message: String?
    public let episodeId: Int?
    public let createdAt: Date

    /// "Subito", "Alta", "Bassa" or nil for normal priority.
    public var priorityLabel: String? {
        switch priority ?? 0 {
        case 10...: "Subito"
        case 1..<10: "Alta"
        case ..<0: "Bassa"
        default: nil
        }
    }

    /// Source shown in lists ("repair" jobs are library repairs, not downloads).
    public var sourceLabel: String { source == "repair" ? "Riparazione" : source.capitalized }
}

public struct DownloadItem: Codable, Sendable {
    public let sourceRef: String
    public let episodeNumber: Double?
    public init(sourceRef: String, episodeNumber: Double?) {
        self.sourceRef = sourceRef
        self.episodeNumber = episodeNumber
    }
}

public struct DownloadRequest: Codable, Sendable {
    public let source: String
    public let seriesTitle: String
    public let aniListId: Int?
    public let items: [DownloadItem]
    public init(source: String, seriesTitle: String, aniListId: Int?, items: [DownloadItem]) {
        self.source = source
        self.seriesTitle = seriesTitle
        self.aniListId = aniListId
        self.items = items
    }
}

public struct TelegramChannel: Codable, Hashable, Identifiable, Sendable {
    public let id: Int64
    public let title: String
    public let username: String?
    public var enabled: Bool
}

public struct TelegramStatus: Codable, Sendable {
    public let configured: Bool
    public let loggedIn: Bool
}

public struct PasskeyInfo: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let createdAt: Date
    public let lastUsedAt: Date?
}

/// Anything the UI can open as a "title" page: either already on the NAS or only on AniList.
/// A title AniList links to this one (stagione precedente/successiva, storia parallela…); `relation` is already in Italian.
public struct RelatedDTO: Codable, Hashable, Sendable {
    public let relation: String
    public let media: AniListMedia
}

public enum TitleRef: Hashable, Sendable {
    case series(SeriesDTO)
    case aniList(AniListMedia)

    public var title: String {
        switch self { case .series(let s): s.title; case .aniList(let m): m.title }
    }
    public var posterURL: URL? {
        switch self {
        case .series(let s): s.posterUrl.flatMap(URL.init(string:))
        case .aniList(let m): m.coverUrl.flatMap(URL.init(string:))
        }
    }
    public var bannerURL: URL? {
        switch self {
        case .series(let s): (s.bannerUrl ?? s.posterUrl).flatMap(URL.init(string:))
        case .aniList(let m): (m.bannerUrl ?? m.coverUrl).flatMap(URL.init(string:))
        }
    }
    public var aniListId: Int? {
        switch self { case .series(let s): s.aniListId; case .aniList(let m): m.id }
    }
}

public extension SeriesDTO {
    /// The server stores genres as "Action, Drama".
    var genreList: [String] {
        (genres ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Space on the NAS disk: what is free, what the library takes, and the reserve the server always keeps free.
public struct StorageInfo: Codable, Sendable, Equatable {
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let libraryBytes: Int64
    public let reserveBytes: Int64
    public var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
}
