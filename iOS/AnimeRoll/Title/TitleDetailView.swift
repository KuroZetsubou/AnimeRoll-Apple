import AnimeRollKit
import SwiftUI

@MainActor
@Observable
final class TitleModel {
    let ref: TitleRef
    var media: AniListMedia?
    var series: SeriesDTO?
    var episodes: [EpisodeDTO] = []
    var entry: AniListEntry?
    var error: String?
    var loading = true

    init(ref: TitleRef) {
        self.ref = ref
        if case .series(let s) = ref { series = s }
        if case .aniList(let m) = ref { media = m }
    }

    func load(_ api: APIClient) async {
        defer { loading = false }
        do {
            if let alId = ref.aniListId {
                async let m = try? api.aniListMedia(alId)
                async let e = try? api.trackerEntry(alId)
                async let s = try? api.series(aniListId: alId)
                let (mm, ee, ss) = await (m, e, s)
                media = mm ?? media; entry = ee ?? nil; series = ss ?? series
            }
            if let series { episodes = try await api.episodes(seriesId: series.id) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// After deleting from the server: drop it locally; with no episodes left the series is gone too.
    func removed(episode id: Int) {
        episodes.removeAll { $0.id == id }
        if episodes.isEmpty { series = nil }
    }
    func removedSeries() { episodes = []; series = nil }

    var title: String { media?.title ?? series?.title ?? ref.title }
    var description: String {
        (media?.plainDescription ?? series?.description ?? "")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Similar": AniList's own recommendations, with the server version of a title when we have it.
    var similar: [TitleRef] = []
    var similarLoaded = false
    /// "Seasons and related": prequels, sequels, side stories (with the relation label).
    var related: [(relation: String, ref: TitleRef)] = []
    func loadSimilar(_ api: APIClient) async {
        guard !similarLoaded, let alId = ref.aniListId ?? media?.id else { similarLoaded = true; return }
        async let rec = try? api.aniListRecommendations(alId)
        async let lib = try? api.library()
        async let rel = try? api.aniListRelations(alId)
        let (r, l, rl) = await (rec, lib, rel)
        // Two server series can share one AniList id: keep the first instead of crashing.
        let onNAS = Dictionary((l ?? []).compactMap { s in s.aniListId.map { ($0, s) } }, uniquingKeysWith: { first, _ in first })
        var seen = Set<Int>()
        similar = (r ?? []).filter { $0.id != alId && seen.insert($0.id).inserted }.map { m in onNAS[m.id].map(TitleRef.series) ?? .aniList(m) }
        related = (rl ?? []).map { ($0.relation, onNAS[$0.media.id].map(TitleRef.series) ?? .aniList($0.media)) }
        similarLoaded = true
    }

    /// First not-completed episode, for the big "Play" button.
    var nextToWatch: EpisodeDTO? {
        let watchedOnAniList = Double(entry?.progress ?? 0)
        let regular = episodes.filter { !$0.extra }
        return regular.first { !$0.completed && $0.number > watchedOnAniList } ?? regular.first { !$0.completed } ?? episodes.first
    }
}

/// Title page from docs/UI-REWORK.md. Shown as a sheet over the app (TitleSheetHost) or in the
/// right pane of the two-pane layout (`inlinePlayer`: the player opens at the top of the pane).
struct TitleDetailView: View {
    let ref: TitleRef
    var inlinePlayer = false

    @Environment(AppSession.self) private var session
    @Environment(OfflineDownloads.self) private var offline
    @Environment(\.titleSheet) private var sheet
    @Environment(\.openTitle) private var openTitle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: TitleModel
    @State private var playing: PlaybackItem?
    @State private var inlineItem: PlaybackItem?
    @State private var fullScreenItem: PlaybackItem?
    @State private var showSources = false
    @State private var expanded = false
    @State private var section = 0
    @State private var zoomed = false
    @State private var showStatus = false
    @State private var showAll = false
    @State private var deleting: EpisodeDTO?
    @State private var deletingSeries = false
    @State private var deleteError: String?
    @State private var moving: [EpisodeDTO]?
    @State private var editing: EpisodeDTO?
    @State private var editingSeries = false

    init(ref: TitleRef, inlinePlayer: Bool = false) {
        self.ref = ref
        self.inlinePlayer = inlinePlayer
        _model = State(initialValue: TitleModel(ref: ref))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                VStack(alignment: .leading, spacing: 14) {
                    titleBlock
                    aniListRow
                    mainButtons
                    if let error = model.error { ErrorBanner(message: error).padding(.horizontal, -16) }
                    descriptionBlock
                }
                .padding(.horizontal)
                .padding(.top, inlineItem == nil ? -64 : 0)
                sectionPicker
                if section == 0 { episodesSection } else { similarSection }
            }
            .padding(.bottom, 40)
        }
        .onScrollGeometryChange(for: Bool.self, of: { $0.contentOffset.y + $0.contentInsets.top <= 1 }) { _, top in
            sheet?.atTop = top
        }
        .background(Theme.background)
        .toolbar(sheet == nil ? .visible : .hidden, for: .navigationBar)
        .navigationTitle(inlineItem == nil ? "" : model.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(session.api) }
        .refreshable { await model.load(session.api) }
        .fullScreenCover(item: $playing, onDismiss: { Task { await model.load(session.api) } }) { PlayerScreen(item: $0) }
        .fullScreenCover(item: $fullScreenItem, onDismiss: { Task { await model.load(session.api) } }) { PlayerScreen(item: $0, startFullScreen: true) }
        .confirmationDialog("Delete the episode from the server?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete episode \(deleting?.numberLabel ?? "")", role: .destructive) {
                guard let ep = deleting else { return }
                Task {
                    do { try await session.api.deleteEpisode(ep.id); model.removed(episode: ep.id) }
                    catch { deleteError = error.localizedDescription }
                }
            }
        } message: { Text("The file and subtitles are deleted from the server, freeing space. To watch it again you will have to download it again.") }
        .confirmationDialog("Delete the whole series from the server?", isPresented: $deletingSeries, titleVisibility: .visible) {
            Button("Delete the series and all its episodes", role: .destructive) {
                guard let series = model.series else { return }
                Task {
                    do { try await session.api.deleteSeries(series.id); model.removedSeries() }
                    catch { deleteError = error.localizedDescription }
                }
            }
        } message: { Text("All episodes of “\(model.title)” are deleted from the server.") }
        .alert("Delete failed", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(deleteError ?? "") }
        .sheet(item: movingItem) { batch in moveSheet(batch) }
        .sheet(isPresented: $editingSeries) {
            if let series = model.series {
                EditSeriesSheet(series: series) { relinked in
                    editingSeries = false
                    if relinked { sheet?.close() } else { Task { await model.load(session.api) } }
                }
            }
        }
        .sheet(item: $editing) { ep in
            EditEpisodeSheet(episode: ep) { editing = nil; Task { await model.load(session.api) } }
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showStatus) { statusSheet }
        .sheet(isPresented: $showSources, onDismiss: { Task { await model.load(session.api) } }) {
            SourcesSheet(title: model.title, aniListId: ref.aniListId, seriesId: model.series?.id) { url, label in
                start(.direct(url, title: label))
            }
        }
    }

    private var movingItem: Binding<MoveBatch?> {
        Binding(get: { moving.map(MoveBatch.init) }, set: { if $0 == nil { moving = nil } })
    }

    private func moveSheet(_ batch: MoveBatch) -> some View {
        MoveEpisodesSheet(episodes: batch.episodes, fromTitle: model.title) { newSeriesId in
            moving = nil
            if newSeriesId != model.series?.id { sheet?.close() } else { Task { await model.load(session.api) } }
        }
    }

    private var statusSheet: some View {
        ListStatusSheet(entry: model.entry, total: model.media?.episodes) { update in
            guard let id = ref.aniListId ?? model.media?.id else { return model.entry }
            try await session.api.saveTrackerEntry(id, update)
            let e = try await session.api.trackerEntry(id)
            model.entry = e
            return e
        }
        .presentationDetents([.large]).presentationBackground(DS.surfaceRaised)
    }

    // MARK: Header (banner or inline player)

    @ViewBuilder private var header: some View {
        if let inlineItem {
            InlinePlayer(item: inlineItem, close: { self.inlineItem = nil; Task { await model.load(session.api) } },
                         expand: { self.inlineItem = nil; fullScreenItem = inlineItem })
                .aspectRatio(16 / 9, contentMode: .fit)
                .id(inlineItem.id)
        } else {
            Color.clear
                .frame(height: inlinePlayer ? 280 : 340)
                .overlay {
                    // Slow zoom 1.0 → 1.08 over 20 s.
                    RemoteImage(url: model.media.flatMap { ($0.bannerUrl ?? $0.coverUrl).flatMap(URL.init(string:)) } ?? ref.bannerURL)
                        .scaleEffect(zoomed ? 1.08 : 1)
                        .animation(reduceMotion ? nil : .linear(duration: 20), value: zoomed)
                        .onAppear { zoomed = true }
                }
                .overlay(DS.scrimBottom)
                .clipped()
                .overlay(alignment: .topLeading) {
                    // On the iPhone Duo the sheet host draws Back on the side, in the column of the tabs.
                    if let sheet, !sheet.backOnSide {
                        Button { Haptics.tick(); sheet.close() } label: {
                            Image(systemName: "chevron.left").font(.body.bold()).foregroundStyle(.white)
                                .frame(width: 44, height: 44).glassCircle()
                        }
                        .accessibilityLabel("Back")
                        .padding(.leading, 12).padding(.top, 14)
                    }
                }
                .overlay {
                    if inlinePlayer, let next = model.nextToWatch, model.series != nil {
                        Button { Haptics.tick(); play(next) } label: {
                            Image(systemName: "play.fill").font(.title).foregroundStyle(.white).frame(width: 64, height: 64).glassCircle()
                        }
                        .accessibilityLabel("Play")
                    }
                }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.title).font(DS.display(32, 800)).lineLimit(3).minimumScaleFactor(0.7)
            if let r = model.media?.titleRomaji, r != model.title {
                Text(r).font(DS.body(13)).foregroundStyle(DS.textTertiary).lineLimit(1)
            }
            HStack(spacing: 8) {
                Text(metaLine).font(DS.body(13)).foregroundStyle(DS.textSecondary)
                if !model.episodes.isEmpty { BadgeLabel(text: "On server") }
            }
            .padding(.top, 4)
            nextAiringRow
        }
    }

