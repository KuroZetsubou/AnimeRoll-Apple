import AVFoundation
import Foundation
import Observation
import os

/// What to play: a NAS episode (with progress + AniList sync) or a direct source stream.
/// An empty `playlist` means "load it in the background after playback starts".
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
///
/// Start-up path is kept short on purpose: no network call before the screen opens,
/// no awaited seek before play, and playback starts as soon as a few seconds are buffered.
@MainActor
@Observable
public final class PlayerModel {
    public let player: AVPlayer
    public private(set) var title = ""
    public private(set) var subtitle = ""
    public private(set) var currentEpisode: EpisodeDTO?
    public private(set) var nextEpisode: EpisodeDTO?
    public private(set) var showNextUp = false
    public private(set) var isLoading = true
    /// Natural size of the picture, used to place subtitles on the video and not on the black bars.
    public private(set) var videoSize: CGSize = .zero
    public private(set) var playlistEpisodes: [EpisodeDTO] = []
    public var error: String?
    /// Subtitles drawn by the app over the video (see SubtitleController).
    public let subtitles = SubtitleController()

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private var series: SeriesDTO?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var subtitleObserver: Any?
    @ObservationIgnored private var lastReport = Date()
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var reporting = false
    @ObservationIgnored private var kvo: [NSKeyValueObservation] = []
    @ObservationIgnored private var startedAt = ContinuousClock.now
    @ObservationIgnored private let log = Logger(subsystem: "com.kurozetsubou.animeroll", category: "player")

    /// Seconds buffered ahead that are enough to start without waiting for AVPlayer's own estimate.
    private static let quickStartBuffer = 3.0

    public init(api: APIClient) {
        self.api = api
        player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = true   // still protects against stalls while watching
    }

    /// Configure once at app launch, never on the way to playback: it blocks the main thread.
    public nonisolated static func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    public func load(_ item: PlaybackItem) async {
        observe()
        switch item {
        case .direct(let url, let t):
            title = t; subtitle = ""
            subtitles.setTracks([], seriesId: nil)
            startedAt = .now
            start(AVPlayerItem(url: url), resumeAt: nil)
        case .episode(let ep, let s, let list):
            series = s
            playlistEpisodes = list
            await play(ep)
            if list.count <= 1 { await loadPlaylist(seriesId: s.id) }
        }
    }

    public func play(_ ep: EpisodeDTO) async {
        startedAt = .now
        isLoading = true
        currentEpisode = ep
        setShowNextUp(false)
        title = series?.title ?? ""
        subtitle = "Episodio \(ep.numberLabel)" + (ep.title.map { $0.hasPrefix("Episodio") ? "" : " · \($0)" } ?? "")
        nextEpisode = playlistEpisodes.first { $0.number > ep.number }

        var resume = ep.completed ? nil : ep.positionSeconds
        let url: URL
        if let local = OfflineDownloads.shared.localURL(for: ep.id) {
            url = local
            subtitles.setTracks(OfflineDownloads.shared.localSubtitles(for: ep.id), seriesId: series?.id)
        } else {
            do {
                let info = try await api.stream(episodeId: ep.id)
                url = info.url
                resume = info.resumeAt ?? resume
                subtitles.setTracks(info.subtitles ?? [], seriesId: series?.id)
            } catch { self.error = error.localizedDescription; isLoading = false; return }
        }
        log.info("TIMING url ready +\(self.elapsed, privacy: .public)")
        start(AVPlayerItem(url: url), resumeAt: resume)
    }

    public func playNext() async {
        guard let next = nextEpisode else { return }
        await report(force: true)
        await play(next)
    }

