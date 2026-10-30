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

    override private init() {
        super.init()
        if let data = try? Data(contentsOf: Self.indexURL),
           let saved = try? APIClient.decoder.decode([OfflineEpisode].self, from: data) {
            items = saved.filter { FileManager.default.fileExists(atPath: Self.folder.appending(path: $0.fileName).path) }
        }
        _ = session // reconnect to background tasks
    }

    public func localURL(for episodeId: Int) -> URL? {
        items.first { $0.episode.id == episodeId }.map { Self.folder.appending(path: $0.fileName) }
    }

    public func isDownloaded(_ episodeId: Int) -> Bool { localURL(for: episodeId) != nil }

    public func download(_ episode: EpisodeDTO, of series: SeriesDTO, api: APIClient) async {
        guard !isDownloaded(episode.id), inFlight[episode.id] == nil else { return }
        do {
            let info = try await api.stream(episodeId: episode.id)
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
        try? FileManager.default.removeItem(at: Self.folder.appending(path: item.fileName))
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
        let name = "\(meta.episode.id).mp4"
        let dest = Self.folder.appending(path: name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var d = dest; try? d.setResourceValues(values)
        } catch { return }
        MainActor.assumeIsolated {
            items.removeAll { $0.episode.id == meta.episode.id }
            items.append(OfflineEpisode(episode: meta.episode, series: meta.series, fileName: name))
            inFlight[meta.episode.id] = nil
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
