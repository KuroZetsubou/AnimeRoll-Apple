import AnimeRollKit
import SwiftUI

private let posterColumns = Array(repeating: GridItem(.fixed(260), spacing: 48), count: 6)

// MARK: - Cerca

struct TVSearchView: View {
    @Environment(AppSession.self) private var session
    @State private var query = ""
    @State private var nas: [SeriesDTO] = []
    @State private var results: [AniListMedia] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if query.count < 2 {
                    Text("Cerca nella libreria e su AniList").font(DS.body(28)).foregroundStyle(DS.textTertiary)
                }
                LazyVGrid(columns: posterColumns, spacing: 60) {
                    ForEach(nas) { s in
                        NavigationLink(value: TitleRef.series(s)) {
                            TVPoster(title: s.title, url: s.posterUrl.flatMap(URL.init(string:)), badge: "NAS", meta: s.year.map(String.init))
                        }
                        .buttonStyle(.borderless)
                    }
                    ForEach(results.filter { r in !nas.contains { $0.aniListId == r.id } }) { m in
                        NavigationLink(value: TitleRef.aniList(m)) {
                            TVPoster(title: m.title, url: m.coverUrl.flatMap(URL.init(string:)), badge: "AniList", meta: m.year.map(String.init))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding(60)
        }
        .background(DS.background)
        .searchable(text: $query, prompt: "Titolo anime")
        .task(id: query) {
            guard query.count >= 2 else { results = []; nas = []; return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            async let n = try? session.api.library(query: query)
            async let r = try? session.api.aniListSearch(query)
            let (nn, rr) = await (n, r)
            nas = nn ?? []; results = rr ?? results
        }
        .navigationDestination(for: TitleRef.self) { TVTitleView(ref: $0) }
    }
}

// MARK: - Libreria

struct TVLibraryView: View {
    @Environment(AppSession.self) private var session
    @State private var series: [SeriesDTO] = []
    @State private var loaded = false
    @State private var info: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack {
                    TVScreenTitle(text: "Libreria", subtitle: "\(series.count) serie sul NAS")
                    Spacer()
                    Button { Task { await importInbox() } } label: { Label("Importa", systemImage: "tray.and.arrow.down") }
                }
                if let info { Text(info).font(DS.body(24)).foregroundStyle(DS.accent) }
                if loaded && series.isEmpty {
                    Text("Scarica qualcosa sul NAS o metti i file in /media/_inbox e premi Importa")
                        .font(DS.body(28)).foregroundStyle(DS.textTertiary).frame(maxWidth: .infinity).padding(.top, 80)
                }
                LazyVGrid(columns: posterColumns, spacing: 60) {
                    ForEach(series.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }) { s in
                        NavigationLink(value: TitleRef.series(s)) {
                            TVPoster(title: s.title, url: s.posterUrl.flatMap(URL.init(string:)),
                                     meta: "\(s.episodeCount)\(s.totalEpisodes.map { "/\($0)" } ?? "") ep")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding(60)
        }
        .background(DS.background)
        .navigationDestination(for: TitleRef.self) { TVTitleView(ref: $0) }
        .task { await load() }
    }

    private func load() async { series = (try? await session.api.library()) ?? series; loaded = true }

    private func importInbox() async {
        do { let n = try await session.api.scanInbox(); info = "Importati \(n) episodi da _inbox"; await load() }
        catch { info = error.localizedDescription }
    }
}

// MARK: - Download

struct TVDownloadsView: View {
    @Environment(AppSession.self) private var session
    @Environment(OfflineDownloads.self) private var offline
    @State private var jobs: [DownloadJob] = []
    @State private var scope = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                TVScreenTitle(text: "Download")
                Picker("", selection: $scope) { Text("Sul NAS").tag(0); Text("Su questa Apple TV").tag(1) }
                    .pickerStyle(.segmented).frame(maxWidth: 800)
                if scope == 0 { nas } else { device }
            }
            .padding(60).frame(maxWidth: 1400, alignment: .leading)
        }
        .background(DS.background)
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(jobs.contains { $0.status.isActive } ? 3 : 15))
            }
        }
    }

    @ViewBuilder private var nas: some View {
        if jobs.isEmpty {
            Text("Dalla pagina di un anime scegli Trova episodi per scaricare sul NAS").font(DS.body(28)).foregroundStyle(DS.textTertiary).padding(.top, 40)
        } else {
            HStack(spacing: 20) {
                if jobs.contains(where: { $0.status == .paused }) {
                    Button { act { try await session.api.resumeAllNASDownloads() } } label: { Label("Riprendi tutto", systemImage: "play.fill") }
                } else {
                    Button { act { try await session.api.pauseAllNASDownloads() } } label: { Label("Pausa tutto", systemImage: "pause.fill") }
                }
                Button { act { try await session.api.clearFinishedNASDownloads() } } label: { Label("Pulisci", systemImage: "trash") }
            }
            ForEach(jobs) { job in card(job) }
        }
    }

    private func color(_ s: DownloadStatus) -> Color {
        switch s {
        case .running: DS.accent
        case .postProcessing: DS.teal
        case .completed: DS.green
        case .failed: DS.pink
        case .paused: DS.yellow
        default: DS.textTertiary
        }
    }

    private func card(_ job: DownloadJob) -> some View {
        // Select = the most useful action; long-press (menu) = every queue action.
        Button { primary(job) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.seriesTitle).font(DS.body(30, 700))
                        Text([job.episodeNumber.map { "Episodio \($0.formatted())" }, job.sourceLabel, job.priorityLabel].compactMap { $0 }.joined(separator: " · "))
                            .font(DS.body(22)).foregroundStyle(DS.textTertiary)
                    }
                    Spacer()
                    Text(job.status.label + (job.status == .running ? " \(Int(job.progress * 100))%" : "")).font(DS.body(24, 700)).foregroundStyle(color(job.status))
                }
                if job.status.isRunning || job.status == .paused { ProgressView(value: job.progress).tint(DS.accent) }
                if let m = job.message, !m.isEmpty { Text(m).font(DS.body(22)).foregroundStyle(job.status == .failed ? DS.pink : DS.textSecondary) }
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.card)
        .contextMenu {
            if job.status == .queued || job.status == .paused { Button("Avvia subito") { act { try await session.api.startNASDownloadNow(job.id) } } }
            if job.status.canPause { Button("Metti in pausa") { act { try await session.api.pauseNASDownload(job.id) } } }
            if job.status.canResume { Button("Riprendi") { act { try await session.api.resumeNASDownload(job.id) } } }
            if job.status.isActive || job.status == .paused {
                ForEach(DownloadPriority.allCases.reversed()) { p in
                    Button("Priorità \(p.label.lowercased())") { act { try await session.api.setNASDownloadPriority(job.id, p) } }
                }
            }
            if job.status.canRetry { Button("Riprova") { act { try await session.api.retryNASDownload(job.id) } } }
            if job.status.canCancel { Button("Annulla", role: .destructive) { act { try await session.api.cancelNASDownload(job.id) } } }
        }
    }

    @ViewBuilder private var device: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(offline.items.count) episodi offline · \(offline.totalBytes.fileSize) usati").font(DS.body(26, 600))
            Text("I download su Apple TV stanno nella cache di sistema, che tvOS può svuotare se serve spazio.").font(DS.body(22)).foregroundStyle(DS.textTertiary)
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading).background(DS.surface, in: .rect(cornerRadius: DS.rCard))
        ForEach(offline.items) { item in
            Text("\(item.series.title) · E\(item.episode.numberLabel)").font(DS.body(28)).padding(24)
                .frame(maxWidth: .infinity, alignment: .leading).background(DS.surface, in: .rect(cornerRadius: DS.rCard))
                .focusable()
                .contextMenu { Button("Elimina", role: .destructive) { offline.delete(item.episode.id) } }
        }
        ForEach(Array(offline.inFlight.keys), id: \.self) { id in
            ProgressView(value: offline.inFlight[id] ?? 0) { Text("Scaricamento episodio #\(id)").font(DS.body(24)) }.tint(DS.accent)
        }
    }

    private func load() async { jobs = (try? await session.api.nasDownloads()) ?? jobs }

    private func act(_ work: @escaping () async throws -> Void) {
        Task { try? await work(); await load() }
    }

    private func primary(_ job: DownloadJob) {
        if job.status.canPause { act { try await session.api.pauseNASDownload(job.id) } }
        else if job.status.canResume { act { try await session.api.resumeNASDownload(job.id) } }
        else if job.status.canRetry { act { try await session.api.retryNASDownload(job.id) } }
    }
}

