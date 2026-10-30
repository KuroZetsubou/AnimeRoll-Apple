import AnimeRollKit
import SwiftUI

/// Find a title on a source (StreamSite, Torrent, Telegram, plugins) and
/// send the download command to the NAS — or stream it right away (StreamSite).
struct SourcesSheet: View {
    let title: String
    let aniListId: Int?
    /// Direct streaming without downloading.
    var onStream: ((URL, String) -> Void)? = nil

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var providers: [ProviderInfo] = []
    @State private var provider: ProviderInfo?
    @State private var query = ""
    @State private var results: [SourceSearchResult] = []
    @State private var searching = false
    @State private var error: String?
    @State private var manualRef = ""
    @State private var manualEpisode = ""
    @State private var sentMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Fonte", selection: $provider) {
                        ForEach(providers.filter(\.enabled)) { Text($0.name).tag(Optional($0)) }
                    }
                    if let hint = provider?.hint { Text(hint).font(.footnote).foregroundStyle(.secondary) }
                }

                if let provider, !provider.canSearch {
                    // Download-only sources (plugins): paste a link or reference.
                    Section("Link o riferimento") {
                        TextField("https://…", text: $manualRef)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Numero episodio (facoltativo)", text: $manualEpisode).keyboardType(.decimalPad)
                        Button("Scarica sul NAS", systemImage: "externaldrive.badge.plus") {
                            send(source: provider.id, items: [DownloadItem(sourceRef: manualRef.trimmingCharacters(in: .whitespaces),
                                                                          episodeNumber: Double(manualEpisode.replacingOccurrences(of: ",", with: ".")))])
                        }
                        .disabled(!refIsValid(provider))
                    }
                } else {
                    Section {
                        HStack {
                            TextField("Cerca", text: $query).onSubmit { Task { await search() } }
                            if searching { ProgressView() }
                        }
                    }
                    if let error { Section { Text(error).foregroundStyle(.red) } }
                    Section("Risultati") {
                        ForEach(results) { r in
                            if provider?.canListEpisodes == true, let provider {
                                NavigationLink {
                                    SourceEpisodesView(provider: provider, result: r, seriesTitle: title, aniListId: aniListId, onStream: onStream)
                                } label: { ResultRow(result: r) }
                            } else {
                                ResultRow(result: r).swipeActions { sendButton(r) }.contextMenu { sendButton(r) }
                                    .overlay(alignment: .trailing) {
                                        Button { send(source: provider!.id, items: [DownloadItem(sourceRef: r.ref, episodeNumber: nil)]) } label: {
                                            Image(systemName: "externaldrive.badge.plus")
                                        }.buttonStyle(.borderless)
                                    }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Fonti")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } } }
            .overlay(alignment: .bottom) {
                if let sentMessage {
                    Label(sentMessage, systemImage: "checkmark.circle.fill")
                        .padding().background(.green.opacity(0.9), in: .capsule).padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .task {
                query = title
                providers = (try? await session.api.providers()) ?? []
                provider = providers.first(where: \.enabled)
                await search()
            }
            .onChange(of: provider) { Task { await search() } }
        }
    }

    private func sendButton(_ r: SourceSearchResult) -> some View {
        Button("Scarica sul NAS", systemImage: "externaldrive.badge.plus") {
            send(source: provider!.id, items: [DownloadItem(sourceRef: r.ref, episodeNumber: nil)])
        }
    }

    private func refIsValid(_ p: ProviderInfo) -> Bool {
        let ref = manualRef.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty else { return false }
        guard let pattern = p.refPattern else { return true }
        return ref.range(of: pattern, options: .regularExpression) != nil
    }

    private func search() async {
        guard let provider, provider.canSearch, !query.isEmpty else { results = []; return }
        searching = true; error = nil
        do { results = try await session.api.search(source: provider.id, query: query) }
        catch { self.error = error.localizedDescription; results = [] }
        searching = false
    }

    private func send(source: String, items: [DownloadItem]) {
        Task {
            do {
                try await session.api.requestNASDownload(DownloadRequest(source: source, seriesTitle: title, aniListId: aniListId, items: items))
                withAnimation { sentMessage = "Inviato al NAS" }
                try? await Task.sleep(for: .seconds(2))
                withAnimation { sentMessage = nil }
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct ResultRow: View {
    let result: SourceSearchResult
    var body: some View {
        HStack(spacing: 12) {
            if let p = result.posterUrl {
                RemoteImage(url: URL(string: p)).frame(width: 44, height: 64).clipShape(.rect(cornerRadius: 4))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).font(.subheadline).lineLimit(3)
                if let s = result.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
        .padding(.trailing, 36)
    }
}

/// Episode picker: select some or all, send to the NAS, or stream one now.
struct SourceEpisodesView: View {
    let provider: ProviderInfo
    let result: SourceSearchResult
    let seriesTitle: String
    let aniListId: Int?
    var onStream: ((URL, String) -> Void)?

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var episodes: [SourceEpisode] = []
    @State private var selection = Set<String>()
    @State private var loading = true
    @State private var message: String?

    private var resolvedAniListId: Int? {
        aniListId ?? episodes.first?.extra?["anilistId"].flatMap(Int.init)
    }

    var body: some View {
        List(selection: $selection) {
            if let message { Text(message).foregroundStyle(.green) }
            ForEach(episodes) { ep in
                HStack {
                    Text(ep.title)
                    Spacer()
                    if provider.canStream, onStream != nil {
                        Button { Task { await stream(ep) } } label: { Image(systemName: "play.circle") }.buttonStyle(.borderless)
                    }
                }
                .tag(ep.ref)
            }
        }
        .environment(\.editMode, .constant(.active))
        .overlay { if loading { ProgressView() } }
        .navigationTitle(result.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selection.count == episodes.count ? "Nessuno" : "Tutti") {
                    selection = selection.count == episodes.count ? [] : Set(episodes.map(\.ref))
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button { Task { await send() } } label: {
                    Label("Scarica sul NAS (\(selection.count))", systemImage: "externaldrive.badge.plus")
                }
                .buttonStyle(.borderedProminent).disabled(selection.isEmpty)
            }
        }
        .task {
            episodes = (try? await session.api.sourceEpisodes(source: provider.id, ref: result.ref)) ?? []
            loading = false
        }
    }

    private func send() async {
        let items = episodes.filter { selection.contains($0.ref) }.map { DownloadItem(sourceRef: $0.ref, episodeNumber: $0.number) }
        do {
            try await session.api.requestNASDownload(DownloadRequest(source: provider.id, seriesTitle: seriesTitle,
                                                                     aniListId: resolvedAniListId, items: items))
            message = "\(items.count) episodi inviati al NAS"
            selection = []
        } catch { message = error.localizedDescription }
    }

    private func stream(_ ep: SourceEpisode) async {
        guard let url = try? await session.api.sourceStreamURL(source: provider.id, ref: ep.ref) else { return }
        dismiss()
        onStream?(url, "\(seriesTitle) · \(ep.title)")
    }
}
