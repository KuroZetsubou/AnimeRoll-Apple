import Foundation
import Observation

/// An episode saved on this device (downloaded from the NAS).
public struct OfflineEpisode: Codable, Hashable, Identifiable, Sendable {
    public let episode: EpisodeDTO
    public let series: SeriesDTO
    public let fileName: String
    public var id: Int { episode.id }
}

/// Downloads episodes from the NAS to the device with a background URLSession,
/// so they continue while the app is closed (iOS). On tvOS the system may purge
/// the Caches folder when space is low, so downloads there are best-effort.
@MainActor
@Observable
public final class OfflineDownloads: NSObject {
    public static let shared = OfflineDownloads()

    public private(set) var items: [OfflineEpisode] = []
    /// episodeId → progress 0…1 for downloads in flight.
    public private(set) var inFlight: [Int: Double] = [:]
    public var lastError: String?

    /// Set from the app delegate's handleEventsForBackgroundURLSession.
    public var backgroundCompletionHandler: (() -> Void)?

    @ObservationIgnored private var pending: [Int: (EpisodeDTO, SeriesDTO)] = [:]
    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.animeroll.offline")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    nonisolated private static var folder: URL {
        #if os(tvOS)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        let dir = base.appending(path: "Offline", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated private static var indexURL: URL { folder.appending(path: "index.json") }

    /// Where the videos go. On iOS: Documents, shown in the Files app ("Su iPhone › AnimeRoll"),
    /// so they can be opened in other apps. Index and subtitles stay hidden in `folder`.
    nonisolated public static var videoFolder: URL {
        #if os(tvOS)
        return folder
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
    }

    /// "Frieren/Frieren - Episodio 3.mp4": readable in the Files app, one folder per series.
    nonisolated static func videoPath(episode: EpisodeDTO, series: SeriesDTO) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines)
        let title = series.title.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        let dir = title.isEmpty ? "Serie \(series.id)" : title
        return "\(dir)/\(dir) - Episodio \(episode.numberLabel).mp4"
    }

    override private init() {
        super.init()
        if let data = try? Data(contentsOf: Self.indexURL),
           let saved = try? APIClient.decoder.decode([OfflineEpisode].self, from: data) {
            items = saved.compactMap(Self.migrated)
                // Deleted (or moved) from the Files app: no longer offline.
                .filter { FileManager.default.fileExists(atPath: Self.videoFolder.appending(path: $0.fileName).path) }
            if items.count != saved.count || items != saved { save() }
        }
        // Reconnect to background tasks: downloads still running after a relaunch show their progress again.
        session.getAllTasks { tasks in
            let ids = tasks.filter { $0.state == .running || $0.state == .suspended }
                .compactMap { $0.taskDescription.flatMap(PendingMeta.decode)?.episode.id }
            Task { @MainActor in for id in ids where self.inFlight[id] == nil { self.inFlight[id] = 0 } }
        }
    }

    /// Earlier builds kept "<id>.mp4" in the hidden folder: move it next to the others under a readable name.
    private static func migrated(_ item: OfflineEpisode) -> OfflineEpisode {
        let old = folder.appending(path: item.fileName)
        guard videoFolder != folder, FileManager.default.fileExists(atPath: old.path) else { return item }
        let path = videoPath(episode: item.episode, series: item.series)
        guard (try? moveIntoVideoFolder(old, path: path)) != nil else { return item }
        return OfflineEpisode(episode: item.episode, series: item.series, fileName: path)
    }

    nonisolated private static func moveIntoVideoFolder(_ file: URL, path: String) throws {
        var dest = videoFolder.appending(path: path)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: file, to: dest)
        var values = URLResourceValues(); values.isExcludedFromBackup = true   // big and re-downloadable
        try? dest.setResourceValues(values)
    }

    public func localURL(for episodeId: Int) -> URL? {
        items.first { $0.episode.id == episodeId }.map { Self.videoFolder.appending(path: $0.fileName) }
    }

    public func isDownloaded(_ episodeId: Int) -> Bool { localURL(for: episodeId) != nil }

    /// Subtitles saved with the episode, pointing at the files in this container.
    public func localSubtitles(for episodeId: Int) -> [SubtitleInfo] {
        guard let data = try? Data(contentsOf: Self.folder.appending(path: "\(episodeId).subs.json")),
              let tracks = try? APIClient.decoder.decode([SubtitleInfo].self, from: data) else { return [] }
        return tracks.compactMap { t in
            let file = Self.folder.appending(path: "\(episodeId).s\(t.index).vtt")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            var local = t; local.url = file
            let ass = Self.folder.appending(path: "\(episodeId).s\(t.index).ass")
            local.assUrl = FileManager.default.fileExists(atPath: ass.path) ? ass : nil
            return local
        }
    }

    /// Small files: fetched right away with the normal session, next to the video.
    private func saveSubtitles(_ tracks: [SubtitleInfo], episodeId: Int) async {
        var saved: [SubtitleInfo] = []
        for t in tracks {
            guard let (data, res) = try? await URLSession.shared.data(from: t.url),
                  (res as? HTTPURLResponse)?.statusCode == 200 else { continue }
            try? data.write(to: Self.folder.appending(path: "\(episodeId).s\(t.index).vtt"), options: .atomic)
            // The original ASS with its fonts, for the libass renderer (offline too).
            if let assUrl = t.assUrl {
                var comps = URLComponents(url: assUrl, resolvingAgainstBaseURL: false)
                let items = comps?.queryItems ?? []
                comps?.queryItems = items + [URLQueryItem(name: "embed", value: "1")]
                if let target = comps?.url, let (ass, r) = try? await URLSession.shared.data(from: target), (r as? HTTPURLResponse)?.statusCode == 200 {
                    try? ass.write(to: Self.folder.appending(path: "\(episodeId).s\(t.index).ass"), options: .atomic)
                }
            }
            saved.append(t)
        }
        if let json = try? APIClient.encoder.encode(saved) {
            try? json.write(to: Self.folder.appending(path: "\(episodeId).subs.json"), options: .atomic)
        }
    }

    public func download(_ episode: EpisodeDTO, of series: SeriesDTO, api: APIClient) async {
        guard !isDownloaded(episode.id), inFlight[episode.id] == nil else { return }
        do {
            let info = try await api.stream(episodeId: episode.id)
            await saveSubtitles(info.subtitles ?? [], episodeId: episode.id)
            pending[episode.id] = (episode, series)
            inFlight[episode.id] = 0
            let task = session.downloadTask(with: info.downloadUrl)
            task.taskDescription = try String(data: APIClient.encoder.encode(PendingMeta(episode: episode, series: series)), encoding: .utf8)
            task.resume()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func cancel(_ episodeId: Int) {
        session.getAllTasks { tasks in
            for t in tasks where (t.taskDescription.flatMap(PendingMeta.decode)?.episode.id) == episodeId { t.cancel() }
        }
        inFlight[episodeId] = nil
    }

    public func delete(_ episodeId: Int) {
        guard let item = items.first(where: { $0.episode.id == episodeId }) else { return }
        let file = Self.videoFolder.appending(path: item.fileName)
        try? FileManager.default.removeItem(at: file)
        // Remove the series folder once its last episode is gone.
        let dir = file.deletingLastPathComponent()
        if dir != Self.videoFolder, (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: dir)
        }
        for t in localSubtitles(for: episodeId) { try? FileManager.default.removeItem(at: t.url) }
        try? FileManager.default.removeItem(at: Self.folder.appending(path: "\(episodeId).subs.json"))
        items.removeAll { $0.episode.id == episodeId }
        save()
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.episode.sizeBytes } }

    private func save() {
        if let data = try? APIClient.encoder.encode(items) { try? data.write(to: Self.indexURL, options: .atomic) }
    }

    fileprivate struct PendingMeta: Codable {
        let episode: EpisodeDTO
        let series: SeriesDTO
        static func decode(_ s: String) -> PendingMeta? { try? APIClient.decoder.decode(PendingMeta.self, from: Data(s.utf8)) }
    }
}

