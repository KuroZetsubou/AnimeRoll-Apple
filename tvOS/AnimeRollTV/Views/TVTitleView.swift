import AnimeRollKit
import SwiftUI

/// Title page: banner backdrop, info on the left, Guarda / Trova episodi / Lista, then Episodi or Simili (AniList).
struct TVTitleView: View {
    let ref: TitleRef
    @Environment(AppSession.self) private var session
    @Environment(OfflineDownloads.self) private var offline
    @State private var media: AniListMedia?
    @State private var series: SeriesDTO?
    @State private var episodes: [EpisodeDTO] = []
    @State private var entry: AniListEntry?
    @State private var similar: [TitleRef]?
    @State private var related: [(relation: String, ref: TitleRef)] = []
    @State private var playing: PlaybackItem?
    @State private var showSources = false
    @State private var section = 0
    @State private var loaded = false
    @State private var deleting: EpisodeDTO?
    @State private var deletingSeries = false
    @State private var deleteError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                HStack(alignment: .top, spacing: 60) {
                    AsyncImage(url: (media?.coverUrl).flatMap(URL.init(string:)) ?? ref.posterURL) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { DS.surface }
                        .frame(width: 340, height: 510).clipShape(.rect(cornerRadius: DS.rCard))

                    VStack(alignment: .leading, spacing: 18) {
                        Text(media?.title ?? series?.title ?? ref.title).font(DS.display(64, 800)).lineLimit(2)
                        if let r = media?.titleRomaji, r != (media?.title ?? "") { Text(r).font(DS.body(24)).foregroundStyle(DS.textTertiary) }
                        HStack(spacing: 14) {
                            Text(meta).font(DS.body(26)).foregroundStyle(DS.textSecondary)
                            if !episodes.isEmpty { TVBadge(text: "Sul NAS") }
                        }
                        if let t = media?.nextAiringText {
                            Label(t, systemImage: "calendar").font(DS.body(26)).foregroundStyle(DS.teal)
                        }
                        if let e = entry {
                            Label("AniList: guardati \(e.progress)/\(media?.episodes.map(String.init) ?? "?") · \(AniListStatusLabel.text(e.status))", systemImage: "link")
                                .font(DS.body(26)).foregroundStyle(DS.teal)
                        }
                        Text(media?.plainDescription ?? series?.description ?? "").font(DS.body(26)).foregroundStyle(DS.textSecondary).lineLimit(4)
                        HStack(spacing: 24) {
                            if let next = nextEpisode {
                                Button { play(next) } label: {
                                    Label((next.positionSeconds ?? 0) > 5 && !next.completed ? "Riprendi E\(next.numberLabel)" : "Guarda E\(next.numberLabel)", systemImage: "play.fill")
                                }
                            } else if loaded {
                                Text("Non ancora sul NAS").font(DS.body(26)).foregroundStyle(DS.textSecondary)
                            }
                            Button { showSources = true } label: { Label("Trova episodi", systemImage: "magnifyingglass") }
                            if let id = ref.aniListId, session.user?.aniListConnected == true {
                                Menu {
                                    ForEach(["CURRENT", "PLANNING", "COMPLETED", "PAUSED", "DROPPED"], id: \.self) { s in
                                        Button(AniListStatusLabel.text(s)) {
                                            Task { try? await session.api.aniListSetStatus(id, status: s); entry = (try? await session.api.aniListEntry(id)) ?? nil }
                                        }
                                    }
                                } label: { Label(entry == nil ? "Lista" : "✓ Lista", systemImage: entry == nil ? "plus" : "checkmark") }
                            }
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 80)
                .focusSection()

                Picker("", selection: $section) { Text("Episodi").tag(0); Text("Simili").tag(1) }
                    .pickerStyle(.segmented).frame(maxWidth: 600).padding(.horizontal, 80)

                if section == 0 { episodesRow } else { similarRow }
            }
            .padding(.vertical, 60)
        }
        .background {
            AsyncImage(url: (media?.bannerUrl).flatMap(URL.init(string:)) ?? ref.bannerURL) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { DS.background }
                .overlay(DS.background.opacity(0.82)).blur(radius: 30).ignoresSafeArea()
        }
        .fullScreenCover(item: $playing, onDismiss: { Task { await load() } }) { TVPlayerView(item: $0) }
        .sheet(isPresented: $showSources, onDismiss: { Task { await load() } }) { TVSourcesView(title: media?.title ?? ref.title, aniListId: ref.aniListId, seriesId: series?.id) }
        .confirmationDialog("Eliminare l'episodio dal NAS?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Elimina episodio \(deleting?.numberLabel ?? "")", role: .destructive) {
                guard let ep = deleting else { return }
                Task {
                    do { try await session.api.deleteEpisode(ep.id); episodes.removeAll { $0.id == ep.id }; if episodes.isEmpty { series = nil } }
                    catch { deleteError = error.localizedDescription }
                }
            }
        } message: { Text("Il file e i sottotitoli vengono cancellati dal NAS e liberano spazio.") }
        .confirmationDialog("Eliminare tutta la serie dal NAS?", isPresented: $deletingSeries, titleVisibility: .visible) {
            Button("Elimina la serie e tutti gli episodi", role: .destructive) {
                guard let s = series else { return }
                Task {
                    do { try await session.api.deleteSeries(s.id); episodes = []; series = nil }
                    catch { deleteError = error.localizedDescription }
                }
            }
        }
        .alert("Eliminazione non riuscita", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(deleteError ?? "") }
        .task { await load() }
        .task(id: section) { if section == 1 { await loadSimilar() } }
    }

    @ViewBuilder private var episodesRow: some View {
        if episodes.isEmpty {
            Text(loaded ? "Nessun episodio sul NAS" : "").font(DS.body(26)).foregroundStyle(DS.textTertiary).padding(.horizontal, 80)
        } else {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 40) {
                    ForEach(episodes) { ep in episodeCard(ep) }
                }
                .padding(.horizontal, 80).padding(.vertical, 30)
            }
            .scrollClipDisabled()
        }
    }

    private func episodeBadge(_ ep: EpisodeDTO) -> String? {
        if ep.completed || Double(entry?.progress ?? 0) >= ep.number { return "Visto" }
        return offline.isDownloaded(ep.id) ? "Offline" : nil
    }

    private func episodeMeta(_ ep: EpisodeDTO) -> String {
        var text = "E\(ep.numberLabel)"
        if let d = ep.durationSeconds { text += " · \(d.durationLabel)" }
        return text
    }

    private func episodeCard(_ ep: EpisodeDTO) -> some View {
        let image: URL? = (series?.bannerUrl ?? series?.posterUrl).flatMap { URL(string: $0) }
        return Button { play(ep) } label: {
            TVPoster(title: ep.title ?? "Episodio \(ep.numberLabel)", url: image, badge: episodeBadge(ep),
                     meta: episodeMeta(ep), progress: ep.progressFraction, wide: true)
        }
        .buttonStyle(.borderless)
        .contextMenu {
            if let series, !offline.isDownloaded(ep.id) {
                Button("Scarica su Apple TV") { Task { await offline.download(ep, of: series, api: session.api) } }
            }
            Button("Ripara sul NAS") { Task { try? await session.api.repairEpisode(ep.id) } }
            if offline.isDownloaded(ep.id) { Button("Rimuovi da Apple TV", role: .destructive) { offline.delete(ep.id) } }
            Button("Elimina dal NAS…", role: .destructive) { deleting = ep }
            if series != nil { Button("Elimina tutta la serie dal NAS…", role: .destructive) { deletingSeries = true } }
        }
    }

    @ViewBuilder private var similarRow: some View {
        if similar == nil { ProgressView().frame(maxWidth: .infinity) }
        else if similar?.isEmpty == true && related.isEmpty { Text("Nessun titolo simile").font(DS.body(26)).foregroundStyle(DS.textTertiary).padding(.horizontal, 80) }
        else {
            // Rows of posters; the page itself scrolls down.
            VStack(alignment: .leading, spacing: 20) {
                if !related.isEmpty {
                    Text("Stagioni e correlati").font(DS.display(34, 700)).padding(.horizontal, 80)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(260), spacing: 40, alignment: .top), count: 5), alignment: .leading, spacing: 50) {
                        ForEach(Array(related.enumerated()), id: \.offset) { _, item in
                            NavigationLink(value: item.ref) { TVPoster(title: item.ref.title, url: item.ref.posterURL, meta: item.relation) }.buttonStyle(.borderless)
                        }
                    }
                    .padding(.horizontal, 80).padding(.bottom, 30)
                    Text("Simili").font(DS.display(34, 700)).padding(.horizontal, 80)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(260), spacing: 40, alignment: .top), count: 5), alignment: .leading, spacing: 50) {
                    ForEach(similar ?? [], id: \.self) { r in
                        NavigationLink(value: r) { TVPoster(title: r.title, url: r.posterURL) }.buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 80).padding(.vertical, 30)
            }
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let y = media?.year ?? series?.year { parts.append(String(y)) }
        let genres = media?.genres ?? series?.genreList ?? []
        if !genres.isEmpty { parts.append(genres.prefix(3).joined(separator: " · ")) }
        if let n = media?.episodes ?? series?.totalEpisodes { parts.append("\(n) episodi") }
        if let s = media?.averageScore { parts.append("★ \(s)%") }
        return parts.joined(separator: " · ")
    }

    private var nextEpisode: EpisodeDTO? {
        let watched = Double(entry?.progress ?? 0)
        return episodes.first { ($0.positionSeconds ?? 0) > 5 && !$0.completed } ?? episodes.first { !$0.completed && $0.number > watched } ?? episodes.first
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
        loaded = true
    }

    /// "Simili": AniList's recommendations; titles already on the NAS open their NAS page.
    private func loadSimilar() async {
        guard similar == nil else { return }
        guard let id = ref.aniListId ?? media?.id else { similar = []; return }
        async let rec = try? session.api.aniListRecommendations(id)
        async let lib = try? session.api.library()
        async let rel = try? session.api.aniListRelations(id)
        let (r, l, rl) = await (rec, lib, rel)
        // Two NAS series can share one AniList id: keep the first instead of crashing.
        let onNAS = Dictionary((l ?? []).compactMap { s in s.aniListId.map { ($0, s) } }, uniquingKeysWith: { first, _ in first })
        var seen = Set<Int>()
        related = (rl ?? []).map { ($0.relation, onNAS[$0.media.id].map(TitleRef.series) ?? .aniList($0.media)) }
        similar = (r ?? []).filter { $0.id != id && seen.insert($0.id).inserted }.map { m in onNAS[m.id].map(TitleRef.series) ?? .aniList(m) }
    }

    private func play(_ ep: EpisodeDTO) {
        guard let series else { return }
        playing = .episode(ep, series: series, playlist: episodes)
    }
}

