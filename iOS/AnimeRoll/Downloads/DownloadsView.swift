import AnimeRollKit
import SwiftUI

/// Download: the NAS queue (job cards with inline actions) and what is saved on this device.
struct DownloadsView: View {
    @Environment(AppSession.self) private var session
    @Environment(OfflineDownloads.self) private var offline
    @State private var jobs: [DownloadJob] = []
    @State private var scope = 0
    @State private var playing: PlaybackItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenTitle("Download")
                PillSegmented(options: ["Sul NAS", "Su questo dispositivo"], selection: $scope)
                if session.isOffline {
                    Label("NAS non raggiungibile: puoi guardare gli episodi salvati sul dispositivo.", systemImage: "wifi.slash")
                        .font(DS.body(13)).foregroundStyle(DS.accent)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(DS.accentSoft, in: .rect(cornerRadius: DS.rCard))
                }
                if scope == 0 { nasSection } else { deviceSection }
            }
            .padding(.horizontal).padding(.top, 8).padding(.bottom, 120)
            .frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { if session.isOffline { scope = 1 } }
        .refreshable { await load() }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(jobs.contains { $0.status.isActive } ? 3 : 15))
            }
        }
        .fullScreenCover(item: $playing) { PlayerScreen(item: $0) }
    }

    // MARK: NAS

    @ViewBuilder private var nasSection: some View {
        if jobs.isEmpty {
            empty("externaldrive", "Dalla pagina di un anime tocca Trova episodi per scaricare sul NAS")
        } else {
            let anyPaused = jobs.contains { $0.status == .paused }
            HStack(spacing: 8) {
                Spacer()
                Button {
                    act { anyPaused ? try await session.api.resumeAllNASDownloads() : try await session.api.pauseAllNASDownloads() }
                } label: { Label(anyPaused ? "Riprendi tutto" : "Pausa tutto", systemImage: anyPaused ? "play.fill" : "pause.fill") }
                    .buttonStyle(GhostButtonStyle())
                Button { act { try await session.api.clearFinishedNASDownloads() } } label: { Label("Pulisci", systemImage: "trash") }
                    .buttonStyle(GhostButtonStyle())
            }
            ForEach(jobs) { job in
                JobCard(job: job, act: act)
                    .contextMenu { jobMenu(job) }
            }
        }
    }

    /// Long-press menu: every queue action, including priority.
    @ViewBuilder private func jobMenu(_ job: DownloadJob) -> some View {
        if job.status == .queued || job.status == .paused {
            Button("Avvia subito", systemImage: "bolt.fill") { act { try await session.api.startNASDownloadNow(job.id) } }
        }
        if job.status.canPause {
            Button("Metti in pausa", systemImage: "pause.fill") { act { try await session.api.pauseNASDownload(job.id) } }
        }
        if job.status.canResume {
            Button("Riprendi", systemImage: "play.fill") { act { try await session.api.resumeNASDownload(job.id) } }
        }
        if job.status.isActive || job.status == .paused {
            Picker("Priorità", selection: Binding(
                get: { DownloadPriority(rawValue: min(max(job.priority ?? 0, -1), 1)) ?? .normal },
                set: { p in act { try await session.api.setNASDownloadPriority(job.id, p) } })) {
                ForEach(DownloadPriority.allCases.reversed()) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
        }
        if job.status.canRetry {
            Button("Riprova", systemImage: "arrow.clockwise") { act { try await session.api.retryNASDownload(job.id) } }
        }
        if job.status.canCancel {
            Button("Annulla", systemImage: "xmark", role: .destructive) { act { try await session.api.cancelNASDownload(job.id) } }
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Haptics.tick()
        Task { try? await work(); await load() }
    }

    // MARK: Device

    @ViewBuilder private var deviceSection: some View {
        let items = offline.items.sorted { ($0.series.title, $0.episode.number) < ($1.series.title, $1.episode.number) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(items.count) episodi offline").font(DS.body(14, 600))
                Spacer()
                Text("\(offline.totalBytes.fileSize) usati").font(DS.body(14)).foregroundStyle(DS.textTertiary)
            }
            ProgressLine(value: min(1, Double(offline.totalBytes) / 64_000_000_000))
            Text("I video sono anche nell'app File, in “Su iPhone › AnimeRoll”. Tieni premuto un episodio per aprirlo in un'altra app.")
                .font(DS.body(12)).foregroundStyle(DS.textTertiary)
        }
        .padding(16).background(DS.surface, in: .rect(cornerRadius: DS.rCard))

        if items.isEmpty && offline.inFlight.isEmpty {
            empty("iphone.and.arrow.forward", "Tocca la freccia accanto a un episodio per salvarlo sul dispositivo")
        }
        ForEach(items) { item in
            Button {
                let list = offline.items.filter { $0.series.id == item.series.id }.map(\.episode).sorted { $0.number < $1.number }
                playing = .episode(item.episode, series: item.series, playlist: list)
            } label: {
                HStack(spacing: 12) {
                    RemoteImage(url: (item.series.bannerUrl ?? item.series.posterUrl).flatMap(URL.init(string:)))
                        .frame(width: 112, height: 63)
                        .overlay { Image(systemName: "play.fill").foregroundStyle(.white) }
                        .clipShape(.rect(cornerRadius: DS.rPoster))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.series.title).font(DS.body(15, 600)).lineLimit(1)
                        Text("Episodio \(item.episode.numberLabel) · \(item.episode.sizeBytes.fileSize)").font(DS.body(12)).foregroundStyle(DS.textTertiary)
                    }
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let file = offline.localURL(for: item.episode.id) {
                    ShareLink(item: file) { Label("Apri con…", systemImage: "square.and.arrow.up") }
                }
                Button("Elimina dal dispositivo", systemImage: "trash", role: .destructive) { offline.delete(item.episode.id) }
            }
        }
    }

    private func empty(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 34))
            Text(text).font(DS.body(15)).multilineTextAlignment(.center)
        }
        .foregroundStyle(DS.textTertiary).frame(maxWidth: .infinity).padding(.vertical, 48).padding(.horizontal, 24)
    }

    private func load() async { jobs = (try? await session.api.nasDownloads()) ?? jobs }
}

