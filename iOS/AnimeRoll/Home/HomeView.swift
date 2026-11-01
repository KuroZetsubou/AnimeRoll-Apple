import AnimeRollKit
import CoreMotion
import SwiftUI

@MainActor
@Observable
final class HomeModel {
    var home: HomeDTO?
    var library: [SeriesDTO] = []
    var planning: [AniListEntry] = []
    var error: String?

    func load(_ api: APIClient) async {
        do {
            async let h = api.home()
            async let l = try? api.library()
            home = try await h
            library = await l ?? library
            planning = (try? await api.aniListList("PLANNING")) ?? planning
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// Every genre we have something for, NAS genres first.
    var genres: [String] {
        var seen = Set<String>(), out: [String] = []
        let all = library.flatMap(\.genreList) + (home?.trending ?? []).flatMap(\.genres) + (home?.seasonal ?? []).flatMap(\.genres)
        for g in all where seen.insert(g).inserted { out.append(g) }
        return out
    }

    /// Up to three genres with at least 2 NAS series, most common first.
    var nasGenreShelves: [(genre: String, series: [SeriesDTO])] {
        let counts = Dictionary(grouping: library.flatMap { s in s.genreList.map { ($0, s) } }, by: \.0)
        return counts.map { (genre: $0.key, series: $0.value.map(\.1)) }
            .filter { $0.series.count >= 2 }
            .sorted { $0.series.count > $1.series.count }
            .prefix(3).map { $0 }
    }
}

enum HomeRoute: Hashable { case search }

/// Home: search pill, genre chips, featured carousel, shelves.
/// `compactHero` is used by the two-pane layout (unfolded iPhone Duo / iPad).
struct HomeView: View {
    var compactHero = false
    var onScrollDirection: ((Bool) -> Void)? = nil

    @Environment(AppSession.self) private var session
    @Environment(\.openTitle) private var openTitle
    @State private var model = HomeModel()
    @State private var playing: PlaybackItem?
    @State private var genre: String?
    @State private var path: [HomeRoute] = []

    private func inGenre(_ m: AniListMedia) -> Bool { genre == nil || m.genres.contains(genre!) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Button { path.append(.search) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                            Text("Cerca nella libreria e su AniList").font(DS.body(15))
                            Spacer()
                        }
                        .foregroundStyle(DS.textSecondary).padding(.horizontal, 16).frame(height: 48)
                        .glassCapsule()
                    }
                    .buttonStyle(.plain).padding(.horizontal)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Chip(title: "Tutti", selected: genre == nil) { withAnimation(DS.base) { genre = nil } }
                            ForEach(Array(model.genres.prefix(12)), id: \.self) { g in
                                Chip(title: g, selected: genre == g) { withAnimation(DS.base) { genre = g } }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.top, -14)

                    if let error = model.error { ErrorBanner(message: error) }
                    if let home = model.home { shelves(home) }
                    else if model.error == nil { ProgressView().frame(maxWidth: .infinity).padding(.top, 120) }
                }
                .padding(.top, 8).padding(.bottom, 120)
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { old, new in
                if new > 90, new - old > 4 { onScrollDirection?(true) }
                else if new - old < -4 || new <= 90 { onScrollDirection?(false) }
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.load(session.api) }
            .task { if model.home == nil { await model.load(session.api) } }
            .fullScreenCover(item: $playing) { PlayerScreen(item: $0) }
            .navigationDestination(for: HomeRoute.self) { _ in SearchView() }
        }
    }

    @ViewBuilder private func shelves(_ home: HomeDTO) -> some View {
        let watching = home.aniListWatching.filter { inGenre($0.media) }
        var seen = Set<Int>()
        let featured = (watching.map(\.media) + home.trending.filter(inGenre)).filter { seen.insert($0.id).inserted }.prefix(5)
        if !featured.isEmpty {
            HeroCarousel(items: Array(featured), compact: compactHero, session: session,
                         play: { await playHero($0) }, open: { openTitle(.aniList($0)) })
        }
        if genre == nil {
            Shelf(title: "Continua a guardare", items: home.continueWatching) { item in
                ContinueCard(item: item, play: { Haptics.tick(); playing = .episode(item.episode, series: item.series, playlist: []) },
                             info: { openTitle(.series(item.series)) })
            }
        }
        Shelf(title: "Stai guardando su AniList", items: watching) { entry in
            posterButton(.aniList(entry.media), meta: "\(entry.progress)/\(entry.media.episodes.map(String.init) ?? "?") episodi")
        }
        Shelf(title: "Pianificati da vedere", items: model.planning.filter { inGenre($0.media) }) { e in
            posterButton(.aniList(e.media), meta: ([e.media.episodes.map { "\($0) episodi" }, e.media.genres.first].compactMap { $0 }).joined(separator: " · "))
        }
        Shelf(title: "Sul tuo NAS", items: genre == nil ? home.recentlyAdded : home.recentlyAdded.filter { $0.genreList.contains(genre!) }) { s in
            posterButton(.series(s), badge: "\(s.episodeCount) ep", meta: s.year.map(String.init))
        }
        Shelf(title: "Questa stagione", items: home.seasonal.filter(inGenre)) { m in posterButton(.aniList(m), meta: m.genres.first) }
        Shelf(title: "Di tendenza", items: Array(home.trending.filter(inGenre).prefix(10).enumerated().map { RankedItem(rank: $0.offset + 1, media: $0.element) })) { item in
            Button { openTitle(.aniList(item.media)) } label: {
                RankedPoster(rank: item.rank, url: item.media.coverUrl.flatMap(URL.init(string:)))
            }
            .buttonStyle(.plain)
        }
    }

    private func posterButton(_ ref: TitleRef, badge: String? = nil, meta: String? = nil, width: CGFloat = 120) -> some View {
        Button { openTitle(ref) } label: { PosterCard(title: ref.title, url: ref.posterURL, badge: badge, meta: meta, width: width) }
            .buttonStyle(.plain)
    }

    /// Plays the next episode when the title is on the NAS, otherwise opens its page.
    private func playHero(_ media: AniListMedia) async {
        Haptics.tick()
        guard let series = try? await session.api.series(aniListId: media.id),
              let episodes = try? await session.api.episodes(seriesId: series.id), !episodes.isEmpty
        else { openTitle(.aniList(media)); return }
        let next = episodes.first { !$0.completed } ?? episodes[0]
        playing = .episode(next, series: series, playlist: episodes)
    }
}