/// "Trova episodi" for the remote: 1 Fonte, 2 Risultati, then pick episodes and send them to the NAS.
struct TVSourcesView: View {
    let title: String
    let aniListId: Int?
    var seriesId: Int? = nil
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var subtitleNote: String?
    @State private var providers: [ProviderInfo] = []
    @State private var provider: ProviderInfo?
    @State private var results: [SourceSearchResult] = []
    @State private var picked: SourceSearchResult?
    @State private var episodes: [SourceEpisode] = []
    @State private var selection = Set<String>()
    @State private var loading = false
    @State private var sent = 0
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if sent > 0 {
                    VStack(spacing: 20) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 90)).foregroundStyle(DS.accent)
                        Text("Inviati \(sent) download al NAS").font(DS.display(44, 700))
                        Text("Li trovi nella coda in Download.").font(DS.body(26)).foregroundStyle(DS.textSecondary)
                        Button("Chiudi") { dismiss() }
                    }
                    .frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    Text("Trova episodi").font(DS.display(52, 800))
                    Text(title).font(DS.body(26)).foregroundStyle(DS.textTertiary)
                    Text("1 · Fonte").font(DS.display(30, 700))
                    ScrollView(.horizontal) {
                        HStack(spacing: 16) {
                            ForEach(providers.filter { $0.enabled && $0.canSearch }) { p in
                                TVChip(title: p.name, selected: p.id == provider?.id) { provider = p }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .scrollClipDisabled()
                    if loading { ProgressView() }
                    if let picked {
                        HStack {
                            Text("3 · \(picked.title)").font(DS.display(30, 700)).lineLimit(1)
                            Spacer()
                            Button("Tutti") { selection = Set(episodes.map(\.ref)) }
                            Button("Nessuno") { selection = [] }
                        }
                        ForEach(episodes) { ep in
                            Button { if selection.contains(ep.ref) { selection.remove(ep.ref) } else { selection.insert(ep.ref) } } label: {
                                HStack {
                                    Image(systemName: selection.contains(ep.ref) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(selection.contains(ep.ref) ? DS.accent : DS.textTertiary)
                                    Text(ep.title).font(DS.body(28))
                                    Spacer()
                                }
                            }
                        }
                        Button { Task { await send() } } label: { Label("Scarica sul NAS (\(selection.count))", systemImage: "externaldrive.badge.plus") }
                            .disabled(selection.isEmpty)
                        if provider?.canSubtitles == true, seriesId != nil {
                            Button { Task { await refreshSubtitles() } } label: { Label("Aggiorna solo i sottotitoli (ASS)", systemImage: "captions.bubble") }
                            if let subtitleNote { Text(subtitleNote).font(DS.body(22)).foregroundStyle(DS.textSecondary) }
                        }
                        Button("← Risultati") { self.picked = nil; episodes = [] }
                    } else {
                        Text("2 · Risultati").font(DS.display(30, 700))
                        if results.isEmpty && !loading { Text("Nessun risultato.").font(DS.body(26)).foregroundStyle(DS.textTertiary) }
                        ForEach(results) { r in
                            Button { Task { await open(r) } } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(r.title).font(DS.body(28, 600))
                                    if let s = r.subtitle { Text(s).font(DS.body(22)).foregroundStyle(DS.textTertiary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    if let error { Text(error).font(DS.body(24)).foregroundStyle(DS.pink) }
                }
            }
            .padding(80)
        }
        .background(DS.background)
        .task {
            providers = (try? await session.api.providers()) ?? []
            provider = providers.first { $0.enabled && $0.canSearch }
        }
        .task(id: provider?.id) { await search() }
    }

    private func search() async {
        picked = nil; episodes = []
        guard let provider else { results = []; return }
        loading = true; error = nil
        results = ((try? await session.api.search(source: provider.id, query: title)) ?? []).prefix(15).map { $0 }
        loading = false
    }

    private func open(_ r: SourceSearchResult) async {
        guard let provider else { return }
        guard provider.canListEpisodes else { await send(items: [DownloadItem(sourceRef: r.ref, episodeNumber: nil)], aniList: r.aniListId); return }
        picked = r; loading = true
        episodes = (try? await session.api.sourceEpisodes(source: provider.id, ref: r.ref)) ?? []
        selection = Set(episodes.map(\.ref)); loading = false
    }

    private func refreshSubtitles() async {
        guard let provider, let picked, let seriesId else { return }
        subtitleNote = "Invio…"
        do {
            let r = try await session.api.refreshSubtitles(seriesId: seriesId, source: provider.id, seriesRef: picked.ref)
            subtitleNote = "\(r.queued) episodi in coda per i sottotitoli. Segui l'avanzamento in Download."
        } catch { subtitleNote = error.localizedDescription }
    }

    private func send() async {
        let items = episodes.filter { selection.contains($0.ref) }.map { DownloadItem(sourceRef: $0.ref, episodeNumber: $0.number) }
        await send(items: items, aniList: picked?.aniListId ?? episodes.first?.extra?["anilistId"].flatMap(Int.init))
    }

    private func send(items: [DownloadItem], aniList: Int?) async {
        guard let provider, !items.isEmpty else { return }
        do {
            _ = try await session.api.requestNASDownload(DownloadRequest(source: provider.id, seriesTitle: title, aniListId: aniListId ?? aniList, items: items))
            sent = items.count
        } catch { self.error = error.localizedDescription }
    }
}
