import AVFoundation
import Foundation
import Observation

/// What to play: a NAS episode (with progress + AniList sync) or a direct source stream.
public enum PlaybackItem: Hashable, Identifiable, Sendable {
    case episode(EpisodeDTO, series: SeriesDTO, playlist: [EpisodeDTO])
    case direct(URL, title: String)

    public var id: String {
        switch self {
        case .episode(let e, _, _): "ep-\(e.id)"
        case .direct(let u, _): u.absoluteString
        }
    }
}

/// Owns the AVPlayer, resumes from the saved position, reports progress to the NAS
/// every 15 seconds (the server marks the episode watched at 85% and updates AniList),
/// and offers "next episode" like Netflix.
@MainActor
@Observable
public final class PlayerModel {
    public let player = AVPlayer()
    public private(set) var title = ""
    public private(set) var subtitle = ""
    public private(set) var currentEpisode: EpisodeDTO?
    public private(set) var nextEpisode: EpisodeDTO?
    public private(set) var showNextUp = false
    public var error: String?

    @ObservationIgnored private var api: APIClient
    @ObservationIgnored private var series: SeriesDTO?
    public private(set) var playlistEpisodes: [EpisodeDTO] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var lastReport = Date.distantPast

    public init(api: APIClient) { self.api = api }

    public func load(_ item: PlaybackItem) async {
        switch item {
        case .direct(let url, let t):
            title = t; subtitle = ""
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.play()
        case .episode(let ep, let s, let list):
            series = s; playlistEpisodes = list
            await play(ep)
        }
        observe()
    }

    public func play(_ ep: EpisodeDTO) async {
        currentEpisode = ep
        showNextUp = false
        title = series?.title ?? ""
        subtitle = "Episodio \(ep.numberLabel)" + (ep.title.map { $0.hasPrefix("Episodio") ? "" : " · \($0)" } ?? "")
        nextEpisode = playlistEpisodes.first { $0.number > ep.number }

        var resume = ep.completed ? nil : ep.positionSeconds
        let url: URL
        if let local = OfflineDownloads.shared.localURL(for: ep.id) {
            url = local
        } else {
            do {
                let info = try await api.stream(episodeId: ep.id)
                url = info.url
                resume = info.resumeAt ?? resume
            } catch { self.error = error.localizedDescription; return }
        }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 30
        player.replaceCurrentItem(with: item)
        if let resume, resume > 5 { await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) }
        player.play()
    }

    public func playNext() async {
        guard let next = nextEpisode else { return }
        await report(force: true)
        await play(next)
    }

    public func skip(seconds: Double) {
        let t = player.currentTime().seconds + seconds
        player.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600))
    }

    public func stop() async {
        await report(force: true)
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    private func observe() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let item = player.currentItem, item.duration.isNumeric else { return }
        let pos = player.currentTime().seconds, dur = item.duration.seconds
        // "Prossimo episodio" in the last 90 seconds (ending credits)
        showNextUp = nextEpisode != nil && dur - pos < 90 && dur > 300
        if Date().timeIntervalSince(lastReport) > 15 { Task { await report(force: false) } }
    }

    private func report(force: Bool) async {
        guard let ep = currentEpisode, let item = player.currentItem, item.duration.isNumeric else { return }
        lastReport = Date()
        let pos = player.currentTime().seconds
        guard force || player.rate > 0, pos > 1 else { return }
        _ = try? await api.saveProgress(episodeId: ep.id, position: pos, duration: item.duration.seconds)
    }
}