// MARK: - Profilo

struct TVSettingsView: View {
    @Environment(AppSession.self) private var session
    @State private var queue: QueueSettings?
    @State private var passkeys: [PasskeyInfo] = []
    @State private var storage: StorageInfo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                TVScreenTitle(text: "Profilo")
                if let u = session.user {
                    TVGroup(title: "Account") {
                        TVRow(icon: "person", label: "Utente", value: u.username)
                        TVRow(icon: "server.rack", label: "Server", value: session.api.baseURL.host() ?? "")
                    }
                    TVGroup(title: "AniList", note: "Oltre l'85% di un episodio il server aggiorna AniList. Su Apple TV lo colleghi dall'app iPhone.") {
                        TVRow(icon: "link", label: u.aniListConnected ? "Collegato come \(u.aniListUserName ?? "AniList")" : "Non collegato")
                    }
                    TVGroup(title: "Passkey") {
                        if passkeys.isEmpty { TVRow(icon: "key", label: "Nessuna passkey", value: "\(u.passkeyCount)") }
                        ForEach(passkeys) { p in
                            TVRow(icon: "key", label: p.name, value: p.lastUsedAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "mai usata")
                        }
                    }
                    if let st = storage {
                        TVGroup(title: "Spazio sul NAS", note: "Sotto la riserva il NAS rifiuta nuovi download e import. Per liberare spazio elimina episodi dalla pagina del titolo.") {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Text("\(st.freeBytes.fileSize) liberi").font(DS.display(34, 700)).foregroundStyle(st.freeBytes < st.reserveBytes * 2 ? DS.pink : .white)
                                    Spacer()
                                    Text("su \(st.totalBytes.fileSize)").font(DS.body(24)).foregroundStyle(DS.textTertiary)
                                }
                                ProgressView(value: st.totalBytes > 0 ? min(1, Double(st.usedBytes) / Double(st.totalBytes)) : 0).tint(st.freeBytes < st.reserveBytes * 2 ? DS.pink : DS.accent)
                                HStack {
                                    Text("Libreria \(st.libraryBytes.fileSize)").font(DS.body(22)).foregroundStyle(DS.textSecondary)
                                    Spacer()
                                    Text("Riserva \(st.reserveBytes.fileSize)").font(DS.body(22)).foregroundStyle(DS.textTertiary)
                                }
                            }
                            .padding(28)
                        }
                    }
                    if let queue {
                        TVGroup(title: "Download sul NAS", note: "Quanti lavori il NAS esegue insieme.") {
                            Picker("Download contemporanei", selection: Binding(
                                get: { queue.maxConcurrentDownloads },
                                set: { v in Task { self.queue = (try? await session.api.setQueueSettings(QueueSettings(maxConcurrentDownloads: v))) ?? self.queue } })) {
                                ForEach(Array(QueueSettings.range), id: \.self) { Text("\($0)").tag($0) }
                            }
                            .padding(.horizontal, 28).frame(minHeight: 84)
                        }
                    }
                }
                Button(role: .destructive) { session.logout() } label: { Label("Esci", systemImage: "rectangle.portrait.and.arrow.right") }
            }
            .padding(60).frame(maxWidth: 1100, alignment: .leading)
        }
        .background(DS.background)
        .task {
            queue = try? await session.api.queueSettings()
            storage = try? await session.api.storageInfo()
            passkeys = (try? await session.api.passkeys()) ?? []
        }
    }
}

