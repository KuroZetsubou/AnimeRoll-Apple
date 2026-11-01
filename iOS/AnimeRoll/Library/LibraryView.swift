import AnimeRollKit
import SwiftUI

/// Libreria: series on the NAS, a filter field and Importa (scans /media/_inbox).
struct LibraryView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openTitle) private var openTitle
    @State private var series: [SeriesDTO] = []
    @State private var filter = ""
    @State private var info: String?
    @State private var loaded = false

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 12, alignment: .top)]
    private var shown: [SeriesDTO] {
        series.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) || ($0.titleRomaji?.localizedCaseInsensitiveContains(filter) ?? false) }
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    ScreenTitle("Libreria")
                    Spacer()
                    Button { Task { await importInbox() } } label: { Label("Importa", systemImage: "tray.and.arrow.down") }
                        .buttonStyle(PrimaryButtonStyle(prominent: false, small: true))
                }
                SearchPill(text: $filter, placeholder: "Filtra la libreria")
                if let info { Text(info).font(DS.body(13)).foregroundStyle(DS.accent) }
                if loaded && shown.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder").font(.system(size: 36))
                        Text(filter.isEmpty ? "Scarica qualcosa sul NAS o metti i file in /media/_inbox e premi Importa"
                                            : "Nessuna serie per “\(filter)”")
                            .font(DS.body(15)).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(DS.textTertiary).frame(maxWidth: .infinity).padding(.vertical, 48)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(shown) { s in
                        Button { openTitle(.series(s)) } label: {
                            PosterCard(title: s.title, url: s.posterUrl.flatMap(URL.init(string:)),
                                       meta: [s.year.map(String.init), "\(s.episodeCount)\(s.totalEpisodes.map { "/\($0)" } ?? "") ep"].compactMap { $0 }.joined(separator: " · "),
                                       width: 104)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal).padding(.top, 8).padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await load() }
        .task { await load() }
    }

    private func importInbox() async {
        Haptics.tick()
        do { let n = try await session.api.scanInbox(); info = "Importati \(n) episodi da _inbox"; await load() }
        catch { info = error.localizedDescription }
    }

    private func load() async { series = (try? await session.api.library()) ?? series; loaded = true }
}

/// Rounded search / filter field.
struct SearchPill: View {
    @Binding var text: String
    var placeholder: String
    var focused: FocusState<Bool>.Binding? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(DS.textTertiary)
            field.font(DS.body(16)).autocorrectionDisabled().textInputAutocapitalization(.never).submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DS.textTertiary) }
                    .accessibilityLabel("Cancella")
            }
        }
        .padding(.horizontal, 16).frame(height: 48)
        .background(DS.surface, in: .capsule).overlay(Capsule().strokeBorder(DS.hairline))
    }

    @ViewBuilder private var field: some View {
        if let focused { TextField(placeholder, text: $text).focused(focused) } else { TextField(placeholder, text: $text) }
    }
}

/// Cerca: recent searches while empty, then a poster grid mixing the NAS (first) and AniList, as you type.
struct SearchView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openTitle) private var openTitle
    @Environment(\.dismiss) private var dismiss
    @AppStorage("recentSearches") private var recentRaw = ""
    @State private var query = ""
    @State private var nas: [SeriesDTO] = []
    @State private var results: [AniListMedia] = []
    @State private var searched = false
    @FocusState private var focused: Bool

    private let grid = [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 12, alignment: .top)]
    private var recents: [String] { recentRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    SearchPill(text: $query, placeholder: "Cerca titoli", focused: $focused)
                    Button("Annulla") { dismiss() }.font(DS.body(15, 600)).tint(DS.accent)
                }
                if query.count < 2 {
                    if !recents.isEmpty {
                        Text("Recenti").font(DS.display(17, 700)).padding(.top, 10)
                        ForEach(recents, id: \.self) { r in
                            Button { query = r } label: {
                                HStack(spacing: 12) { Image(systemName: "clock"); Text(r); Spacer() }
                                    .font(DS.body(15)).foregroundStyle(DS.textSecondary).frame(height: 44).contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("I risultati mescolano la libreria NAS e AniList.").font(DS.body(13)).foregroundStyle(DS.textTertiary).padding(.top, 8)
                } else {
                    LazyVGrid(columns: grid, alignment: .leading, spacing: 18) {
                        ForEach(nas) { s in
                            Button { openTitle(.series(s)) } label: {
                                PosterCard(title: s.title, url: s.posterUrl.flatMap(URL.init(string:)), badge: "NAS", meta: s.year.map(String.init), width: 100)
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(results.filter { r in !nas.contains { $0.aniListId == r.id } }) { m in
                            Button { openTitle(.aniList(m)) } label: {
                                PosterCard(title: m.title, url: m.coverUrl.flatMap(URL.init(string:)), badge: "AniList", meta: m.year.map(String.init), width: 100)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 6)
                    if searched && nas.isEmpty && results.isEmpty {
                        Text("Nessun risultato per “\(query)”").font(DS.body(15)).foregroundStyle(DS.textTertiary)
                            .frame(maxWidth: .infinity).padding(.top, 32)
                    }
                }
            }
            .padding(.horizontal).padding(.top, 8).padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { focused = true }
        .task(id: query) {
            searched = false
            guard query.count >= 2 else { results = []; nas = []; return }
            try? await Task.sleep(for: .milliseconds(300)) // debounce
            guard !Task.isCancelled else { return }
            async let n = try? session.api.library(query: query)
            async let r = try? session.api.aniListSearch(query)
            let (nn, rr) = await (n, r)
            nas = nn ?? []
            results = rr ?? results
            searched = true
            let q = query.trimmingCharacters(in: .whitespaces)
            recentRaw = ([q] + recents.filter { $0 != q }).prefix(6).joined(separator: "\n")
        }
    }
}