    /// AniList status card; tapping it opens the status sheet ("+ Lista" included).
    @ViewBuilder private var aniListRow: some View {
        if (ref.aniListId ?? model.media?.id) != nil, session.user?.hasTracker == true {
            Button { showStatus = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: model.entry == nil ? "plus" : "link").foregroundStyle(DS.teal)
                    Text(model.entry.map { e in
                        let total = model.media?.episodes.map(String.init) ?? "?"
                        let score = e.score.flatMap { $0 > 0 ? " · ★ \(Int($0.rounded()))" : nil } ?? ""
                        return String(localized: "Watched \(e.progress)/\(total) · \(statusLabel(e.status))") + score
                    } ?? String(localized: "Add to your list"))
                        .font(DS.body(14))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(DS.textTertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(DS.surface, in: .rect(cornerRadius: DS.rCard))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else if session.user?.hasTracker != true {
            Text("Connect a list from Profile").font(DS.body(13)).foregroundStyle(DS.textTertiary)
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let y = model.media?.year ?? model.series?.year { parts.append(String(y)) }
        if let g = (model.media?.genres ?? model.series?.genreList), !g.isEmpty { parts.append(g.prefix(3).joined(separator: " · ")) }
        if let n = model.media?.episodes ?? model.series?.totalEpisodes { parts.append(String(localized: "\(n) episodes")) }
        if let s = model.media?.averageScore { parts.append("★ \(s)%") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var nextAiringRow: some View {
        if let t = model.media?.nextAiringText {
            Label(t, systemImage: "calendar").font(DS.body(13)).foregroundStyle(DS.teal)
        }
    }

    // MARK: Buttons

    @ViewBuilder private var mainButtons: some View {
        if let next = model.nextToWatch, model.series != nil {
            HStack(spacing: 10) {
                Button { Haptics.tick(); play(next) } label: {
                    Label(next.positionSeconds ?? 0 > 5 && !next.completed ? "Resume E\(next.numberLabel)" : "Watch E\(next.numberLabel)",
                          systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                Button { showSources = true } label: { Label("Find episodes", systemImage: "magnifyingglass") }
                    .buttonStyle(PrimaryButtonStyle(prominent: false)).fixedSize()
            }
        } else if !model.loading {
            VStack(spacing: 10) {
                Text("Not on the server yet").font(DS.body(14)).foregroundStyle(DS.textSecondary)
                Button { showSources = true } label: { Label("Find episodes", systemImage: "magnifyingglass") }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var descriptionBlock: some View {
        if !model.description.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.description).font(DS.body(14)).foregroundStyle(DS.textSecondary).lineSpacing(3)
                    .lineLimit(expanded ? nil : 3)
                    .onTapGesture { withAnimation(DS.base) { expanded.toggle() } }
                if model.description.count > 160 {
                    Button(expanded ? "less" : "more") { withAnimation(DS.base) { expanded.toggle() } }
                        .font(DS.body(14, 700)).foregroundStyle(.white)
                }
            }
        }
    }

    private func statusLabel(_ s: String) -> String {
        ListStatusSheet.label(s)
    }

    // MARK: Episodi / Simili

    private var sectionPicker: some View {
        PillSegmented(options: ["Episodes", "Similar"], selection: $section).padding(.horizontal)
    }

    @ViewBuilder private var episodesSection: some View {
        if model.loading && model.episodes.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 20)
        } else if model.episodes.isEmpty {
            Text("No episodes on the server").font(DS.body(14)).foregroundStyle(DS.textTertiary)
                .frame(maxWidth: .infinity).padding(.vertical, 32)
        } else {
            if let series = model.series {
                HStack(spacing: 8) {
                    Spacer()
                    Menu {
                        Button("Repair the whole series on the server", systemImage: "wrench.and.screwdriver") {
                            Task { try? await session.api.repairSeries(series.id) }
                        }
                        Button("Edit info and images…", systemImage: "pencil") { editingSeries = true }
                        Button("Move the series to another…", systemImage: "arrow.right.circle") { moving = model.episodes }
                        Button("Delete series from server…", systemImage: "trash", role: .destructive) { deletingSeries = true }
                    } label: { Label("More", systemImage: "ellipsis") }
                        .buttonStyle(GhostButtonStyle())
                    Button { Task { for e in model.episodes where !offline.isDownloaded(e.id) { await offline.download(e, of: series, api: session.api) } } } label: {
                        Label("Download all to device", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(GhostButtonStyle())
                }
                .padding(.horizontal)
            }
            let shown = showAll ? model.episodes : Array(model.episodes.prefix(12))
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { ep in
                    EpisodeRow(episode: ep, series: model.series, watchedOnAniList: !ep.extra && Double(model.entry?.progress ?? 0) >= ep.number,
                               playing: inlineItem?.id == "ep-\(ep.id)", onDelete: { deleting = ep }, onMove: { moving = [ep] }, onEdit: { editing = ep }) {
                        Haptics.tick(); play(ep)
                    }
                }
            }
            .padding(.horizontal)
            if !showAll && model.episodes.count > 12 {
                Button("More episodes (\(model.episodes.count - 12))") { withAnimation(DS.base) { showAll = true } }
                    .buttonStyle(PrimaryButtonStyle(prominent: false)).padding(.horizontal)
            }
        }
    }

    @ViewBuilder private var similarSection: some View {
        Group {
            if !model.similarLoaded {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
            } else if model.similar.isEmpty && model.related.isEmpty {
                Text("No similar titles").font(DS.body(14)).foregroundStyle(DS.textTertiary).frame(maxWidth: .infinity).padding(.vertical, 32)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if !model.related.isEmpty {
                        Text("Seasons and related").font(DS.display(17, 700)).padding(.horizontal)
                        posterGrid(model.related.map { ($0.ref, $0.relation) })
                    }
                    if !model.similar.isEmpty {
                        Text("Similar").font(DS.display(17, 700)).padding(.horizontal).padding(.top, model.related.isEmpty ? 0 : 14)
                        posterGrid(model.similar.map { ($0, nil) })
                    }
                }
            }
        }
        .task { await model.loadSimilar(session.api) }
    }

    /// Posters wrap into rows: the page scrolls vertically instead of sideways.
    private func posterGrid(_ items: [(TitleRef, String?)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 12, alignment: .top)], alignment: .leading, spacing: 18) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button { openTitle(item.0) } label: { PosterCard(title: item.0.title, url: item.0.posterURL, meta: item.1, width: 112) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }

    private func play(_ ep: EpisodeDTO) {
        guard let series = model.series else { return }
        start(.episode(ep, series: series, playlist: model.episodes))
    }

    private func start(_ item: PlaybackItem) {
        if inlinePlayer { inlineItem = item } else { playing = item }
    }
}

struct EpisodeRow: View {
    let episode: EpisodeDTO
    let series: SeriesDTO?
    let watchedOnAniList: Bool
    var playing = false
    var onDelete: (() -> Void)? = nil
    var onMove: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    let play: () -> Void
    @Environment(AppSession.self) private var session
    @Environment(OfflineDownloads.self) private var offline

    private var seen: Bool { episode.completed || watchedOnAniList }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: play) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(playing ? DS.accent : seen ? DS.accentSoft : DS.surface)
                        if seen && !playing { Image(systemName: "checkmark").font(.subheadline.bold()).foregroundStyle(DS.accent) }
                        else { Text(episode.numberLabel).font(DS.display(14, 700)).foregroundStyle(playing ? DS.onAccent : DS.textSecondary) }
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(episode.title ?? "Episode \(episode.numberLabel)").font(DS.body(15, 600)).lineLimit(1)
                        Text([episode.durationSeconds.flatMap { $0 >= 60 ? $0.durationLabel : nil }, episode.sizeBytes.fileSize, episode.source.capitalized]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(DS.body(12)).foregroundStyle(DS.textTertiary)
                        if let p = episode.progressFraction, p > 0, !episode.completed { ProgressLine(value: p).padding(.top, 6) }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            deviceDownloadButton
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.hairline).frame(height: 1) }
        .contextMenu {
            // Audio out of sync, slow to start, subtitles missing: the server reprocesses the file.
            Button("Repair on server", systemImage: "wrench.and.screwdriver") {
                Task { try? await session.api.repairEpisode(episode.id) }
            }
            if let file = offline.localURL(for: episode.id) {
                ShareLink(item: file) { Label("Open with…", systemImage: "square.and.arrow.up") }
            }
            if let onEdit {
                Button("Edit number…", systemImage: "pencil", action: onEdit)
            }
            if let onMove {
                Button("Move to another series…", systemImage: "arrow.right.circle", action: onMove)
            }
            if let onDelete {
                Divider()
                Button("Delete from server…", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
    }

    @ViewBuilder private var deviceDownloadButton: some View {
        if offline.isDownloaded(episode.id) {
            Menu {
                Button("Remove from device", systemImage: "trash", role: .destructive) { offline.delete(episode.id) }
            } label: { Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(DS.accent).frame(width: 44, height: 44) }
        } else if let p = offline.inFlight[episode.id] {
            Button { offline.cancel(episode.id) } label: {
                Gauge(value: p) { EmptyView() }.gaugeStyle(.accessoryCircularCapacity).scaleEffect(0.5).frame(width: 30, height: 30)
            }
        } else if let series {
            Button { Task { await offline.download(episode, of: series, api: session.api) } } label: {
                Image(systemName: "arrow.down.to.line").font(.body.weight(.semibold)).foregroundStyle(.white).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Download to device")
        }
    }
}


/// Status, episodes watched and rating (1-10) of a title on the list in use (AniList or MyAnimeList).
struct ListStatusSheet: View {
    let total: Int?
    let save: (EntryUpdate) async throws -> AniListEntry?
    @State private var cur: AniListEntry?
    @State private var busy = false
    @State private var error: String?

    init(entry: AniListEntry?, total: Int?, save: @escaping (EntryUpdate) async throws -> AniListEntry?) {
        self.total = total; self.save = save
        _cur = State(initialValue: entry)
    }

    static func label(_ s: String) -> String {
        switch s {
        case "CURRENT": String(localized: "Watching")
        case "PLANNING": String(localized: "Planning")
        case "COMPLETED": String(localized: "Completed")
        case "PAUSED": String(localized: "Paused")
        case "DROPPED": String(localized: "Dropped")
        case "REPEATING": String(localized: "Rewatching")
        default: s
        }
    }

    private var progress: Int { cur?.progress ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("List status").font(DS.display(20, 700)).padding(.top, 28).padding(.bottom, 8)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Episodes watched").font(DS.body(16))
                        if let total { Text("of \(total)").font(DS.body(12)).foregroundStyle(DS.textTertiary) }
                    }
                    Spacer()
                    stepButton("minus", label: "One less", disabled: busy || progress <= 0) { apply(EntryUpdate(progress: progress - 1)) }
                    Text("\(progress)").font(DS.body(17, 700)).frame(minWidth: 36)
                    stepButton("plus", label: "One more", disabled: busy || progress >= (total ?? 9999)) { apply(EntryUpdate(progress: progress + 1)) }
                }
                .frame(height: 56)
                Rectangle().fill(DS.hairline).frame(height: 1)

                Text("Status").font(DS.body(12, 700)).tracking(1).foregroundStyle(DS.textTertiary).padding(.top, 16).padding(.bottom, 4)
                ForEach(ListStatus.all, id: \.self) { s in
                    Button { Haptics.tick(); apply(EntryUpdate(status: s)) } label: {
                        HStack {
                            Text(Self.label(s)).font(DS.body(16))
                            Spacer()
                            if s == cur?.status { Image(systemName: "checkmark").foregroundStyle(DS.accent) }
                        }
                        .frame(height: 48).contentShape(.rect)
                    }
                    .buttonStyle(.plain).disabled(busy)
                    Rectangle().fill(DS.hairline).frame(height: 1)
                }

                Text("Your rating").font(DS.body(12, 700)).tracking(1).foregroundStyle(DS.textTertiary).padding(.top, 16).padding(.bottom, 8)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(1...10, id: \.self) { n in
                        let on = Int((cur?.score ?? 0).rounded()) == n
                        Button { apply(EntryUpdate(score: n)) } label: {
                            Text("\(n)").font(DS.display(16, 700)).frame(maxWidth: .infinity).frame(height: 44)
                                .foregroundStyle(on ? DS.onAccent : .white)
                                .background(on ? DS.accent : DS.surface, in: .rect(cornerRadius: 10))
                        }
                        .buttonStyle(.plain).disabled(busy || cur == nil)
                    }
                }
                if (cur?.score ?? 0) > 0 {
                    Button("Remove rating") { apply(EntryUpdate(score: 0)) }
                        .font(DS.body(14, 600)).foregroundStyle(DS.accent).padding(.top, 10).disabled(busy)
                }
                if cur == nil {
                    Text("Choose a status first to add this title to your list, then you can rate it.")
                        .font(DS.body(12)).foregroundStyle(DS.textTertiary).padding(.top, 8)
                }
                if let error { Text(error).font(DS.body(13)).foregroundStyle(DS.pink).padding(.top, 10) }
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
    }

    private func stepButton(_ icon: String, label: LocalizedStringKey, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.body.weight(.bold)).frame(width: 40, height: 40)
                .background(DS.surface, in: .circle).opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.plain).disabled(disabled).accessibilityLabel(label)
    }