// MARK: - Esplora

/// Esplora: AniList titles by season and genre.
struct TVExploreView: View {
    @Environment(AppSession.self) private var session
    private static let seasons: [(String, String)] = [("Inverno", "WINTER"), ("Primavera", "SPRING"), ("Estate", "SUMMER"), ("Autunno", "FALL")]
    private static let genres = ["Action", "Adventure", "Comedy", "Drama", "Fantasy", "Horror", "Mecha", "Music", "Mystery", "Romance", "Sci-Fi", "Slice of Life", "Sports", "Supernatural"]
    @State private var season = (Calendar.current.component(.month, from: .now) - 1) / 3
    @State private var year = Calendar.current.component(.year, from: .now)
    @State private var genre: String?
    @State private var items: [AniListMedia]?
    @State private var error: String?
    @State private var nasIds = Set<Int>()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                TVScreenTitle(text: "Esplora", subtitle: "Stagioni da AniList")
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        ForEach(Self.seasons.indices, id: \.self) { i in TVChip(title: Self.seasons[i].0, selected: i == season) { season = i } }
                        Divider().frame(height: 50)
                        ForEach([year + 1, year, year - 1, year - 2].uniqued(), id: \.self) { y in TVChip(title: String(y), selected: y == year) { year = y } }
                    }
                    .padding(.vertical, 8)
                }
                .scrollClipDisabled()
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        TVChip(title: "Tutti", selected: genre == nil) { genre = nil }
                        ForEach(Self.genres, id: \.self) { g in TVChip(title: g, selected: genre == g) { genre = g } }
                    }
                    .padding(.vertical, 8)
                }
                .scrollClipDisabled()
                HStack {
                    Text("\(Self.seasons[season].0) \(String(year))").font(DS.display(40, 700))
                    Spacer()
                    if let items { Text("\(items.count) titoli").font(DS.body(24)).foregroundStyle(DS.textTertiary) }
                }
                .padding(.top, 12)
                if let error { Text(error).font(DS.body(24)).foregroundStyle(DS.pink) }
                if items == nil && error == nil { ProgressView().frame(maxWidth: .infinity) }
                LazyVGrid(columns: posterColumns, spacing: 60) {
                    ForEach(items ?? []) { m in
                        NavigationLink(value: TitleRef.aniList(m)) {
                            TVPoster(title: m.title, url: m.coverUrl.flatMap(URL.init(string:)), badge: nasIds.contains(m.id) ? "NAS" : nil,
                                     meta: m.genres.prefix(2).joined(separator: " · "))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding(60)
        }
        .background(DS.background)
        .navigationDestination(for: TitleRef.self) { TVTitleView(ref: $0) }
        .task { nasIds = Set(((try? await session.api.library()) ?? []).compactMap(\.aniListId)) }
        .task(id: "\(season)-\(year)-\(genre ?? "")") {
            items = nil; error = nil
            do { items = try await session.api.aniListBrowse(season: Self.seasons[season].1, year: year, genre: genre) }
            catch APIError.http(404, _) { error = "Esplora richiede la nuova versione del server: aggiorna AnimeRoll sul NAS."; items = [] }
            catch { self.error = error.localizedDescription; items = [] }
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}