    public func skip(seconds: Double) {
        let t = max(0, player.currentTime().seconds + seconds)
        // A little keyframe tolerance makes skips instant instead of decoding up to an exact frame.
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600), toleranceAfter: .zero)
    }

    public func togglePlayPause() {
        player.timeControlStatus == .paused ? player.play() : player.pause()
    }

    /// Safe to call more than once (close button and onDisappear both call it): only the first runs.
    public func stop() async {
        guard !stopped else { return }
        stopped = true
        player.pause()
        await report(force: true)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let subtitleObserver { player.removeTimeObserver(subtitleObserver) }
        timeObserver = nil
        subtitleObserver = nil
        kvo = []
    }

    // MARK: Start-up

    private func start(_ item: AVPlayerItem, resumeAt: Double?) {
        watch(item)
        player.replaceCurrentItem(with: item)
        if let resumeAt, resumeAt > 5 {
            // Queued until the item is ready; play() is NOT delayed waiting for it.
            player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600),
                        toleranceBefore: CMTime(seconds: 2, preferredTimescale: 600), toleranceAfter: .zero)
        }
        player.play()
    }

    private func watch(_ item: AVPlayerItem) {
        kvo = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self else { return }
                    switch item.status {
                    case .readyToPlay:
                        self.log.info("TIMING item ready +\(self.elapsed, privacy: .public)")
                        self.quickStartIfBuffered(item)
                        await Self.disableEmbeddedSubtitles(item)
                    case .failed:
                        self.error = item.error?.localizedDescription ?? "Impossibile riprodurre il video."
                        self.isLoading = false
                    default: break
                    }
                }
            },
            item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in
                    let size = item.presentationSize
                    if size != .zero, self?.videoSize != size { self?.videoSize = size }
                }
            },
            // Start as soon as a few seconds are buffered instead of waiting for AVPlayer's network estimate.
            item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in self?.quickStartIfBuffered(item) }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                Task { @MainActor in
                    guard let self, player.timeControlStatus == .playing, self.isLoading else { return }
                    self.isLoading = false
                    self.log.info("TIMING playing +\(self.elapsed, privacy: .public)")
                }
            },
        ]
    }

    /// Old episodes may still carry mov_text tracks: never show them on top of ours.
    private static func disableEmbeddedSubtitles(_ item: AVPlayerItem) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
        item.select(nil, in: group)
    }

    private func quickStartIfBuffered(_ item: AVPlayerItem) {
        guard item === player.currentItem, item.status == .readyToPlay,
              player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
        let now = item.currentTime()
        let ahead = item.loadedTimeRanges.map(\.timeRangeValue)
            .first { $0.containsTime(now) }
            .map { ($0.end - now).seconds } ?? 0
        if ahead >= Self.quickStartBuffer { player.playImmediately(atRate: 1) }
    }

    private func loadPlaylist(seriesId: Int) async {
        guard let list = try? await api.episodes(seriesId: seriesId), !list.isEmpty else { return }
        playlistEpisodes = list
        if let ep = currentEpisode { nextEpisode = list.first { $0.number > ep.number } }
    }

    // MARK: Progress

    private func observe() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // 50 ms keeps subtitles within a frame or two of the dialogue; only changes re-render.
        subtitleObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.subtitles.update(time: time.seconds) }
        }
    }

    private func tick() {
        guard let item = player.currentItem, item.duration.isNumeric else { return }
        let pos = player.currentTime().seconds, dur = item.duration.seconds
        // "Prossimo episodio" in the last 90 seconds (ending credits)
        setShowNextUp(nextEpisode != nil && dur - pos < 90 && dur > 300)
        if Date().timeIntervalSince(lastReport) > 15 { Task { await report(force: false) } }
    }

    /// Only touch observed state when it changes: every write re-renders the player screen.
    private func setShowNextUp(_ value: Bool) {
        if showNextUp != value { showNextUp = value }
    }

    /// One save in flight at a time; a periodic save that finds one running is skipped.
    private func report(force: Bool) async {
        guard let ep = currentEpisode, let item = player.currentItem, item.duration.isNumeric else { return }
        lastReport = Date()
        let pos = player.currentTime().seconds
        guard force || player.rate > 0, pos > 1 else { return }
        if reporting && !force { return }
        reporting = true
        defer { reporting = false }
        _ = try? await api.saveProgress(episodeId: ep.id, position: pos, duration: item.duration.seconds)
    }

    private var elapsed: String { (ContinuousClock.now - startedAt).formatted(.units(allowed: [.milliseconds])) }
}
