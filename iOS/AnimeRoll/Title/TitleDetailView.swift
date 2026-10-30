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

    var title: String { media?.title ?? series?.title ?? ref.title }
    var description: String { media?.plainDescription ?? series?.description ?? "" }

    /// First not-completed episode, for the big "Riproduci" button.
    var nextToWatch: EpisodeDTO? {
        let watchedOnAniList = Double(entry?.progress ?? 0)
        return episodes.first { !$0.completed && $0.number > watchedOnAniList } ?? episodes.first { !$0.completed } ?? episodes.first
    }
}

struct TitleDetailView: View {
    let ref: TitleRef
    var inlinePlayer = false

    @Environment(AppSession.self) private var session
    @Environment(OfflineDownloads.self) private var offline
    @State private var model: TitleModel
    @State private var playing: PlaybackItem?
    @State private var inlineItem: PlaybackItem?
    @State private var showSources = false

    init(ref: TitleRef, inlinePlayer: Bool = false) {
        self.ref = ref
        self.inlinePlayer = inlinePlayer
        _model = State(initialValue: TitleModel(ref: ref))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                actions
                if let error = model.error { ErrorBanner(message: error) }
                if !model.description.isEmpty {
                    Text(model.description).font(.callout).foregroundStyle(.secondary).padding(.horizontal).lineLimit(6)
                }
                episodesSection
            }
            .padding(.bottom, 40)
        }
        .background(Theme.background)
        .navigationTitle(inlineItem == nil ? "" : model.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(session.api) }
        .refreshable { await model.load(session.api) }
        .fullScreenCover(item: $playing, onDismiss: { Task { await model.load(session.api) } }) { PlayerScreen(item: $0) }
        .sheet(isPresented: $showSources, onDismiss: { Task { await model.load(session.api) } }) {
            SourcesSheet(title: model.title, aniListId: ref.aniListId) { url, label in
                start(.direct(url, title: label))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { aniListMenu }
        }
    }

    // MARK: Header (banner or inline player)

    @ViewBuilder private var header: some View {
        if let inlineItem {
            InlinePlayer(item: inlineItem) { self.inlineItem = nil; Task { await model.load(session.api) } }
                .aspectRatio(16 / 9, contentMode: .fit)
                .id(inlineItem.id)
        } else {
            Color.clear
                .frame(maxWidth: .infinity).frame(height: inlinePlayer ? 180 : 260)
                .overlay { RemoteImage(url: model.media.flatMap { ($0.bannerUrl ?? $0.coverUrl).flatMap(URL.init(string:)) } ?? ref.bannerURL) }
                .overlay(LinearGradient(colors: [.clear, Theme.background], startPoint: .center, endPoint: .bottom))
                .clipped()
                .overlay(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 14) {
                    RemoteImage(url: model.media?.coverUrl.flatMap(URL.init(string:)) ?? ref.posterURL)
                        .frame(width: 96, height: 144).clipShape(.rect(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.title).font(.title2.bold()).lineLimit(3)
                        Text(metaLine).font(.caption).foregroundStyle(.secondary)
                        if let e = model.entry {
                            Text("AniList: \(statusLabel(e.status)) · \(e.progress)/\(model.media?.episodes.map(String.init) ?? "?")")
                                .font(.caption.bold()).foregroundStyle(Theme.accent)
                        }
                    }
                }
                .padding(.horizontal)
                .offset(y: 40)
                }
                .padding(.bottom, 40)
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let y = model.media?.year ?? model.series?.year { parts.append(String(y)) }
        if let f = model.media?.format { parts.append(f) }
        if let n = model.media?.episodes ?? model.series?.totalEpisodes { parts.append("\(n) episodi") }
        if let s = model.media?.averageScore { parts.append("★ \(s)%") }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 12) {
            if let next = model.nextToWatch {
                Button { play(next) } label: {
                    Label(next.positionSeconds ?? 0 > 5 && !next.completed ? "Riprendi E\(next.numberLabel)" : "Riproduci E\(next.numberLabel)",
                          systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black).controlSize(.large)
            }
            Button { showSources = true } label: {
                Label(model.episodes.isEmpty ? "Trova episodi" : "Altri episodi", systemImage: "plus.magnifyingglass")
                    .frame(maxWidth: model.episodes.isEmpty ? .infinity : nil)
            }
            .buttonStyle(.bordered).controlSize(.large)
        }
        .padding(.horizontal)
    }

    private var aniListMenu: some View {
        Menu {
            if let id = ref.aniListId, session.user?.aniListConnected == true {
                ForEach(["CURRENT", "PLANNING", "COMPLETED", "PAUSED", "DROPPED"], id: \.self) { s in
                    Button(statusLabel(s)) { Task { try? await session.api.aniListSetStatus(id, status: s); await model.load(session.api) } }
                }
            } else {
                Text("Collega AniList dal Profilo")
            }
        } label: { Image(systemName: model.entry == nil ? "bookmark" : "bookmark.fill") }
    }

    private func statusLabel(_ s: String) -> String {
        ["CURRENT": "Sto guardando", "PLANNING": "Da vedere", "COMPLETED": "Completato", "PAUSED": "In pausa",
         "DROPPED": "Abbandonato", "REPEATING": "Rewatch"][s] ?? s
    }

    // MARK: Episodes

    @ViewBuilder private var episodesSection: some View {
        if model.loading && model.episodes.isEmpty {
            ProgressView().frame(maxWidth: .infinity)
        } else if model.episodes.isEmpty {
            ContentUnavailableView {
                Label("Non ancora sul NAS", systemImage: "externaldrive.badge.plus")
            } description: {
                Text("Cerca una fonte e manda il download al NAS, oppure guardalo subito in streaming.")
            } actions: {
                Button("Trova episodi") { showSources = true }.buttonStyle(.borderedProminent)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Episodi").font(.title3.bold())
                    Spacer()
                    if let series = model.series {
                        Menu {
                            Button("Scarica tutti sul dispositivo", systemImage: "arrow.down.to.line") {
                                Task { for e in model.episodes { await offline.download(e, of: series, api: session.api) } }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
                .padding(.horizontal)
                ForEach(model.episodes) { ep in
                    EpisodeRow(episode: ep, series: model.series, watchedOnAniList: Double(model.entry?.progress ?? 0) >= ep.number) {
                        play(ep)
                    }
                    Divider().padding(.leading)
                }
            }
        }
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
    let play: () -> Void
    @Environment(AppSession.self) private var session
    @Environment(OfflineDownloads.self) private var offline

    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                HStack(spacing: 12) {
                    ZStack {
                        RemoteImage(url: series.flatMap { ($0.bannerUrl ?? $0.posterUrl).flatMap(URL.init(string:)) })
                            .frame(width: 128, height: 72)
                        Image(systemName: "play.fill").foregroundStyle(.white)
                    }
                    .overlay(alignment: .bottom) { if let p = episode.progressFraction { ProgressLine(value: episode.completed ? 1 : p) } }
                    .clipShape(.rect(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(episode.numberLabel). \(episode.title ?? "Episodio")").font(.subheadline.bold()).lineLimit(2)
                        HStack(spacing: 6) {
                            if let d = episode.durationSeconds { Text(d.durationLabel) }
                            Text(episode.sizeBytes.fileSize)
                            Text(episode.source.capitalized)
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                        if episode.completed || watchedOnAniList {
                            Label("Visto", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            deviceDownloadButton
        }
        .padding(.horizontal).padding(.vertical, 6)
    }

    @ViewBuilder private var deviceDownloadButton: some View {
        if offline.isDownloaded(episode.id) {
            Menu {
                Button("Rimuovi dal dispositivo", systemImage: "trash", role: .destructive) { offline.delete(episode.id) }
            } label: { Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Theme.accent) }
        } else if let p = offline.inFlight[episode.id] {
            Button { offline.cancel(episode.id) } label: {
                Gauge(value: p) { EmptyView() }.gaugeStyle(.accessoryCircularCapacity).scaleEffect(0.5).frame(width: 30, height: 30)
            }
        } else if let series {
            Button { Task { await offline.download(episode, of: series, api: session.api) } } label: {
                Image(systemName: "arrow.down.circle").font(.title3)
            }
            .accessibilityLabel("Scarica sul dispositivo")
        }
    }
}