    private func apply(_ update: EntryUpdate) {
        busy = true; error = nil
        Task {
            do { cur = try await save(update) }
            catch {
                self.error = (error as? APIError).flatMap { if case .http(409, _) = $0 { String(localized: "Connect a list from Profile") } else { nil } } ?? error.localizedDescription
            }
            busy = false
        }
    }
}


/// "Edit number": fixes the number of one episode by hand, or marks it as an extra (EX1) that AniList never counts.
struct EditEpisodeSheet: View {
    let episode: EpisodeDTO
    let done: () -> Void

    @Environment(AppSession.self) private var session
    @State private var number: String
    @State private var isExtra: Bool
    @State private var busy = false
    @State private var error: String?

    init(episode: EpisodeDTO, done: @escaping () -> Void) {
        self.episode = episode; self.done = done
        _number = State(initialValue: episode.number.rounded() == episode.number ? String(Int(episode.number)) : String(episode.number))
        _isExtra = State(initialValue: episode.extra)
    }

    private var parsed: Double? { Double(number.replacingOccurrences(of: ",", with: ".")) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit number").font(DS.display(22, 800)).padding(.top, 24)
            TextField("Number", text: $number).keyboardType(.decimalPad).font(DS.body(18))
                .padding(14).background(DS.surface, in: .rect(cornerRadius: DS.rCard))
            Toggle(isOn: $isExtra) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Extra content").font(DS.body(15, 600))
                    Text("Shown as EX\(number) and not counted in AniList progress.").font(DS.body(12)).foregroundStyle(DS.textTertiary)
                }
            }
            if let error { Text(error).font(DS.body(13)).foregroundStyle(.red) }
            Button { save() } label: { Text("Save").frame(maxWidth: .infinity) }
                .buttonStyle(PrimaryButtonStyle()).disabled(parsed == nil || busy)
            Spacer()
        }
        .padding(.horizontal, 20)
        .background(DS.background.ignoresSafeArea())
    }

    private func save() {
        guard let n = parsed else { return }
        busy = true; error = nil
        Task {
            do { try await session.api.editEpisode(episode.id, number: n, isExtra: isExtra); done() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

/// "Edit info": fixes title, description, poster, banner and the AniList link of a series; "Aggiorna da AniList" re-reads them.
struct EditSeriesSheet: View {
    let series: SeriesDTO
    let done: (Bool) -> Void

    @Environment(AppSession.self) private var session
    @State private var title: String
    @State private var desc: String
    @State private var poster: String
    @State private var banner: String
    @State private var aniListId: String
    @State private var busy = false
    @State private var error: String?

    init(series: SeriesDTO, done: @escaping (Bool) -> Void) {
        self.series = series; self.done = done
        _title = State(initialValue: series.title)
        _desc = State(initialValue: series.description ?? "")
        _poster = State(initialValue: series.posterUrl ?? "")
        _banner = State(initialValue: series.bannerUrl ?? "")
        _aniListId = State(initialValue: series.aniListId.map(String.init) ?? "")
    }

    private var newId: Int? { aniListId.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : Int(aniListId) }

    private func field(_ label: String, _ text: Binding<String>, lines: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(DS.body(12, 600)).foregroundStyle(DS.textTertiary)
            TextField(label, text: text, axis: .vertical).lineLimit(1...lines).font(DS.body(15))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12).background(DS.surface, in: .rect(cornerRadius: DS.rCard))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Edit info").font(DS.display(22, 800)).padding(.top, 24)
                field("Title", $title)
                field("AniList ID (empty = no link)", $aniListId)
                field("Poster URL", $poster, lines: 3)
                field("Banner URL", $banner, lines: 3)
                field("Description", $desc, lines: 8)
                if let error { Text(error).font(DS.body(13)).foregroundStyle(.red) }
                Button { save(refresh: false) } label: { Text("Save").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButtonStyle()).disabled(busy || newId == nil || title.trimmingCharacters(in: .whitespaces).isEmpty)
                Button { save(refresh: true) } label: { Label("Save and refresh from AniList", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButtonStyle(prominent: false)).disabled(busy || (newId ?? 0) == 0)
                Text("“Refresh from AniList” replaces title, description, images, episodes, genres and year with AniList’s.")
                    .font(DS.body(12)).foregroundStyle(DS.textTertiary)
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(DS.background.ignoresSafeArea())
    }

    private func save(refresh: Bool) {
        guard let id = newId else { return }
        busy = true; error = nil
        Task {
            do {
                var e = SeriesEdit(title: title, description: desc, posterUrl: poster, bannerUrl: banner, refreshFromAniList: refresh)
                if id != (series.aniListId ?? 0) { e.aniListId = id }
                try await session.api.editSeries(series.id, e)
                done(id != (series.aniListId ?? 0))
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct MoveBatch: Identifiable { let episodes: [EpisodeDTO]; var id: String { episodes.map { String($0.id) }.joined(separator: ",") } }

/// "Move to another series": pick the right AniList title (e.g. the correct season); files, subtitles and progress follow.
struct MoveEpisodesSheet: View {
    let episodes: [EpisodeDTO]
    let fromTitle: String
    let done: (Int) -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [AniListMedia] = []
    @State private var picked: AniListMedia?
    @State private var offset = "0"
    @State private var busy = false
    @State private var error: String?

    private var shift: Double { Double(offset.replacingOccurrences(of: ",", with: ".")) ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Move to another series").font(DS.display(22, 800)).padding(.top, 24)
                Text(episodes.count == 1 ? "You are moving episode \(episodes[0].numberLabel) of “\(fromTitle)”. The file, subtitles and progress go with it."
                                         : "You are moving \(episodes.count) episodes of “\(fromTitle)”. The files, subtitles and progress go with them.")
                    .font(DS.body(13)).foregroundStyle(DS.textSecondary)
                if let picked {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(picked.title).font(DS.body(16, 700))
                        Text([picked.year.map(String.init), picked.format, picked.episodes.map { "\($0) ep" }].compactMap { $0 }.joined(separator: " · "))
                            .font(DS.body(12)).foregroundStyle(DS.textTertiary)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(DS.surface, in: .rect(cornerRadius: DS.rCard))
                    Text("Shift the episode numbers by").font(DS.body(13, 600)).padding(.top, 6)
                    TextField("0", text: $offset).keyboardType(.numbersAndPunctuation).font(DS.body(16))
                        .padding(.horizontal, 16).frame(height: 50).background(DS.surface, in: .rect(cornerRadius: DS.rCard))
                    Text(episodes.count == 1 ? "Example: if episode 13 here is the first of the new series, enter -12. Episode \(episodes[0].numberLabel) will become \(String(format: "%g", episodes[0].number + shift))."
                                             : "Example: if episode 13 here is the first of the new series, enter -12.")
                        .font(DS.body(12)).foregroundStyle(DS.textTertiary)
                    if let error { Text(error).font(DS.body(13)).foregroundStyle(DS.pink) }
                    Button { Task { await move(picked) } } label: { Text(busy ? "Moving…" : "Move to “\(picked.title)”") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(busy)
                    Button("Choose another series") { self.picked = nil }.font(DS.body(14, 600)).tint(DS.textSecondary)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(DS.textTertiary)
                        TextField("Find the right series on AniList", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    .padding(.horizontal, 16).frame(height: 50).background(DS.surface, in: .rect(cornerRadius: 25))
                    ForEach(results) { m in
                        Button { picked = m } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.title).font(DS.body(15, 600)).lineLimit(2)
                                Text([m.year.map(String.init), m.format, m.episodes.map { "\($0) ep" }].compactMap { $0 }.joined(separator: " · "))
                                    .font(DS.body(12)).foregroundStyle(DS.textTertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 52).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(DS.hairline)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
        .background(DS.background)
        .presentationBackground(DS.background)
        .presentationDragIndicator(.visible)
        .task { query = fromTitle }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, query.count > 1 else { return }
            results = (try? await session.api.aniListSearch(query)) ?? []
        }
    }

    private func move(_ target: AniListMedia) async {
        busy = true; error = nil
        do { done(try await session.api.moveEpisodes(episodes.map(\.id), toAniListId: target.id, numberOffset: shift)) }
        catch { self.error = error.localizedDescription; busy = false }
    }
}