extension OfflineDownloads: URLSessionDownloadDelegate {
    public nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Must move the file before returning.
        guard let meta = downloadTask.taskDescription.flatMap(PendingMeta.decode) else { return }
        // An error page (expired link, file missing on the NAS) must not be saved as the video.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            MainActor.assumeIsolated {
                inFlight[meta.episode.id] = nil
                lastError = "Il NAS ha risposto con l'errore \(http.statusCode). Riprova più tardi."
            }
            return
        }
        let name = Self.videoPath(episode: meta.episode, series: meta.series)
        do {
            try Self.moveIntoVideoFolder(location, path: name)
        } catch {
            let message = error.localizedDescription
            MainActor.assumeIsolated { inFlight[meta.episode.id] = nil; lastError = message }
            return
        }
        MainActor.assumeIsolated {
            items.removeAll { $0.episode.id == meta.episode.id }
            items.append(OfflineEpisode(episode: meta.episode, series: meta.series, fileName: name))
            inFlight[meta.episode.id] = nil
            lastError = nil
            save()
        }
    }

    public nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                       totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0, let meta = downloadTask.taskDescription.flatMap(PendingMeta.decode) else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        MainActor.assumeIsolated { inFlight[meta.episode.id] = p }
    }

    public nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let meta = task.taskDescription.flatMap(PendingMeta.decode) else { return }
        MainActor.assumeIsolated {
            inFlight[meta.episode.id] = nil
            if (error as NSError).code != NSURLErrorCancelled { lastError = error.localizedDescription }
        }
    }

    public nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            backgroundCompletionHandler?()
            backgroundCompletionHandler = nil
        }
    }
}
