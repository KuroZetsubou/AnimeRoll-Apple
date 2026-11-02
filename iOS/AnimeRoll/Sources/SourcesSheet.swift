import AnimeRollKit
import SwiftUI

extension Notification.Name {
    /// Asks MainView to switch to the Download tab (after sending downloads to the NAS).
    static let showDownloads = Notification.Name("AnimeRoll.showDownloads")
}

/// "Trova episodi", guided: 1 Fonte, 2 Cerca (or a link for download-only sources),
/// 3 Risultati → pick the episodes → "Scarica sul NAS (n)". Streaming stays available per episode.
struct SourcesSheet: View {
    let title: String
    let aniListId: Int?
    /// Series already in the library: enables "Aggiorna solo i sottotitoli".
    var seriesId: Int? = nil
    /// Direct streaming without downloading.
    var onStream: ((URL, String) -> Void)? = nil

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var providers: [ProviderInfo] = []
    @State private var provider: ProviderInfo?
    @State private var query = ""
    @State private var results: [SourceSearchResult] = []
    @State private var picked: SourceSearchResult?
    @State private var episodes: [SourceEpisode] = []
    @State private var selection = Set<String>()
    @State private var loading = false
    @State private var error: String?
    @State private var manualRef = ""
    @State private var manualEpisode = ""
    @State private var sent = 0
    @State private var subtitleNote: String?

    private var manual: Bool { provider.map { !$0.canSearch } ?? false }
    private var count: Int { manual ? (refIsValid ? 1 : 0) : (picked == nil ? 0 : selection.count) }

