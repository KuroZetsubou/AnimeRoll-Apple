import AnimeRollKit
import SwiftUI

struct TVTitleView: View {
    let ref: TitleRef
    @Environment(AppSession.self) private var session
    @Environment(OfflineDownloads.self) private var offline
    @State private var media: AniListMedia?
    @State private var series: SeriesDTO?
    @State private var episodes: [EpisodeDTO] = []
    @State private var entry: AniListEntry?
    @State private var playing: PlaybackItem?
    @State private var showSources = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                HStack(alignment: .top, spacing: 60) {
                    AsyncImage(url: (media?.coverUrl).flatMap(URL.init(string:)) ?? ref.posterURL) { $0.resizable().aspectRatio(contentMode: .fill) }
                        placeholder: { Color.white.opacity(0.08) }
                        .frame(width: 340, height: 510).clipShape(.rect(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 20) {
                        Text(media?.title ?? ref.title).font(.system(size: 56, weight: .bold)).lineLimit(2)
                        Text(meta).font(.headline).foregroundStyle(.secondary)
                        if let e = entry {
                            Text("AniList: \(e.progress)/\(media?.episodes.map(String.init) ?? "?") episodi visti")
                                .font(.headline).foregroundStyle(TVTheme.accent)
                        }
                        Text(media?.plainDescription ?? series?.description ?? "").font(.callout).lineLimit(5)
                        HStack(spacing: 30) {
                            if let next = nextEpisode {
                                Button { play(next) } label: { Label("Riproduci E\(next.numberLabel)", systemImage: "play.fill") }
                            }
                            Button { showSources = true } label: { Label("Scarica sul NAS", systemImage: "externaldrive.badge.plus") }
                        }
                    }
                }
                .padding(.horizontal, 80)
                .focusSection()

                if !episodes.isEmpty {
                    Text("Episodi").font(.title3.bold()).padding(.horizontal, 80)
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 40) {
                            ForEach(episodes) { ep in
                                Button { play(ep) } label: {
                                    TVPoster(title: "E\(ep.numberLabel) · \(ep.title ?? "")",
                                             url: (series?.bannerUrl ?? series?.posterUrl).flatMap(URL.init(string:)),
                                             badge: ep.completed || Double(entry?.progress ?? 0) >= ep.number ? "Visto"
                                                : offline.isDownloaded(ep.id) ? "Offline" : nil,
                                             progress: ep.progressFraction, wide: true)
                                }
                                .buttonStyle(.borderless)
                                .contextMenu {
                                    if let series, !offline.isDownloaded(ep.id) {
                                        Button("Scarica su Apple TV") { Task { await offline.download(ep, of: series, api: session.api) } }
                                    }
                                    if offline.isDownloaded(ep.id) {
                                        Button("Rimuovi da Apple TV", role: .destructive) { offline.delete(ep.id) }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 80).padding(.vertical, 40)
                    }
                    .scrollClipDisabled()
                }
            }
            .padding(.vertical, 60)
        }
        .background {
            AsyncImage(url: (media?.bannerUrl).flatMap(URL.init(string:)) ?? ref.bannerURL) { $0.resizable().aspectRatio(contentMode: .fill) }
                placeholder: { Color.black }
                .overlay(.black.opacity(0.75)).blur(radius: 30).ignoresSafeArea()
        }
        .fullScreenCover(item: $playing, onDismiss: { Task { await load() } }) { TVPlayerView(item: $0) }
        .sheet(isPresented: $showSources) { TVSourcesView(title: media?.title ?? ref.title, aniListId: ref.aniListId) }
        .task { await load() }
    }

    private var meta: String {
        [media?.year.map(String.init), media?.format, media?.episodes.map { "\($0) episodi" }, media?.averageScore.map { "★ \($0)%" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var nextToWatchFromAniList: Double { Double(entry?.progress ?? 0) }
    private var nextEpisode: EpisodeDTO? {
        episodes.first { !$0.completed && $0.number > nextToWatchFromAniList } ?? episodes.first
    }

    private func load() async {
        if case .series(let s) = ref { series = s }
        if case .aniList(let m) = ref { media = m }
        if let id = ref.aniListId {
            media = (try? await session.api.aniListMedia(id)) ?? media
            entry = (try? await session.api.aniListEntry(id)) ?? nil
            series = (try? await session.api.series(aniListId: id)) ?? series
        }
        if let series { episodes = (try? await session.api.episodes(seriesId: series.id)) ?? [] }
    }

    private func play(_ ep: EpisodeDTO) {
        guard let series else { return }
        playing = .episode(ep, series: series, playlist: episodes)
    }
}

/// Simplified remote-friendly source picker: pick a source result and send
/// every episode (or the torrent/Telegram file) to the NAS.
struct TVSourcesView: View {
    let title: String
    let aniListId: Int?
    @Environment(AppSession.self) private var session
    @State private var providers: [ProviderInfo] = []
    @State private var results: [String: [SourceSearchResult]] = [:]
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                if let message { Text(message).foregroundStyle(.green) }
                ForEach(providers.filter { $0.enabled && $0.canSearch }) { p in
                    Section(p.name) {
                        ForEach(results[p.id] ?? []) { r in
                            Button { Task { await send(p, r) } } label: {
                                VStack(alignment: .leading) {
                                    Text(r.title)
                                    if let s = r.subtitle { Text(s).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scarica “\(title)” sul NAS")
        }
        .task {
            providers = (try? await session.api.providers()) ?? []
            for p in providers where p.enabled && p.canSearch {
                results[p.id] = (try? await session.api.search(source: p.id, query: title)).map { Array($0.prefix(12)) }
            }
        }
    }

    private func send(_ p: ProviderInfo, _ r: SourceSearchResult) async {
        do {
            var items = [DownloadItem(sourceRef: r.ref, episodeNumber: nil)]
            var alId = aniListId
            if p.canListEpisodes {
                let eps = try await session.api.sourceEpisodes(source: p.id, ref: r.ref)
                items = eps.map { DownloadItem(sourceRef: $0.ref, episodeNumber: $0.number) }
                alId = alId ?? eps.first?.extra?["anilistId"].flatMap(Int.init)
            }
            try await session.api.requestNASDownload(DownloadRequest(source: p.id, seriesTitle: title, aniListId: alId, items: items))
            message = "Inviati \(items.count) download al NAS da \(p.name)"
        } catch { message = error.localizedDescription }
    }
}
