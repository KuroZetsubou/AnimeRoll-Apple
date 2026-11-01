import AnimeRollKit
import SwiftUI

struct TVSearchView: View {
    @Environment(AppSession.self) private var session
    @State private var query = ""
    @State private var results: [AniListMedia] = []

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(260), spacing: 48), count: 6), spacing: 60) {
                ForEach(results) { m in
                    NavigationLink(value: TitleRef.aniList(m)) { TVPoster(title: m.title, url: m.coverUrl.flatMap(URL.init(string:))) }
                        .buttonStyle(.borderless)
                }
            }
            .padding(60)
        }
        .searchable(text: $query, prompt: "Titolo anime")
        .task(id: query) {
            guard query.count >= 2 else { results = []; return }
            try? await Task.sleep(for: .milliseconds(400))
            results = (try? await session.api.aniListSearch(query)) ?? results
        }
        .navigationDestination(for: TitleRef.self) { TVTitleView(ref: $0) }
    }
}

struct TVLibraryView: View {
    @Environment(AppSession.self) private var session
    @State private var series: [SeriesDTO] = []

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(260), spacing: 48), count: 6), spacing: 60) {
                ForEach(series) { s in
                    NavigationLink(value: TitleRef.series(s)) {
                        TVPoster(title: s.title, url: s.posterUrl.flatMap(URL.init(string:)), badge: "\(s.episodeCount)")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(60)
        }
        .overlay { if series.isEmpty { ContentUnavailableView("Libreria vuota", systemImage: "externaldrive") } }
        .navigationDestination(for: TitleRef.self) { TVTitleView(ref: $0) }
        .task { series = (try? await session.api.library()) ?? [] }
    }
}

struct TVDownloadsView: View {
    @Environment(AppSession.self) private var session
    @Environment(OfflineDownloads.self) private var offline
    @State private var jobs: [DownloadJob] = []

    var body: some View {
        List {
            Section("Sul NAS") {
                if jobs.isEmpty { Text("Nessun download").foregroundStyle(.secondary) }
                ForEach(jobs) { job in
                    // Select = the most useful action; long-press (menu) = every queue action.
                    Button { primary(job) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(job.seriesTitle)\(job.episodeNumber.map { " · E\($0.formatted())" } ?? "") — \(job.sourceLabel)\(job.priorityLabel.map { " · \($0)" } ?? "")")
                            if job.status.isRunning || job.status == .paused { ProgressView(value: job.progress) }
                            Text("\(job.status.label)\(job.message.map { " · \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        if job.status == .queued || job.status == .paused {
                            Button("Avvia subito") { act { try await session.api.startNASDownloadNow(job.id) } }
                        }
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
                if jobs.contains(where: { $0.status.isActive || $0.status == .paused }) {
                    Button("Metti tutto in pausa") { act { try await session.api.pauseAllNASDownloads() } }
                    Button("Riprendi tutto") { act { try await session.api.resumeAllNASDownloads() } }
                }
            }
            Section("Su questa Apple TV (\(offline.totalBytes.formatted(.byteCount(style: .file))))") {
                ForEach(offline.items) { item in
                    Text("\(item.series.title) · E\(item.episode.numberLabel)")
                        .contextMenu { Button("Elimina", role: .destructive) { offline.delete(item.episode.id) } }
                }
                ForEach(Array(offline.inFlight.keys), id: \.self) { id in
                    ProgressView(value: offline.inFlight[id] ?? 0) { Text("Episodio #\(id)") }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(jobs.contains { $0.status.isActive } ? 3 : 15))
            }
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


struct TVSettingsView: View {
    @Environment(AppSession.self) private var session
    @State private var queue: QueueSettings?

    var body: some View {
        List {
            if let u = session.user {
                LabeledContent("Utente", value: u.username)
                LabeledContent("Server", value: session.api.baseURL.host() ?? "")
                LabeledContent("AniList", value: u.aniListConnected ? (u.aniListUserName ?? "Collegato") : "Collegalo dall'app iPhone")
                LabeledContent("Passkey", value: "\(u.passkeyCount)")
            }
            if let queue {
                Picker("Download contemporanei sul NAS", selection: Binding(
                    get: { queue.maxConcurrentDownloads },
                    set: { v in Task { self.queue = (try? await session.api.setQueueSettings(QueueSettings(maxConcurrentDownloads: v))) ?? self.queue } })) {
                    ForEach(Array(QueueSettings.range), id: \.self) { Text("\($0)").tag($0) }
                }
            }
            Button("Esci", role: .destructive) { session.logout() }
        }
        .task { queue = try? await session.api.queueSettings() }
    }
}

/// Esplora: AniList titles by season, with a genre row.
struct TVExploreView: View {
    @Environment(AppSession.self) private var session
    private static let seasons: [(String, String)] = [("Inverno", "WINTER"), ("Primavera", "SPRING"), ("Estate", "SUMMER"), ("Autunno", "FALL")]
    private static let genres = ["Action", "Adventure", "Comedy", "Drama", "Fantasy", "Horror", "Mecha", "Music", "Mystery", "Romance", "Sci-Fi", "Slice of Life", "Sports", "Supernatural"]
    @State private var season = (Calendar.current.component(.month, from: .now) - 1) / 3
    @State private var year = Calendar.current.component(.year, from: .now)
    @State private var genre: String?
    @State private var items: [AniListMedia] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Esplora").font(DS.display(56, 800))
                ScrollView(.horizontal) {
                    HStack(spacing: 20) {
                        ForEach(Self.seasons.indices, id: \.self) { i in
                            Button(Self.seasons[i].0) { season = i }.tint(i == season ? DS.accent : nil)
                        }
                        Divider().frame(height: 50)
                        ForEach([year + 1, year, year - 1, year - 2], id: \.self) { y in
                            Button(String(y)) { year = y }
                        }
                    }
                    .padding(.vertical, 20)
                }
                .scrollClipDisabled()
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        Button("Tutti") { genre = nil }.tint(genre == nil ? DS.accent : nil)
                        ForEach(Self.genres, id: \.self) { g in Button(g) { genre = g }.tint(genre == g ? DS.accent : nil) }
                    }
                    .padding(.vertical, 20)
                }
                .scrollClipDisabled()
                Text("\(Self.seasons[season].0) \(String(year)) · \(items.count) titoli").font(DS.display(34, 700))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(260), spacing: 48), count: 6), spacing: 60) {
                    ForEach(items) { m in
                        NavigationLink(value: TitleRef.aniList(m)) {
                            TVPoster(title: m.title, url: m.coverUrl.flatMap(URL.init(string:)))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding(60)
        }
        .navigationDestination(for: TitleRef.self) { TVTitleView(ref: $0) }
        .task(id: "\(season)-\(year)-\(genre ?? "")") {
            items = (try? await session.api.aniListBrowse(season: Self.seasons[season].1, year: year, genre: genre)) ?? []
        }
    }
}