private struct RankedItem: Hashable { let rank: Int; let media: AniListMedia }

// MARK: - Featured carousel

/// Featured card; advances every 4.5 s, tilt parallax kept.
struct HeroCarousel: View {
    let items: [AniListMedia]
    var compact = false
    let session: AppSession
    let play: (AniListMedia) async -> Void
    let open: (AniListMedia) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    @State private var motion = TiltMotion()
    private let timer = Timer.publish(every: 4.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let m = items[min(index, items.count - 1)]
        let tilt = reduceMotion ? CGSize.zero : motion.offset
        Color.clear
            .frame(height: compact ? 280 : 360)
            .overlay {
                RemoteImage(url: (m.bannerUrl ?? m.coverUrl).flatMap(URL.init(string:)))
                    .scaleEffect(1.08).offset(x: tilt.width * 0.7, y: tilt.height * 0.7)
            }
            .overlay(DS.scrimBottom)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    BadgeLabel(text: "In evidenza")
                    Text(m.title).font(DS.display(32, 800)).lineLimit(2).minimumScaleFactor(0.7).padding(.top, 6)
                    Text(([m.year.map(String.init), m.genres.prefix(3).joined(separator: " · "), m.episodes.map { "\($0) episodi" }]
                        .compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: " · "))
                        .font(DS.body(13)).foregroundStyle(DS.textSecondary).padding(.bottom, 10)
                    Button { open(m) } label: { Label("Scopri", systemImage: "info.circle") }
                        .buttonStyle(PrimaryButtonStyle(small: true))
                }
                .padding(16).offset(x: -tilt.width * 0.35, y: -tilt.height * 0.35)
            }
            .overlay(alignment: .bottomTrailing) {
                if items.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(items.indices, id: \.self) { i in
                            Capsule().fill(i == index ? DS.accent : .white.opacity(0.4)).frame(width: i == index ? 18 : 6, height: 6)
                        }
                    }
                    .padding(22)
                }
            }
            .id(m.id).transition(.opacity)
            .clipShape(.rect(cornerRadius: DS.rHero))
            .contentShape(.rect(cornerRadius: DS.rHero))
            .onTapGesture { open(m) }
            .padding(.horizontal, 16)
            .onReceive(timer) { _ in
                guard items.count > 1 else { return }
                withAnimation(DS.slow) { index = (index + 1) % items.count }
            }
            .onAppear { if !reduceMotion { motion.start() } }
            .onDisappear { motion.stop() }
    }
}

/// Device tilt → small offset (max ±8 pt) for the hero parallax.
@MainActor @Observable final class TiltMotion {
    private(set) var offset: CGSize = .zero
    @ObservationIgnored private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let g = data?.gravity else { return }
            let x = max(-8, min(8, g.x * 16))
            let y = max(-8, min(8, (g.y + 0.6) * 16))   // phone held at ~35°
            withAnimation(.easeOut(duration: 0.15)) { self.offset = CGSize(width: x, height: y) }
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}

// MARK: - Continue watching