/// One NAS job: title, episode · source, coloured status, progress and the actions it allows.
private struct JobCard: View {
    let job: DownloadJob
    let act: (@escaping () async throws -> Void) -> Void
    @Environment(AppSession.self) private var session

    private var color: Color {
        switch job.status {
        case .running: DS.accent
        case .postProcessing: DS.teal
        case .completed: DS.green
        case .failed: DS.pink
        case .paused: DS.yellow
        default: DS.textTertiary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.seriesTitle).font(DS.body(15, 700)).lineLimit(1)
                    Text([job.episodeNumber.map { "Episodio \($0.formatted())" }, job.sourceLabel,
                          (job.status.isActive || job.status == .paused) ? job.priorityLabel : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(DS.body(12)).foregroundStyle(DS.textTertiary)
                }
                Spacer()
                Text(job.status.label + (job.status == .running ? " \(Int(job.progress * 100))%" : ""))
                    .font(DS.body(12, 700)).foregroundStyle(color)
            }
            if job.status.isRunning || job.status == .paused || (job.status == .queued && job.progress > 0) {
                ProgressLine(value: job.progress)
            }
            if let m = job.message, !m.isEmpty {
                Text(m).font(DS.body(12)).foregroundStyle(job.status == .failed ? DS.pink : DS.textSecondary).lineLimit(2)
            }
            if job.status != .completed {
                HStack(spacing: 8) {
                    if job.status.canRetry {
                        Button("Riprova") { act { try await session.api.retryNASDownload(job.id) } }.buttonStyle(PrimaryButtonStyle(small: true))
                    }
                    if job.status == .queued || job.status == .paused {
                        Button { act { try await session.api.startNASDownloadNow(job.id) } } label: { Label("Avvia subito", systemImage: "bolt.fill") }
                            .buttonStyle(GhostButtonStyle())
                    }
                    if job.status.canPause {
                        Button("Pausa") { act { try await session.api.pauseNASDownload(job.id) } }.buttonStyle(GhostButtonStyle())
                    }
                    if job.status.canResume {
                        Button("Riprendi") { act { try await session.api.resumeNASDownload(job.id) } }.buttonStyle(PrimaryButtonStyle(small: true))
                    }
                    if job.status.canCancel && job.status != .postProcessing {
                        Button("Annulla") { act { try await session.api.cancelNASDownload(job.id) } }.buttonStyle(PrimaryButtonStyle(prominent: false, small: true))
                    }
                }
            }
        }
        .padding(14)
        .background(DS.surface, in: .rect(cornerRadius: DS.rCard))
    }
}
