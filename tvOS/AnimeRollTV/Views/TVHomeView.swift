import AnimeRollKit
import AVKit
import SwiftUI

/// Big focusable poster for the Siri Remote.
struct TVPoster: View {
    let title: String
    let url: URL?
    var badge: String? = nil
    var progress: Double? = nil
    var wide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.white.opacity(0.08) }
                .frame(width: wide ? 480 : 260, height: wide ? 270 : 390)
                .clipped()
                .overlay(alignment: .topLeading) {
                    if let badge {
                        Text(badge).font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 4)
                            .background(TVTheme.accent, in: .capsule).padding(10)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress {
                        GeometryReader { g in
                            Rectangle().fill(TVTheme.accent).frame(width: g.size.width * progress, height: 6)
                        }
                        .frame(height: 6)
                    }
                }
            Text(title).font(.caption).lineLimit(1).frame(width: wide ? 480 : 260, alignment: .leading)
        }
    }
}

struct TVShelf<Item: Hashable, Content: View>: View {
    let title: String
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                Text(title).font(.title3.bold()).padding(.leading, 80)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 48) { ForEach(items, id: \.self) { content($0) } }
                        .padding(.horizontal, 80).padding(.vertical, 40)
                }
                .scrollClipDisabled()
            }
        }
    }
}

struct TVHomeView: View {
    @Environment(AppSession.self) private var session
    @State private var home: HomeDTO?
    @State private var error: String?
    @State private var playing: PlaybackItem?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                if let error { Text(error).foregroundStyle(.red).padding(.horizontal, 80) }
                if let home {
                    if let hero = home.aniListWatching.first?.media ?? home.trending.first {
                        TVHero(media: hero)
                    }
                    TVShelf(title: "Continua a guardare", items: home.continueWatching) { item in
                        Button { Task { await play(item) } } label: {
                            TVPoster(title: "\(item.series.title) · E\(item.episode.numberLabel)",
                                     url: (item.series.bannerUrl ?? item.series.posterUrl).flatMap(URL.init(string:)),
                                     progress: item.episode.progressFraction, wide: true)
                        }
                        .buttonStyle(.borderless)
                    }
                    TVShelf(title: "Stai guardando su AniList", items: home.aniListWatching) { e in
                        NavigationLink(value: TitleRef.aniList(e.media)) {
                            TVPoster(title: e.media.title, url: e.media.coverUrl.flatMap(URL.init(string:)),
                                     badge: "\(e.progress)/\(e.media.episodes.map(String.init) ?? "?")")
                        }
                        .buttonStyle(.borderless)
                    }
                    TVShelf(title: "Sul tuo NAS", items: home.recentlyAdded) { s in
                        NavigationLink(value: TitleRef.series(s)) {
                            TVPoster(title: s.title, url: s.posterUrl.flatMap(URL.init(string:)), badge: "\(s.episodeCount) ep")
                        }
                        .buttonStyle(.borderless)
                    }
                    TVShelf(title: "Questa stagione", items: home.seasonal) { m in
                        NavigationLink(value: TitleRef.aniList(m)) { TVPoster(title: m.title, url: m.coverUrl.flatMap(URL.init(string:))) }
                            .buttonStyle(.borderless)
                    }
                    TVShelf(title: "Di tendenza", items: home.trending) { m in
                        NavigationLink(value: TitleRef.aniList(m)) { TVPoster(title: m.title, url: m.coverUrl.flatMap(URL.init(string:))) }
                            .buttonStyle(.borderless)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 300)
                }
            }
        }
        .ignoresSafeArea(edges: [.top, .horizontal])
        .navigationDestination(for: TitleRef.self) { TVTitleView(ref: $0) }
        .fullScreenCover(item: $playing) { TVPlayerView(item: $0) }
        .task {
            do { home = try await session.api.home() } catch { self.error = error.localizedDescription }
        }
    }

    private func play(_ item: ContinueWatching) async {
        let list = (try? await session.api.episodes(seriesId: item.series.id)) ?? [item.episode]
        playing = .episode(item.episode, series: item.series, playlist: list)
    }
}

private struct TVHero: View {
    let media: AniListMedia
    var body: some View {
        Color.clear.frame(maxWidth: .infinity).frame(height: 640)
            .overlay {
                AsyncImage(url: (media.bannerUrl ?? media.coverUrl).flatMap(URL.init(string:))) { $0.resizable().aspectRatio(contentMode: .fill) }
                    placeholder: { Color.black }
            }
            .overlay(LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom))
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(media.title).font(.system(size: 64, weight: .bold)).lineLimit(2)
                    Text(media.plainDescription).font(.callout).lineLimit(3).frame(maxWidth: 1000, alignment: .leading)
                    NavigationLink(value: TitleRef.aniList(media)) { Label("Scopri", systemImage: "info.circle") }
                }
                .padding(80)
            }
            .clipped()
            .focusSection()
    }
}

/// Full-screen AVPlayerViewController (native tvOS transport bar, subtitles, audio tracks).
struct TVPlayerView: View {
    let item: PlaybackItem
    @Environment(AppSession.self) private var session
    @State private var model: PlayerModel?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let model {
                TVSystemPlayer(player: model.player, title: model.title, subtitle: model.subtitle).ignoresSafeArea()
                if model.showNextUp, let next = model.nextEpisode {
                    Button("Episodio \(next.numberLabel) ▸") { Task { await model.playNext() } }
                        .padding(80)
                }
            }
        }
        .task {
            let m = PlayerModel(api: session.api)
            model = m
            await m.load(item)
        }
        .onDisappear { Task { await model?.stop() } }
    }
}

struct TVSystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let title: String
    let subtitle: String

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        let t = AVMutableMetadataItem(); t.identifier = .commonIdentifierTitle; t.value = title as NSString
        let s = AVMutableMetadataItem(); s.identifier = .iTunesMetadataTrackSubTitle; s.value = subtitle as NSString
        player.currentItem?.externalMetadata = [t, s]
    }
}
