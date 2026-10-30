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
                    Button {
                        Task {
                            if job.status.isActive { try? await session.api.cancelNASDownload(job.id) }
                            else if job.status == .failed { try? await session.api.retryNASDownload(job.id) }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(job.seriesTitle)\(job.episodeNumber.map { " · E\($0.formatted())" } ?? "") — \(job.source.capitalized)")
                            if job.status.isActive { ProgressView(value: job.progress) }
                            Text("\(job.status.label)\(job.message.map { " · \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
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
                jobs = (try? await session.api.nasDownloads()) ?? jobs
                try? await Task.sleep(for: .seconds(jobs.contains { $0.status.isActive } ? 3 : 15))
            }
        }
    }
}

struct TVSettingsView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        List {
            if let u = session.user {
                LabeledContent("Utente", value: u.username)
                LabeledContent("Server", value: session.api.baseURL.host() ?? "")
                LabeledContent("AniList", value: u.aniListConnected ? (u.aniListUserName ?? "Collegato") : "Collegalo dall'app iPhone")
                LabeledContent("Passkey", value: "\(u.passkeyCount)")
            }
            Button("Esci", role: .destructive) { session.logout() }
        }
    }
}