struct ContinueCard: View {
    let item: ContinueWatching
    let play: () -> Void
    let info: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: play) {
                RemoteImage(url: (item.series.bannerUrl ?? item.series.posterUrl).flatMap(URL.init(string:)))
                    .frame(width: 220, height: 124)
                    .overlay { Image(systemName: "play.fill").font(.title3).foregroundStyle(.white).frame(width: 44, height: 44).background(.black.opacity(0.5), in: .circle) }
                    .overlay(alignment: .bottom) { ProgressLine(value: item.episode.progressFraction ?? 0) }
                    .clipShape(.rect(cornerRadius: DS.rPoster))
            }
            .buttonStyle(.plain)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.series.title).font(DS.body(13, 600)).lineLimit(1)
                    Text("Episodio \(item.episode.numberLabel)").font(DS.body(12)).foregroundStyle(DS.textTertiary)
                }
                Spacer()
                Button(action: info) { Image(systemName: "info.circle").foregroundStyle(DS.textSecondary) }.accessibilityLabel("Dettagli")
            }
            .padding(.top, 8)
        }
        .frame(width: 220)
    }
}

// MARK: - Categories overlay

struct CategoriesOverlay: View {
    let genres: [String]
    let selected: String?
    let pick: (String?) -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(.ultraThinMaterial).overlay(Color.black.opacity(0.55)).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    ForEach(genres, id: \.self) { g in
                        Button { Haptics.tick(); pick(g) } label: {
                            Text(g).font(g == selected ? .title2.bold() : .title3)
                                .foregroundStyle(g == selected ? .white : .white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80).padding(.bottom, 140)
            }
            Button { pick(nil) } label: {
                Image(systemName: "xmark").font(.title2.bold()).foregroundStyle(.black)
                    .frame(width: 60, height: 60).background(.white, in: .circle)
            }
            .accessibilityLabel("Chiudi")
            .padding(.bottom, 30)
        }
    }
}

// MARK: - Two panes

/// Two panes: catalog and the selected title (player inline at the top of the title pane).
/// - iPhone Duo half open like a book: left page catalog, right page title, split exactly on the crease.
/// - iPhone Duo in tabletop: title (with the player) on the upper half, catalog on the lower half.
/// - iPad / wide screens without a hinge: catalog on the left, title on the right.
/// Built by hand instead of NavigationSplitView, which collapses to one column
/// whenever the size class is compact, even on a wide screen.
struct DualPaneHome: View {
    @Environment(\.foldPosture) private var posture
    @State private var selected: TitleRef?

    /// Space kept free on each side of the crease so nothing sits on the fold.
    private let creaseGap: CGFloat = 14

    /// The crease runs through the middle of the physical screen.
    private var screen: CGRect {
        (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.bounds) ?? .zero
    }

    var body: some View {
        GeometryReader { geo in
            let fold = foldFrame(geo)
            switch posture {
            case .tabletop:
                VStack(spacing: 0) {
                    titlePane.frame(height: max(200, fold.minY))
                    crease(vertical: false).frame(height: max(1, fold.height))
                    catalog.frame(maxHeight: .infinity)
                }
            case .book:
                HStack(spacing: 0) {
                    catalog.frame(width: max(280, fold.minX))
                    crease(vertical: true).frame(width: max(1, fold.width))
                    titlePane.frame(maxWidth: .infinity)
                }
            default:
                HStack(spacing: 0) {
                    catalog.frame(width: max(320, geo.size.width * 0.42))
                    Divider()
                    titlePane.frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.background)
    }

    /// The folding region in this view's coordinates. iOS 27.1 reports it as a reserved
    /// "division" region while the device is partially folded; otherwise it is the middle
    /// of the physical screen, widened by `creaseGap` on each side.
    private func foldFrame(_ geo: GeometryProxy) -> CGRect {
        if #available(iOS 27.1, *),
           let region = geo.reservedRegions(kind: .division).first(where: \.isActive), !region.frame.isEmpty {
            return region.frame
        }
        let global = geo.frame(in: .global)
        if posture == .tabletop {
            let y = screen.height / 2 - global.minY
            return CGRect(x: 0, y: y - creaseGap, width: geo.size.width, height: creaseGap * 2)
        }
        let x = screen.width / 2 - global.minX
        return CGRect(x: x - creaseGap, y: 0, width: creaseGap * 2, height: geo.size.height)
    }

    private var catalog: some View {
        HomeView(compactHero: true).environment(\.openTitle, OpenTitleAction { selected = $0 })
    }

    @ViewBuilder private var titlePane: some View {
        NavigationStack {
            if let selected {
                TitleDetailView(ref: selected, inlinePlayer: true).id(selected)
                    .environment(\.openTitle, OpenTitleAction { self.selected = $0 })
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.split.2x1").font(.system(size: 36))
                    Text("Scegli un titolo").font(DS.display(20, 700)).foregroundStyle(.white)
                    Text("Il dettaglio e il player si aprono su questa metà.").font(DS.body(14))
                }
                .foregroundStyle(DS.textTertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Dark band over the fold.
    private func crease(vertical: Bool) -> some View {
        Rectangle().fill(Color.black).ignoresSafeArea()
            .overlay(Rectangle().fill(DS.hairline).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1))
    }
}
