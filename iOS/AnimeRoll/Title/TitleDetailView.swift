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
                async let e = try? api.aniListEntry(alId)
                async let s = try? api.series(aniListId: alId)
                let (mm, ee, ss) = await (m, e, s)
                media = mm ?? media; entry = ee ?? nil; series = ss ?? series
            }
            if let series { episodes = try await api.episodes(seriesId: series.id) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// After deleting from the NAS: drop it locally; with no episodes left the series is gone too.
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

    /// "Simili": AniList's own recommendations, with the NAS version of a title when we have it.
    var similar: [TitleRef] = []
    var similarLoaded = false
    /// "Stagioni e correlati": prequels, sequels, side stories (with the relation label).
    var related: [(relation: String, ref: TitleRef)] = []
    func loadSimilar(_ api: APIClient) async {
        guard !similarLoaded, let alId = ref.aniListId ?? media?.id else { similarLoaded = true; return }
        async let rec = try? api.aniListRecommendations(alId)
        async let lib = try? api.library()
        async let rel = try? api.aniListRelations(alId)
        let (r, l, rl) = await (rec, lib, rel)
        // Two NAS series can share one AniList id: keep the first instead of crashing.
        let onNAS = Dictionary((l ?? []).compactMap { s in s.aniListId.map { ($0, s) } }, uniquingKeysWith: { first, _ in first })
        var seen = Set<Int>()
        similar = (r ?? []).filter { $0.id != alId && seen.insert($0.id).inserted }.map { m in onNAS[m.id].map(TitleRef.series) ?? .aniList(m) }
        related = (rl ?? []).map { ($0.relation, onNAS[$0.media.id].map(TitleRef.series) ?? .aniList($0.media)) }
        similarLoaded = true
    }

    /// First not-completed episode, for the big "Riproduci" button.
    var nextToWatch: EpisodeDTO? {
        let watchedOnAniList = Double(entry?.progress ?? 0)
        return episodes.first { !$0.completed && $0.number > watchedOnAniList } ?? episodes.first { !$0.completed } ?? episodes.first
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
        .confirmationDialog("Eliminare l'episodio dal NAS?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Elimina episodio \(deleting?.numberLabel ?? "")", role: .destructive) {
                guard let ep = deleting else { return }
                Task {
                    do { try await session.api.deleteEpisode(ep.id); model.removed(episode: ep.id) }
                    catch { deleteError = error.localizedDescription }
                }
            }
        } message: { Text("Il file e i sottotitoli vengono cancellati dal NAS e liberano spazio. Se vuoi rivederlo dovrai scaricarlo di nuovo.") }
        .confirmationDialog("Eliminare tutta la serie dal NAS?", isPresented: $deletingSeries, titleVisibility: .visible) {
            Button("Elimina la serie e tutti gli episodi", role: .destructive) {
                guard let series = model.series else { return }
                Task {
                    do { try await session.api.deleteSeries(series.id); model.removedSeries() }
                    catch { deleteError = error.localizedDescription }
                }
            }
        } message: { Text("Tutti gli episodi di “\(model.title)” vengono cancellati dal NAS.") }
        .alert("Eliminazione non riuscita", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(deleteError ?? "") }
        .sheet(item: movingItem) { batch in moveSheet(batch) }
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
        AniListStatusSheet(current: model.entry?.status, progress: model.entry?.progress ?? 0, total: model.media?.episodes,
                           setProgress: { n in
            guard let id = ref.aniListId ?? model.media?.id else { return }
            Task { try? await session.api.aniListSetProgress(id, progress: n); await model.load(session.api) }
        }) { status in
            showStatus = false
            guard let id = ref.aniListId ?? model.media?.id else { return }
            Task { try? await session.api.aniListSetStatus(id, status: status); await model.load(session.api) }
        }
        .presentationDetents([.height(470)])
        .presentationBackground(DS.surfaceRaised)
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
                        .accessibilityLabel("Indietro")
                        .padding(.leading, 12).padding(.top, 14)
                    }
                }
                .overlay {
                    if inlinePlayer, let next = model.nextToWatch, model.series != nil {
                        Button { Haptics.tick(); play(next) } label: {
                            Image(systemName: "play.fill").font(.title).foregroundStyle(.white).frame(width: 64, height: 64).glassCircle()
                        }
                        .accessibilityLabel("Riproduci")
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
                if !model.episodes.isEmpty { BadgeLabel(text: "Sul NAS") }
            }
            .padding(.top, 4)
        }
    }

    /// AniList status card; tapping it opens the status sheet ("+ Lista" included).
    @ViewBuilder private var aniListRow: some View {
        if (ref.aniListId ?? model.media?.id) != nil, session.user?.aniListConnected == true {
            Button { showStatus = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: model.entry == nil ? "plus" : "link").foregroundStyle(DS.teal)
                    Text(model.entry.map { "AniList: guardati \($0.progress)/\(model.media?.episodes.map(String.init) ?? "?") · \(statusLabel($0.status))" }
                         ?? "Aggiungi alla lista AniList")
                        .font(DS.body(14))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(DS.textTertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(DS.surface, in: .rect(cornerRadius: DS.rCard))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else if session.user?.aniListConnected != true {
            Text("Collega AniList dal Profilo").font(DS.body(13)).foregroundStyle(DS.textTertiary)
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let y = model.media?.year ?? model.series?.year { parts.append(String(y)) }
        if let g = (model.media?.genres ?? model.series?.genreList), !g.isEmpty { parts.append(g.prefix(3).joined(separator: " · ")) }
        if let n = model.media?.episodes ?? model.series?.totalEpisodes { parts.append("\(n) episodi") }
        if let s = model.media?.averageScore { parts.append("★ \(s)%") }
        return parts.joined(separator: " · ")
    }

    // MARK: Buttons

    @ViewBuilder private var mainButtons: some View {
        if let next = model.nextToWatch, model.series != nil {
            HStack(spacing: 10) {
                Button { Haptics.tick(); play(next) } label: {
                    Label(next.positionSeconds ?? 0 > 5 && !next.completed ? "Riprendi E\(next.numberLabel)" : "Guarda E\(next.numberLabel)",
                          systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                Button { showSources = true } label: { Label("Trova episodi", systemImage: "magnifyingglass") }
                    .buttonStyle(PrimaryButtonStyle(prominent: false)).fixedSize()
            }
        } else if !model.loading {
            VStack(spacing: 10) {
                Text("Non ancora sul NAS").font(DS.body(14)).foregroundStyle(DS.textSecondary)
                Button { showSources = true } label: { Label("Trova episodi", systemImage: "magnifyingglass") }
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
                    Button(expanded ? "meno" : "altro") { withAnimation(DS.base) { expanded.toggle() } }
                        .font(DS.body(14, 700)).foregroundStyle(.white)
                }
            }
        }
    }

    private func statusLabel(_ s: String) -> String {
        AniListStatusSheet.label(s)
    }

    // MARK: Episodi / Simili

    private var sectionPicker: some View {
        PillSegmented(options: ["Episodi", "Simili"], selection: $section).padding(.horizontal)
    }

    @ViewBuilder private var episodesSection: some View {
        if model.loading && model.episodes.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 20)
        } else if model.episodes.isEmpty {
            Text("Nessun episodio sul NAS").font(DS.body(14)).foregroundStyle(DS.textTertiary)
                .frame(maxWidth: .infinity).padding(.vertical, 32)
        } else {
            if let series = model.series {
                HStack(spacing: 8) {
                    Spacer()
                    Menu {
                        Button("Ripara tutta la serie sul NAS", systemImage: "wrench.and.screwdriver") {
                            Task { try? await session.api.repairSeries(series.id) }
                        }
                        Button("Sposta la serie in un'altra…", systemImage: "arrow.right.circle") { moving = model.episodes }
                        Button("Elimina la serie dal NAS…", systemImage: "trash", role: .destructive) { deletingSeries = true }
                    } label: { Label("Altro", systemImage: "ellipsis") }
                        .buttonStyle(GhostButtonStyle())
                    Button { Task { for e in model.episodes where !offline.isDownloaded(e.id) { await offline.download(e, of: series, api: session.api) } } } label: {
                        Label("Scarica tutti sul dispositivo", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(GhostButtonStyle())
                }
                .padding(.horizontal)
            }
            let shown = showAll ? model.episodes : Array(model.episodes.prefix(12))
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { ep in
                    EpisodeRow(episode: ep, series: model.series, watchedOnAniList: Double(model.entry?.progress ?? 0) >= ep.number,
                               playing: inlineItem?.id == "ep-\(ep.id)", onDelete: { deleting = ep }, onMove: { moving = [ep] }) {
                        Haptics.tick(); play(ep)
                    }
                }
            }
            .padding(.horizontal)
            if !showAll && model.episodes.count > 12 {
                Button("Altri episodi (\(model.episodes.count - 12))") { withAnimation(DS.base) { showAll = true } }
                    .buttonStyle(PrimaryButtonStyle(prominent: false)).padding(.horizontal)
            }
        }
    }

    @ViewBuilder private var similarSection: some View {
        Group {
            if !model.similarLoaded {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
            } else if model.similar.isEmpty && model.related.isEmpty {
                Text("Nessun titolo simile").font(DS.body(14)).foregroundStyle(DS.textTertiary).frame(maxWidth: .infinity).padding(.vertical, 32)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if !model.related.isEmpty {
                        Text("Stagioni e correlati").font(DS.display(17, 700)).padding(.horizontal)
                        posterGrid(model.related.map { ($0.ref, $0.relation) })
                    }
                    if !model.similar.isEmpty {
                        Text("Simili").font(DS.display(17, 700)).padding(.horizontal).padding(.top, model.related.isEmpty ? 0 : 14)
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
                        Text(episode.title ?? "Episodio \(episode.numberLabel)").font(DS.body(15, 600)).lineLimit(1)
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
            // Audio out of sync, slow to start, subtitles missing: the NAS reprocesses the file.
            Button("Ripara sul NAS", systemImage: "wrench.and.screwdriver") {
                Task { try? await session.api.repairEpisode(episode.id) }
            }
            if let file = offline.localURL(for: episode.id) {
                ShareLink(item: file) { Label("Apri con…", systemImage: "square.and.arrow.up") }
            }
            if let onMove {
                Button("Sposta in un'altra serie…", systemImage: "arrow.right.circle", action: onMove)
            }
            if let onDelete {
                Divider()
                Button("Elimina dal NAS…", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
    }

    @ViewBuilder private var deviceDownloadButton: some View {
        if offline.isDownloaded(episode.id) {
            Menu {
                Button("Rimuovi dal dispositivo", systemImage: "trash", role: .destructive) { offline.delete(episode.id) }
            } label: { Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(DS.accent).frame(width: 44, height: 44) }
        } else if let p = offline.inFlight[episode.id] {
            Button { offline.cancel(episode.id) } label: {
                Gauge(value: p) { EmptyView() }.gaugeStyle(.accessoryCircularCapacity).scaleEffect(0.5).frame(width: 30, height: 30)
            }
        } else if let series {
            Button { Task { await offline.download(episode, of: series, api: session.api) } } label: {
                Image(systemName: "arrow.down.to.line").font(.body.weight(.semibold)).foregroundStyle(.white).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Scarica sul dispositivo")
        }
    }
}


/// "Stato su AniList": In corso, Pianificato, Completato, In pausa, Abbandonato.
struct AniListStatusSheet: View {
    let current: String?
    let progress: Int
    let total: Int?
    let setProgress: (Int) -> Void
    let pick: (String) -> Void
    @State private var count: Int

    init(current: String?, progress: Int, total: Int?, setProgress: @escaping (Int) -> Void, pick: @escaping (String) -> Void) {
        self.current = current; self.progress = progress; self.total = total; self.setProgress = setProgress; self.pick = pick
        _count = State(initialValue: progress)
    }

    static func label(_ s: String) -> String {
        ["CURRENT": "In corso", "PLANNING": "Pianificato", "COMPLETED": "Completato", "PAUSED": "In pausa",
         "DROPPED": "Abbandonato", "REPEATING": "Rewatch"][s] ?? s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Stato su AniList").font(DS.display(20, 700)).padding(.top, 28).padding(.bottom, 8)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Episodi guardati").font(DS.body(16))
                    Text(total.map { "su \($0)" } ?? "").font(DS.body(12)).foregroundStyle(DS.textTertiary)
                }
                Spacer()
                Stepper(value: $count, in: 0...(total ?? 9999)) { Text("\(count)").font(DS.body(16, 700)).frame(maxWidth: .infinity, alignment: .trailing) }
                    .fixedSize()
                    .onChange(of: count) { _, n in setProgress(n) }
            }
            .frame(height: 56)
            Rectangle().fill(DS.hairline).frame(height: 1)
            ForEach(["CURRENT", "PLANNING", "COMPLETED", "PAUSED", "DROPPED"], id: \.self) { s in
                Button { Haptics.tick(); pick(s) } label: {
                    HStack {
                        Text(Self.label(s)).font(DS.body(16))
                        Spacer()
                        if s == current { Image(systemName: "checkmark").foregroundStyle(DS.accent) }
                    }
                    .frame(height: 50).contentShape(.rect)
                }
                .buttonStyle(.plain)
                Rectangle().fill(DS.hairline).frame(height: 1)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
    }
}


struct MoveBatch: Identifiable { let episodes: [EpisodeDTO]; var id: String { episodes.map { String($0.id) }.joined(separator: ",") } }

/// "Sposta in un'altra serie": pick the right AniList title (e.g. the correct season); files, subtitles and progress follow.
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
                Text("Sposta in un'altra serie").font(DS.display(22, 800)).padding(.top, 24)
                Text("Sposti \(episodes.count == 1 ? "l'episodio \(episodes[0].numberLabel)" : "\(episodes.count) episodi") di “\(fromTitle)”. Il file, i sottotitoli e i progressi vanno con loro.")
                    .font(DS.body(13)).foregroundStyle(DS.textSecondary)
                if let picked {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(picked.title).font(DS.body(16, 700))
                        Text([picked.year.map(String.init), picked.format, picked.episodes.map { "\($0) ep" }].compactMap { $0 }.joined(separator: " · "))
                            .font(DS.body(12)).foregroundStyle(DS.textTertiary)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(DS.surface, in: .rect(cornerRadius: DS.rCard))
                    Text("Cambia il numero degli episodi di").font(DS.body(13, 600)).padding(.top, 6)
                    TextField("0", text: $offset).keyboardType(.numbersAndPunctuation).font(DS.body(16))
                        .padding(.horizontal, 16).frame(height: 50).background(DS.surface, in: .rect(cornerRadius: DS.rCard))
                    Text("Esempio: se l'episodio 13 qui è il primo della nuova serie, metti -12."
                         + (episodes.count == 1 ? " L'episodio \(episodes[0].numberLabel) diventerà il \(String(format: "%g", episodes[0].number + shift))." : ""))
                        .font(DS.body(12)).foregroundStyle(DS.textTertiary)
                    if let error { Text(error).font(DS.body(13)).foregroundStyle(DS.pink) }
                    Button { Task { await move(picked) } } label: { Text(busy ? "Spostamento…" : "Sposta in “\(picked.title)”") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(busy)
                    Button("Scegli un'altra serie") { self.picked = nil }.font(DS.body(14, 600)).tint(DS.textSecondary)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(DS.textTertiary)
                        TextField("Cerca la serie giusta su AniList", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
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
