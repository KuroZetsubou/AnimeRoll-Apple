import AnimeRollKit
import SwiftUI

/// Everything already on the NAS.
struct LibraryView: View {
    @Environment(AppSession.self) private var session
    @State private var series: [SeriesDTO] = []
    @State private var filter = ""
    @State private var info: String?

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 170), spacing: 12)]

    var body: some View {
        ScrollView {
            if let info { Text(info).font(.footnote).foregroundStyle(.secondary).padding(.top) }
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(series.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }) { s in
                    NavigationLink(value: TitleRef.series(s)) {
                        PosterCard(title: s.title, url: s.posterUrl.flatMap(URL.init(string:)), badge: "\(s.episodeCount)", width: 110)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .overlay {
            if series.isEmpty {
                ContentUnavailableView("Libreria vuota", systemImage: "externaldrive",
                                       description: Text("Scarica qualcosa sul NAS o metti i file in /media/_inbox e premi Importa."))
            }
        }
        .background(Theme.background)
        .navigationTitle("Libreria")
        .searchable(text: $filter, prompt: "Filtra")
        .navigationDestination(for: TitleRef.self) { TitleDetailView(ref: $0) }
        .toolbar {
            Button("Importa", systemImage: "tray.and.arrow.down") {
                Task {
                    let n = (try? await session.api.scanInbox()) ?? 0
                    info = "Importati \(n) episodi da _inbox"
                    await load()
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async { series = (try? await session.api.library()) ?? series }
}

/// AniList search → title page (which shows NAS episodes or lets you find sources).
struct SearchView: View {
    @Environment(AppSession.self) private var session
    @State private var query = ""
    @State private var results: [AniListMedia] = []

    var body: some View {
        List(results) { m in
            NavigationLink(value: TitleRef.aniList(m)) {
                HStack(spacing: 12) {
                    RemoteImage(url: m.coverUrl.flatMap(URL.init(string:))).frame(width: 50, height: 74).clipShape(.rect(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.title).font(.subheadline.bold())
                        Text([m.year.map(String.init), m.format, m.episodes.map { "\($0) ep" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Cerca")
        .searchable(text: $query, prompt: "Titolo anime")
        .task(id: query) {
            guard query.count >= 2 else { results = []; return }
            try? await Task.sleep(for: .milliseconds(350)) // debounce
            results = (try? await session.api.aniListSearch(query)) ?? results
        }
        .navigationDestination(for: TitleRef.self) { TitleDetailView(ref: $0) }
    }
}
