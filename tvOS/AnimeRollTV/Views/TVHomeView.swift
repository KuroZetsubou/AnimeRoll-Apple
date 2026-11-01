import AnimeRollKit
import AVKit
import SwiftUI

struct TVHomeView: View {
    @Environment(AppSession.self) private var session
    @State private var home: HomeDTO?
    @State private var planning: [AniListEntry] = []
    @State private var library: [SeriesDTO] = []
    @State private var error: String?
    @State private var playing: PlaybackItem?
    @State private var genre: String?

    private func inGenre(_ m: AniListMedia) -> Bool { genre == nil || m.genres.contains(genre!) }

    private var genres: [String] {
        var count: [String: Int] = [:]
        for g in ((home?.trending ?? []) + (home?.seasonal ?? []) + (home?.aniListWatching.map(\.media) ?? [])).flatMap(\.genres) { count[g, default: 0] += 1 }
        return count.sorted { $0.value > $1.value }.prefix(10).map(\.key)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let error { Text(error).font(DS.body(24)).foregroundStyle(DS.pink).padding(.horizontal, 80) }
                if let home {
                    let watching = home.aniListWatching.filter { inGenre($0.media) }
                    var seen = Set<Int>()
                    let featured = (watching.map(\.media) + home.trending.filter(inGenre)).filter { seen.insert($0.id).inserted }.prefix(5)

                    if !featured.isEmpty { TVHero(items: Array(featured), play: playMedia) }

                    ScrollView(.horizontal) {
                        HStack(spacing: 16) {
                            TVChip(title: "Tutti", selected: genre == nil) { genre = nil }
                            ForEach(genres, id: \.self) { g in TVChip(title: g, selected: genre == g) { genre = g } }
                        }
                        .padding(.horizontal, 80).padding(.vertical, 8)
                    }
                    .scrollClipDisabled()

                    if genre == nil {
                        TVShelf(title: "Continua a guardare", items: home.continueWatching) { item in
                            Button { play(item) } label: {
                                TVPoster(title: item.series.title, url: (item.series.bannerUrl ?? item.series.posterUrl).flatMap(URL.init(string:)),
                                         meta: "Episodio \(item.episode.numberLabel)", progress: item.episode.progressFraction, wide: true)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    TVShelf(title: "Stai guardando su AniList", items: watching) { e in
                        NavigationLink(value: TitleRef.aniList(e.media)) {
                            TVPoster(title: e.media.title, url: e.media.coverUrl.flatMap(URL.init(string:)),
                                     meta: "\(e.progress)/\(e.media.episodes.map(String.init) ?? "?") episodi")
                        }
                        .buttonStyle(.borderless)
                    }
                    TVShelf(title: "Pianificati da vedere", items: planning.filter { inGenre($0.media) }) { e in
                        NavigationLink(value: TitleRef.aniList(e.media)) {
                            TVPoster(title: e.media.title, url: e.media.coverUrl.flatMap(URL.init(string:)),
                                     meta: [e.media.episodes.map { "\($0) episodi" }, e.media.genres.first].compactMap { $0 }.joined(separator: " · "))
                        }
                        .buttonStyle(.borderless)
                    }
                    TVShelf(title: "Sul tuo NAS", items: genre == nil ? home.recentlyAdded : home.recentlyAdded.filter { $0.genreList.contains(genre!) }) { s in
                        NavigationLink(value: TitleRef.series(s)) {
                            TVPoster(title: s.title, url: s.posterUrl.flatMap(URL.init(string:)), badge: "\(s.episodeCount) ep", meta: s.year.map(String.init))
                        }
                        .buttonStyle(.borderless)
                    }
                    TVShelf(title: "Questa stagione", items: home.seasonal.filter(inGenre)) { m in
                        NavigationLink(value: TitleRef.aniList(m)) {
                            TVPoster(title: m.title, url: m.coverUrl.flatMap(URL.init(string:)), meta: m.genres.first)
                        }
                        .buttonStyle(.borderless)
                    }
                    TVShelf(title: "Di tendenza", items: Array(home.trending.filter(inGenre).prefix(10).enumerated().map { TVRankedItem(rank: $0.offset + 1, media: $0.element) })) { item in
                        NavigationLink(value: TitleRef.aniList(item.media)) {
                            TVRankedPoster(rank: item.rank, title: item.media.title, url: item.media.coverUrl.flatMap(URL.init(string:)))
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 300)
                }
            }
            .padding(.bottom, 60)
        }
        .background(DS.background)
        .ignoresSafeArea(edges: [.top, .horizontal])
        .navigationDestination(for: TitleRef.self) { TVTitleView(ref: $0) }
        .fullScreenCover(item: $playing) { TVPlayerView(item: $0) }
        .task {
            do { home = try await session.api.home() } catch { self.error = error.localizedDescription }
            planning = (try? await session.api.aniListList("PLANNING")) ?? []
            library = (try? await session.api.library()) ?? []
        }
    }

    private func play(_ item: ContinueWatching) {
        playing = .episode(item.episode, series: item.series, playlist: [])   // list loads in the player
    }

    /// Hero "Guarda": next episode when the title is on the NAS, otherwise its page opens (Scopri).
    private func playMedia(_ m: AniListMedia) async -> Bool {
        guard let series = try? await session.api.series(aniListId: m.id),
              let episodes = try? await session.api.episodes(seriesId: series.id), !episodes.isEmpty else { return false }
        playing = .episode(episodes.first { !$0.completed } ?? episodes[0], series: series, playlist: episodes)
        return true
    }
}

private struct TVRankedItem: Hashable { let rank: Int; let media: AniListMedia }

/// Featured title, changes every 6 s; the dots show where you are. Left / right on the remote moves between titles.
private struct TVHero: View {
    let items: [AniListMedia]
    let play: (AniListMedia) async -> Bool
    @State private var index = 0
    @State private var lastChange = Date.now
    private let timer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    var body: some View {
        let m = items[min(index, items.count - 1)]
        Color.clear.frame(maxWidth: .infinity).frame(height: 720)
            .overlay {
                AsyncImage(url: (m.bannerUrl ?? m.coverUrl).flatMap(URL.init(string:))) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { DS.surface }
            }
            .overlay(DS.scrimBottom)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 14) {
                    TVBadge(text: "In evidenza")
                    Text(m.title).font(DS.display(80, 800)).lineLimit(2)
                    Text(([m.year.map(String.init), m.genres.prefix(3).joined(separator: " · "), m.episodes.map { "\($0) episodi" }]
                        .compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: " · "))
                        .font(DS.body(28)).foregroundStyle(DS.textSecondary)
                    Text(m.plainDescription).font(DS.body(26)).foregroundStyle(DS.textSecondary).lineLimit(2).frame(maxWidth: 1100, alignment: .leading)
                    HStack(spacing: 24) {
                        NavigationLink(value: TitleRef.aniList(m)) { Label("Scopri", systemImage: "info.circle") }
                        Button { Task { _ = await play(m) } } label: { Label("Guarda", systemImage: "play.fill") }
                    }
                    .padding(.top, 8)
                    HStack(spacing: 8) {
                        ForEach(items.indices, id: \.self) { i in
                            Capsule().fill(i == index ? DS.accent : .white.opacity(0.4)).frame(width: i == index ? 36 : 12, height: 12)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(80)
            }
            .id(m.id).transition(.opacity)
            .clipped()
            .focusSection()
            .onReceive(timer) { now in
                guard items.count > 1, now.timeIntervalSince(lastChange) >= 5.5 else { return }
                withAnimation(DS.slow) { index = (index + 1) % items.count }
                lastChange = now
            }
            .onMoveCommand { dir in
                guard items.count > 1 else { return }
                if dir == .right { withAnimation(DS.slow) { index = (index + 1) % items.count }; lastChange = .now }
                if dir == .left { withAnimation(DS.slow) { index = (index + items.count - 1) % items.count }; lastChange = .now }
            }
    }
}
