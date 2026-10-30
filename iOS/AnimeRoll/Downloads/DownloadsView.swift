import AnimeRollKit
import SwiftUI

/// Two lists: what the NAS is downloading, and what is saved on this device.
struct DownloadsView: View {
    @Environment(AppSession.self) private var session
    @Environment(OfflineDownloads.self) private var offline
    @State private var jobs: [DownloadJob] = []
    @State private var scope = 0
    @State private var playing: PlaybackItem?

    var body: some View {
        List {
            Picker("", selection: $scope) {
                Text("Sul NAS").tag(0)
                Text("Su questo dispositivo").tag(1)
            }
            .pickerStyle(.segmented).listRowBackground(Color.clear)

            if scope == 0 { nasSection } else { deviceSection }
        }
        .navigationTitle("Download")
        .refreshable { await load() }
        .task {
            // Poll while the screen is open.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(jobs.contains { $0.status.isActive } ? 3 : 15))
            }
        }
        .toolbar {
            if scope == 0 {
                Button("Pulisci", systemImage: "trash") { Task { try? await session.api.clearFinishedNASDownloads(); await load() } }
            }
        }
        .fullScreenCover(item: $playing) { PlayerScreen(item: $0) }
    }

    @ViewBuilder private var nasSection: some View {
        if jobs.isEmpty {
            ContentUnavailableView("Nessun download", systemImage: "externaldrive",
                                   description: Text("Dalla pagina di un anime tocca “Trova episodi” e mandali al NAS."))
        }
        ForEach(jobs) { job in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(job.seriesTitle).font(.subheadline.bold()).lineLimit(1)
                    if let n = job.episodeNumber { Text("E\(n.formatted())").font(.subheadline).foregroundStyle(.secondary) }
                    Spacer()
                    Text(job.source.capitalized).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Theme.card, in: .capsule)
                }
                if job.status.isActive { ProgressView(value: job.progress) }
                Text("\(job.status.label)\(job.message.map { " · \($0)" } ?? "")").font(.caption).foregroundStyle(job.status == .failed ? .red : .secondary)
                    .lineLimit(2)
            }
            .swipeActions {
                if job.status.isActive {
                    Button("Annulla", role: .destructive) { Task { try? await session.api.cancelNASDownload(job.id); await load() } }
                } else if job.status == .failed || job.status == .cancelled {
                    Button("Riprova") { Task { try? await session.api.retryNASDownload(job.id); await load() } }.tint(.orange)
                }
            }
        }
    }

    @ViewBuilder private var deviceSection: some View {
        if offline.items.isEmpty {
            ContentUnavailableView("Niente offline", systemImage: "iphone.and.arrow.forward",
                                   description: Text("Tocca la freccia accanto a un episodio per salvarlo sul dispositivo."))
        } else {
            Text("Spazio usato: \(offline.totalBytes.fileSize)").font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(offline.items.sorted { ($0.series.title, $0.episode.number) < ($1.series.title, $1.episode.number) }) { item in
            Button {
                let list = offline.items.filter { $0.series.id == item.series.id }.map(\.episode).sorted { $0.number < $1.number }
                playing = .episode(item.episode, series: item.series, playlist: list)
            } label: {
                HStack {
                    RemoteImage(url: item.series.posterUrl.flatMap(URL.init(string:))).frame(width: 40, height: 60).clipShape(.rect(cornerRadius: 4))
                    VStack(alignment: .leading) {
                        Text(item.series.title).font(.subheadline.bold())
                        Text("Episodio \(item.episode.numberLabel) · \(item.episode.sizeBytes.fileSize)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .swipeActions { Button("Elimina", role: .destructive) { offline.delete(item.episode.id) } }
        }
    }

    private func load() async { jobs = (try? await session.api.nasDownloads()) ?? jobs }
}
