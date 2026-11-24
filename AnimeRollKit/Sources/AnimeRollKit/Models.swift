import Foundation
import SwiftUI

// Mirrors the JSON of AnimeRoll.Server (camelCase).

public struct UserDTO: Codable, Hashable, Sendable {
    public let id: UUID
    public let username: String
    public let aniListConnected: Bool
    public let aniListUserName: String?
    public let passkeyCount: Int
    /// Avatar colour index (0...7); the avatar is that colour plus the initial of the name.
    public let avatar: Int
    public let hasPasscode: Bool
    /// List in use: "anilist" or "mal"; nil when no list is connected.
    public let tracker: String?
    public let malConnected: Bool
    public let malUserName: String?

    /// A list (AniList or MyAnimeList) is connected, so the title page can show and change status and rating.
    public var hasTracker: Bool { tracker != nil }

    private enum CodingKeys: String, CodingKey {
        case id, username, aniListConnected, aniListUserName, passkeyCount, avatar, hasPasscode, tracker, malConnected, malUserName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        username = try c.decode(String.self, forKey: .username)
        aniListConnected = try c.decodeIfPresent(Bool.self, forKey: .aniListConnected) ?? false
        aniListUserName = try c.decodeIfPresent(String.self, forKey: .aniListUserName)
        passkeyCount = try c.decodeIfPresent(Int.self, forKey: .passkeyCount) ?? 0
        avatar = try c.decodeIfPresent(Int.self, forKey: .avatar) ?? 0
        hasPasscode = try c.decodeIfPresent(Bool.self, forKey: .hasPasscode) ?? false
        tracker = try c.decodeIfPresent(String.self, forKey: .tracker)
        malConnected = try c.decodeIfPresent(Bool.self, forKey: .malConnected) ?? false
        malUserName = try c.decodeIfPresent(String.self, forKey: .malUserName)
    }
}

/// One profile of the server (a profile is a user): "Who's watching?".
public struct ProfileDTO: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let avatar: Int
    public let hasPasscode: Bool
    public let isCurrent: Bool
    public let isOwner: Bool
}

public struct TrackerAccount: Codable, Hashable, Sendable {
    public let configured: Bool
    public let connected: Bool
    public let userName: String?
}

public struct TrackerInfo: Codable, Hashable, Sendable {
    public let active: String?
    public let aniList: TrackerAccount
    public let mal: TrackerAccount
}

/// Manual change of a list entry; every field is optional, score 0 removes the rating.
public struct EntryUpdate: Encodable, Sendable {
    public var status: String?
    public var progress: Int?
    public var score: Int?
    public init(status: String? = nil, progress: Int? = nil, score: Int? = nil) { self.status = status; self.progress = progress; self.score = score }
}

/// Statuses of a list entry (AniList names, also used for MyAnimeList).
public enum ListStatus {
    public static let all = ["CURRENT", "PLANNING", "COMPLETED", "PAUSED", "DROPPED", "REPEATING"]
}

/// Avatar palette shared by every client: index 0...7.
public enum AvatarPalette {
    public static let colors: [Color] = ([0xFF6A1A, 0xE5484D, 0xF5A524, 0x30A46C, 0x12A594, 0x3E63DD, 0x8E4EC6, 0xD6409F] as [UInt32]).map { Color(hex: $0) }
    public static func color(_ i: Int) -> Color { colors[((i % colors.count) + colors.count) % colors.count] }
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
    public let nextAiringAt: Int64?
    public let malId: Int?

    /// "E5 · sab 8 nov, 18:30" for ongoing series, nil when AniList has no schedule.
    public var nextAiringText: String? {
        guard let ep = nextAiringEpisode, let at = nextAiringAt else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.setLocalizedDateFormatFromTemplate("EEE d MMM HH:mm")
        return String(localized: "Next episode (E\(ep)): \(f.string(from: Date(timeIntervalSince1970: TimeInterval(at))))", bundle: .module)
    }

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

/// Hand edits of a series: nil leaves a field as it is, "" clears a text field, aniListId 0 unlinks it.
public struct SeriesEdit: Encodable, Sendable {
    public var title: String?
    public var description: String?
    public var posterUrl: String?
    public var bannerUrl: String?
    public var aniListId: Int?
    public var refreshFromAniList: Bool
    public init(title: String? = nil, description: String? = nil, posterUrl: String? = nil, bannerUrl: String? = nil,
                aniListId: Int? = nil, refreshFromAniList: Bool = false) {
        self.title = title; self.description = description; self.posterUrl = posterUrl; self.bannerUrl = bannerUrl
        self.aniListId = aniListId; self.refreshFromAniList = refreshFromAniList
    }
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
    public let isExtra: Bool?

    /// Bonus content (EX1): not counted for AniList.
    public var extra: Bool { isExtra ?? false }

    /// "5", "5.5", or "X1" for extras (so "E" + label reads "EX1").
    public var numberLabel: String {
        let n = number.rounded() == number ? String(Int(number)) : String(number)
        return extra ? "X" + n : n
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
        case .queued: "Queued"
        case .running: "Airing"
        case .postProcessing: "Processing"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .paused: "Paused"
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
        switch self { case .low: String(localized: "Low", bundle: .module); case .normal: String(localized: "Normal", bundle: .module); case .high: String(localized: "High", bundle: .module) }
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
        case 10...: String(localized: "Now", bundle: .module)
        case 1..<10: String(localized: "High", bundle: .module)
        case ..<0: String(localized: "Low", bundle: .module)
        default: nil
        }
    }

    /// Source shown in lists ("repair" jobs are library repairs, not downloads).
    public var sourceLabel: String { source == "repair" ? String(localized: "Repair", bundle: .module) : source.capitalized }
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

/// Anything the UI can open as a "title" page: either already on the server or only on AniList.
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

/// Space on the server disk: what is free, what the library takes, and the reserve the server always keeps free.
public struct StorageInfo: Codable, Sendable, Equatable {
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let libraryBytes: Int64
    public let reserveBytes: Int64
    public var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
}
