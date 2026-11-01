import AnimeRollKit
import SwiftUI

/// Esplora: AniList titles by season and genre.
struct ExploreView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openTitle) private var openTitle
    @Environment(\.horizontalSizeClass) private var hSize

    private static let seasons: [(name: String, key: String)] = [("Inverno", "WINTER"), ("Primavera", "SPRING"), ("Estate", "SUMMER"), ("Autunno", "FALL")]
    private static let genres = ["Action", "Adventure", "Comedy", "Drama", "Fantasy", "Horror", "Mecha", "Music", "Mystery",
                                 "Psychological", "Romance", "Sci-Fi", "Slice of Life", "Sports", "Supernatural", "Thriller"]

    @State private var season = (Calendar.current.component(.month, from: .now) - 1) / 3   // 0 Inverno … 3 Autunno
    @State private var year = Calendar.current.component(.year, from: .now)
    @State private var genre: String?
    @State private var items: [AniListMedia]?
    @State private var error: String?
    @State private var picker = false
    @State private var nasIds: Set<Int> = []

    private let nowSeason = (Calendar.current.component(.month, from: .now) - 1) / 3
    private let nowYear = Calendar.current.component(.year, from: .now)
    private let grid = [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 12)]
    private var label: String { "\(Self.seasons[season].name) \(year)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenTitle("Esplora")
                Text("Stagioni da AniList").font(DS.body(13)).foregroundStyle(DS.textTertiary).padding(.top, 4)
                Button { picker = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar").foregroundStyle(DS.accent)
                        Text(label).font(DS.display(18, 700))
                        Spacer()
                        if season == nowSeason && year == nowYear { BadgeLabel(text: "In corso", tint: DS.teal) }
                        Image(systemName: "chevron.down").foregroundStyle(DS.textSecondary)
                    }
                    .padding(.horizontal, 18).frame(height: 52).frame(maxWidth: 360)
                    .background(DS.surface, in: .capsule).overlay(Capsule().strokeBorder(DS.borderStrong))
                }
                .buttonStyle(.plain).padding(.top, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Chip(title: "Tutti", selected: genre == nil) { genre = nil }
                        ForEach(Self.genres, id: \.self) { g in Chip(title: g, selected: genre == g) { genre = g } }
                    }
                }
                .padding(.top, 12)
                HStack(alignment: .firstTextBaseline) {
                    Text(label).font(DS.display(22, 700))
                    Spacer()
                    if let items { Text("\(items.count) titoli").font(DS.body(13)).foregroundStyle(DS.textTertiary) }
                }
                .padding(.top, 24).padding(.bottom, 12)

                if let error { ErrorBanner(message: error).padding(.horizontal, -16) }
                if items == nil && error == nil { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
                if let items, items.isEmpty, error == nil {
                    ContentUnavailableView("Nessun titolo", systemImage: "calendar.badge.exclamationmark",
                                           description: Text("Nessun titolo di questa stagione" + (genre.map { " per “\($0)”" } ?? "")))
                }
                LazyVGrid(columns: grid, alignment: .leading, spacing: 18) {
                    ForEach(items ?? []) { m in
                        Button { openTitle(.aniList(m)) } label: {
                            PosterCard(title: m.title, url: m.coverUrl.flatMap(URL.init(string:)), badge: nasIds.contains(m.id) ? "NAS" : nil,
                                       meta: m.genres.prefix(2).joined(separator: " · "), width: 104)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal).padding(.top, 8).padding(.bottom, 120)
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .task { nasIds = Set(((try? await session.api.library()) ?? []).compactMap(\.aniListId)) }
        .task(id: "\(season)-\(year)-\(genre ?? "")") {
            items = nil; error = nil
            do { items = try await session.api.aniListBrowse(season: Self.seasons[season].key, year: year, genre: genre) }
            catch APIError.http(404, _) { self.error = "Esplora richiede la nuova versione del server: aggiorna AnimeRoll sul NAS."; items = [] }
            catch { self.error = error.localizedDescription; items = [] }
        }
        .sheet(isPresented: $picker) {
            SeasonPicker(season: season, year: year) { season = $0; year = $1; picker = false }
                .presentationDetents(hSize == .compact ? [.large] : [.medium])
                .presentationBackground(DS.background)
        }
    }

    private struct SeasonPicker: View {
        @State var season: Int
        @State var year: Int
        let apply: (Int, Int) -> Void
        init(season: Int, year: Int, apply: @escaping (Int, Int) -> Void) { _season = State(initialValue: season); _year = State(initialValue: year); self.apply = apply }
        private var years: [Int] { let y = Calendar.current.component(.year, from: .now); return Array((y - 4...y + 1).reversed()) }

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Scegli stagione").font(DS.display(28, 800)).padding(.top, 24)
                HStack(alignment: .top, spacing: 12) {
                    column("Stagione", ExploreView.seasons.indices.map { ($0, ExploreView.seasons[$0].name) }, selected: season) { season = $0 }
                    column("Anno", years.map { ($0, "\($0)") }, selected: year) { year = $0 }
                }
                Spacer()
                Button { apply(season, year) } label: { Text("Mostra \(ExploreView.seasons[season].name) \(String(year))") }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }

        private func column(_ title: String, _ options: [(Int, String)], selected: Int, pick: @escaping (Int) -> Void) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased()).font(DS.body(12, 700)).tracking(1).foregroundStyle(DS.textTertiary).padding(.leading, 4)
                ForEach(options, id: \.0) { id, name in
                    let on = id == selected
                    Button { Haptics.tick(); pick(id) } label: {
                        HStack { Text(name).font(DS.body(16, 600)); Spacer(); if on { Image(systemName: "checkmark") } }
                            .foregroundStyle(on ? DS.accent : .white).padding(.horizontal, 16).frame(height: 52)
                            .background(on ? DS.accentSoft : DS.surface, in: .rect(cornerRadius: DS.rCard))
                            .overlay(RoundedRectangle(cornerRadius: DS.rCard).strokeBorder(on ? DS.accent : DS.hairline))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}
