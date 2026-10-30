import AnimeRollKit
import SwiftUI

@MainActor
@Observable
final class HomeModel {
    var home: HomeDTO?
    var error: String?
    func load(_ api: APIClient) async {
        do { home = try await api.home(); error = nil } catch { self.error = error.localizedDescription }
    }
}

/// Netflix-like home: hero banner + shelves.
/// `select` is set by the two-pane layout (unfolded iPhone Duo / iPad) to show
/// the title next to the list instead of pushing a new screen.
struct HomeView: View {
    var select: ((TitleRef) -> Void)? = nil
    var compactHero = false
    @Environment(AppSession.self) private var session
    @State private var model = HomeModel()
    @State private var playing: PlaybackItem?
    @State private var pushed: TitleRef?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let error = model.error { ErrorBanner(message: error) }
                if let home = model.home {
                    if let hero = home.aniListWatching.first?.media ?? home.trending.first {
                        HeroBanner(media: hero, height: compactHero ? 240 : 420) { open(.aniList(hero)) }
                    }

                    Shelf(title: "Continua a guardare", items: home.continueWatching) { item in
                        ContinueCard(item: item) {
                            Task { await playContinue(item) }
                        }
                    }

                    Shelf(title: "Stai guardando su AniList", items: home.aniListWatching) { entry in
                        titleButton(.aniList(entry.media)) {
                            PosterCard(title: entry.media.title, url: entry.media.coverUrl.flatMap(URL.init(string:)),
                                       badge: "\(entry.progress)/\(entry.media.episodes.map(String.init) ?? "?")")
                        }
                    }

                    Shelf(title: "Sul tuo NAS", items: home.recentlyAdded) { s in
                        titleButton(.series(s)) {
                            PosterCard(title: s.title, url: s.posterUrl.flatMap(URL.init(string:)), badge: "\(s.episodeCount) ep")
                        }
                    }

                    Shelf(title: "Questa stagione", items: home.seasonal) { m in
                        titleButton(.aniList(m)) { PosterCard(title: m.title, url: m.coverUrl.flatMap(URL.init(string:))) }
                    }

                    Shelf(title: "Di tendenza", items: home.trending) { m in
                        titleButton(.aniList(m)) { PosterCard(title: m.title, url: m.coverUrl.flatMap(URL.init(string:))) }
                    }
                } else if model.error == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
                }
            }
            .padding(.bottom, 32)
        }
        .background(Theme.background)
        .ignoresSafeArea(edges: select == nil ? .top : [])
        .navigationDestination(for: TitleRef.self) { TitleDetailView(ref: $0) }
        .navigationDestination(item: $pushed) { TitleDetailView(ref: $0) }
        .refreshable { await model.load(session.api) }
        .task { if model.home == nil { await model.load(session.api) } }
        .fullScreenCover(item: $playing) { PlayerScreen(item: $0) }
        .toolbar(select == nil ? .hidden : .automatic, for: .navigationBar)
    }

    @ViewBuilder
    private func titleButton(_ ref: TitleRef, @ViewBuilder label: () -> some View) -> some View {
        if let select {
            Button { select(ref) } label: { label() }.buttonStyle(.plain)
        } else {
            NavigationLink(value: ref) { label() }.buttonStyle(.plain)
        }
    }

    private func open(_ ref: TitleRef) {
        if let select { select(ref) } else { pushed = ref }
    }

    private func playContinue(_ item: ContinueWatching) async {
        let list = (try? await session.api.episodes(seriesId: item.series.id)) ?? [item.episode]
        playing = .episode(item.episode, series: item.series, playlist: list)
    }
}

struct HeroBanner: View {
    let media: AniListMedia
    var height: CGFloat = 420
    let action: () -> Void

    var body: some View {
        // Fixed-size frame first, image as overlay: a .fill image can't widen the layout.
        Color.clear
            .frame(maxWidth: .infinity).frame(height: height)
            .overlay { RemoteImage(url: (media.bannerUrl ?? media.coverUrl).flatMap(URL.init(string:))) }
            .overlay(LinearGradient(colors: [.clear, .clear, Theme.background], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(media.title).font(.largeTitle.bold()).lineLimit(2).minimumScaleFactor(0.7)
                    Text(media.genres.prefix(3).joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                    Button(action: action) {
                        Label("Scopri", systemImage: "info.circle").padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                }
                .padding()
            }
            .clipped()
    }
}

struct ContinueCard: View {
    let item: ContinueWatching
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                RemoteImage(url: (item.series.bannerUrl ?? item.series.posterUrl).flatMap(URL.init(string:)))
                    .frame(width: 220, height: 124)
                    .overlay { Image(systemName: "play.circle.fill").font(.system(size: 40)).foregroundStyle(.white.opacity(0.9)) }
                    .overlay(alignment: .bottom) { ProgressLine(value: item.episode.progressFraction ?? 0) }
                    .clipShape(.rect(cornerRadius: 8))
                Text(item.series.title).font(.caption.bold()).lineLimit(1)
                Text("Episodio \(item.episode.numberLabel)").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 220, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

/// Unfolded iPhone Duo / iPad / landscape: browse on the left, the selected title on the right
/// (with the player inline at the top of the right pane, Netflix-on-foldable style).
/// Built by hand instead of NavigationSplitView, which collapses to one column
/// whenever the size class is compact, even on a wide screen.
struct DualPaneHome: View {
    @Environment(\.foldPosture) private var posture
    @State private var selected: TitleRef?

    /// On an open iPhone Duo held upright the crease is in the middle:
    /// split exactly there so nothing sits on the fold.
    private func listWidth(_ size: CGSize) -> CGFloat {
        let creaseIsVertical = (posture == .flat || posture == .book) && size.height >= size.width
        return creaseIsVertical && size.width >= 640 ? size.width / 2 : max(320, size.width * 0.42)
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                NavigationStack { HomeView(select: { selected = $0 }, compactHero: true) }
                    .frame(width: listWidth(geo.size))
                Divider()
                NavigationStack {
                    if let selected {
                        TitleDetailView(ref: selected, inlinePlayer: true).id(selected)
                    } else {
                        ContentUnavailableView("Scegli un titolo", systemImage: "rectangle.split.2x1",
                                               description: Text("Il dettaglio e il player si aprono qui accanto."))
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.background)
    }
}