    var body: some View {
        ScrollView {
            if sent > 0 { sentView } else { form }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(DS.background)
        .safeAreaInset(edge: .bottom) { if sent == 0 { bottomBar } }
        .presentationBackground(DS.background)
        .presentationCornerRadius(DS.rSheet)
        .presentationDragIndicator(.visible)
        .task {
            query = title
            providers = ((try? await session.api.providers()) ?? []).filter(\.enabled)
            provider = providers.first
            if providers.isEmpty { error = "Nessuna fonte attiva sul NAS." }
        }
        .task(id: provider?.id) { await search() }
    }

    // MARK: Steps

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trova episodi").font(DS.display(24, 800))
                    Text(title).font(DS.body(13)).foregroundStyle(DS.textTertiary).lineLimit(1)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.bold()).frame(width: 40, height: 40).background(DS.surface, in: .circle)
                }
                .buttonStyle(.plain).accessibilityLabel("Chiudi")
            }
            .padding(.top, 20)

            step(1, "Fonte")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(providers) { p in Chip(title: p.name, selected: p.id == provider?.id) { provider = p } }
                }
            }
            if let hint = provider?.hint { Text(hint).font(DS.body(12)).foregroundStyle(DS.textSecondary).padding(.top, 8) }

            if manual {
                step(2, "Link o riferimento")
                field("https://… o magnet", text: $manualRef, icon: "link").keyboardType(.URL)
                field("Numero episodio (facoltativo)", text: $manualEpisode, icon: "number").keyboardType(.decimalPad).padding(.top, 10)
            } else {
                step(2, "Cerca")
                field("Titolo da cercare", text: $query, icon: "magnifyingglass", pill: true)
                    .submitLabel(.search).onSubmit { Task { await search() } }
                if let picked { episodesStep(picked) } else { resultsStep }
            }
            if let error { Text(error).font(DS.body(13)).foregroundStyle(DS.pink).padding(.top, 12) }
        }
        .padding(.horizontal, 20).padding(.bottom, 24)
    }

    @ViewBuilder private var resultsStep: some View {
        step(3, "Risultati")
        if loading { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20) }
        else if results.isEmpty { Text("Nessun risultato.").font(DS.body(14)).foregroundStyle(DS.textSecondary) }
        ForEach(results) { r in
            Button { open(r) } label: {
                HStack(spacing: 12) {
                    if let p = r.posterUrl {
                        RemoteImage(url: URL(string: p)).frame(width: 40, height: 58).clipShape(.rect(cornerRadius: 6))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title).font(DS.body(15, 600)).lineLimit(2)
                        if let s = r.subtitle { Text(s).font(DS.body(12)).foregroundStyle(DS.textTertiary).lineLimit(1) }
                    }
                    Spacer()
                    Image(systemName: provider?.canListEpisodes == true ? "chevron.right" : "externaldrive.badge.plus")
                        .foregroundStyle(DS.textTertiary)
                }
                .frame(minHeight: 52).contentShape(.rect)
            }
            .buttonStyle(.plain)
            Divider().overlay(DS.hairline)
        }
    }

    @ViewBuilder private func episodesStep(_ r: SourceSearchResult) -> some View {
        HStack {
            stepBadge(3)
            Text(r.title).font(DS.body(15, 700)).lineLimit(1)
            Spacer()
            Button("Tutti") { selection = Set(episodes.map(\.ref)) }
            Button("Nessuno") { selection = [] }.padding(.leading, 10)
        }
        .font(DS.body(14, 600)).tint(DS.accent).padding(.top, 18).padding(.bottom, 4)
        if loading { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20) }
        ForEach(episodes) { ep in
            let on = selection.contains(ep.ref)
            HStack(spacing: 12) {
                Button {
                    Haptics.tick()
                    if on { selection.remove(ep.ref) } else { selection.insert(ep.ref) }
                } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 6).fill(on ? DS.accent : .clear)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? DS.accent : DS.borderStrong, lineWidth: 1.5))
                            .overlay { if on { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(DS.onAccent) } }
                            .frame(width: 22, height: 22)
                        Text(ep.title).font(DS.body(15, 600)).lineLimit(1)
                        Spacer()
                    }
                    .frame(minHeight: 50).contentShape(.rect)
                }
                .buttonStyle(.plain)
                if provider?.canStream == true, onStream != nil {
                    Button { Task { await stream(ep) } } label: { Image(systemName: "play.circle").font(.title3) }
                        .buttonStyle(.plain).foregroundStyle(DS.textSecondary).accessibilityLabel("Guarda ora")
                }
            }
            Divider().overlay(DS.hairline)
        }
        Button { withAnimation(DS.base) { picked = nil; episodes = [] } } label: {
            Label("Risultati", systemImage: "chevron.left").font(DS.body(14, 600))
        }
        .tint(DS.textSecondary).padding(.top, 12)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            Button { Task { await send() } } label: {
                Label("Scarica sul NAS (\(count))", systemImage: "externaldrive.badge.plus")
            }
            .buttonStyle(PrimaryButtonStyle()).disabled(count == 0).opacity(count == 0 ? 0.4 : 1)
            if !manual, provider?.canSubtitles == true, picked != nil, seriesId != nil {
                Button { Task { await refreshSubtitles() } } label: { Label("Aggiorna solo i sottotitoli (ASS)", systemImage: "captions.bubble") }
                    .buttonStyle(PrimaryButtonStyle(prominent: false))
                if let subtitleNote { Text(subtitleNote).font(DS.body(12)).foregroundStyle(DS.textSecondary).multilineTextAlignment(.center) }
            }
            if !manual, provider?.canStream == true, onStream != nil, let first = selectedEpisodes.first ?? episodes.first {
                Button { Task { await stream(first) } } label: { Label("Guarda subito in streaming", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle(prominent: false))
            }
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
        .background(DS.background.opacity(0.96))
    }

    private var sentView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(DS.accent).padding(.top, 48)
            Text("Inviati \(sent) download al NAS").font(DS.display(20, 700))
            Text("Li trovi nella coda in Download.").font(DS.body(14)).foregroundStyle(DS.textSecondary)
            Button("Vai a Download") {
                dismiss()
                NotificationCenter.default.post(name: .showDownloads, object: nil)
            }
            .buttonStyle(PrimaryButtonStyle()).padding(.top, 8)
            Button("Chiudi") { dismiss() }.buttonStyle(PrimaryButtonStyle(prominent: false))
        }
        .padding(.horizontal, 20)
    }

    // MARK: Pieces

    private func step(_ n: Int, _ label: String) -> some View {
        HStack(spacing: 10) { stepBadge(n); Text(label).font(DS.body(15, 700)) }.padding(.top, 18).padding(.bottom, 10)
    }

    private func stepBadge(_ n: Int) -> some View {
        Text("\(n)").font(DS.display(12, 800)).foregroundStyle(DS.onAccent).frame(width: 22, height: 22).background(DS.accent, in: .circle)
    }

    private func field(_ placeholder: String, text: Binding<String>, icon: String, pill: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(DS.textTertiary)
            TextField(placeholder, text: text).font(DS.body(16)).textInputAutocapitalization(.never).autocorrectionDisabled()
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DS.textTertiary) }
            }
        }
        .padding(.horizontal, 16).frame(height: 52)
        .background(DS.surface, in: .rect(cornerRadius: pill ? 26 : DS.rCard))
        .overlay(RoundedRectangle(cornerRadius: pill ? 26 : DS.rCard).strokeBorder(DS.hairline))
    }

    private var selectedEpisodes: [SourceEpisode] { episodes.filter { selection.contains($0.ref) } }

    private var refIsValid: Bool {
        let ref = manualRef.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty else { return false }
        guard let pattern = provider?.refPattern else { return true }
        return ref.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: Actions

    private func search() async {
        picked = nil; episodes = []
        guard let provider, provider.canSearch, !query.isEmpty else { results = []; return }
        loading = true; error = nil
        do { results = try await session.api.search(source: provider.id, query: query) }
        catch { self.error = error.localizedDescription; results = [] }
        loading = false
    }

    private func open(_ r: SourceSearchResult) {
        guard let provider else { return }
        Haptics.tick()
        guard provider.canListEpisodes else {
            Task { await send(items: [DownloadItem(sourceRef: r.ref, episodeNumber: nil)], aniList: r.aniListId) }
            return
        }
        withAnimation(DS.base) { picked = r }
        loading = true
        Task {
            episodes = (try? await session.api.sourceEpisodes(source: provider.id, ref: r.ref)) ?? []
            selection = Set(episodes.map(\.ref))
            loading = false
        }
    }

    private func refreshSubtitles() async {
        guard let provider, let picked, let seriesId else { return }
        subtitleNote = "Invio…"
        do {
            let r = try await session.api.refreshSubtitles(seriesId: seriesId, source: provider.id, seriesRef: picked.ref)
            let missing = r.notFound.isEmpty ? "" : " · non trovati su \(provider.name): " + r.notFound.map { String(format: "%g", $0) }.joined(separator: ", ")
            subtitleNote = "\(r.queued) episodi in coda per i sottotitoli\(missing). Segui l'avanzamento in Download."
        } catch { subtitleNote = error.localizedDescription }
    }

    private func send() async {
        if manual {
            let ep = Double(manualEpisode.replacingOccurrences(of: ",", with: "."))
            await send(items: [DownloadItem(sourceRef: manualRef.trimmingCharacters(in: .whitespaces), episodeNumber: ep)], aniList: nil)
        } else {
            let items = selectedEpisodes.map { DownloadItem(sourceRef: $0.ref, episodeNumber: $0.number) }
            await send(items: items, aniList: picked?.aniListId ?? episodes.first?.extra?["anilistId"].flatMap(Int.init))
        }
    }

    private func send(items: [DownloadItem], aniList: Int?) async {
        guard let provider, !items.isEmpty else { return }
        do {
            _ = try await session.api.requestNASDownload(DownloadRequest(source: provider.id, seriesTitle: title,
                                                                         aniListId: aniListId ?? aniList, items: items))
            Haptics.tick()
            withAnimation(DS.base) { sent = items.count }
        } catch { self.error = error.localizedDescription }
    }

    private func stream(_ ep: SourceEpisode) async {
        guard let provider, let url = try? await session.api.sourceStreamURL(source: provider.id, ref: ep.ref) else { return }
        dismiss()
        onStream?(url, "\(title) · \(ep.title)")
    }
}
