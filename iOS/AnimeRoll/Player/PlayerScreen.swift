import AVKit
import AnimeRollKit
import SwiftUI

/// Full-screen player, shaped by how the device is held:
/// - iPhone Duo half open sideways (tabletop): video in the top half, touch controls
///   and episodes in the bottom half, so it can stand on a table like a mini laptop.
/// - iPhone Duo half open upright (book): video on one half, episode list on the other.
/// - Wide screens (Duo flat, iPad landscape): episode list next to the video, like Netflix on foldables.
struct PlayerScreen: View {
    let item: PlaybackItem
    var body: some View {
        PlayerScreenContent(item: item).trackingFoldPosture()
    }
}

private struct PlayerScreenContent: View {
    let item: PlaybackItem
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.foldPosture) private var posture
    @State private var model: PlayerModel?
    @State private var showEpisodes = true

    private var isEpisode: Bool { if case .episode = item { true } else { false } }

    var body: some View {
        GeometryReader { geo in
            Group {
                switch posture {
                case .tabletop: tabletop(geo.size)
                // Book layout only when each page is wide enough for its content.
                case .book where geo.size.width >= 600: book(geo.size)
                default: standard(geo.size)
                }
            }
        }
        .background(.black)
        .statusBarHidden()
        .task {
            let m = PlayerModel(api: session.api)
            model = m
            await m.load(item)
        }
        .onDisappear { Task { await model?.stop() } }
    }

    private func close() { Task { await model?.stop(); dismiss() } }

    // Video above the crease, controls below it.
    private func tabletop(_ size: CGSize) -> some View {
        VStack(spacing: 0) {
            ZStack {
                if let model { SystemPlayer(player: model.player, showsControls: false) }
            }
            .frame(height: size.height / 2)
            if let model {
                TabletopControls(model: model, showEpisodes: isEpisode, close: close)
                    .frame(height: size.height / 2)
            }
        }
        .ignoresSafeArea()
    }

    // Video on the left page, episodes on the right page.
    private func book(_ size: CGSize) -> some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let model {
                    SystemPlayer(player: model.player)
                    NextUpOverlay(model: model)
                }
                closeButton.padding()
            }
            .frame(width: size.width / 2)
            if let model {
                if isEpisode { EpisodePanel(model: model).frame(width: size.width / 2) }
                else { TabletopControls(model: model, showEpisodes: false, close: close).frame(width: size.width / 2) }
            }
        }
    }

    private func standard(_ size: CGSize) -> some View {
        let wide = (hSize == .regular || posture == .flat) && size.width > 900
        return HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let model {
                    SystemPlayer(player: model.player).ignoresSafeArea()
                    NextUpOverlay(model: model)
                }
                HStack {
                    closeButton
                    Spacer()
                    if wide, isEpisode {
                        Button { withAnimation { showEpisodes.toggle() } } label: {
                            Image(systemName: "sidebar.right").font(.headline).padding(10).background(.ultraThinMaterial, in: .circle)
                        }
                    }
                }
                .padding()
            }
            if wide, showEpisodes, let model, isEpisode {
                EpisodePanel(model: model).frame(width: min(380, size.width * 0.32))
                    .transition(.move(edge: .trailing))
            }
        }
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark").font(.headline).padding(10).background(.ultraThinMaterial, in: .circle)
        }
    }
}

/// Big touch controls for the lower half in tabletop posture.
private struct TabletopControls: View {
    let model: PlayerModel
    let showEpisodes: Bool
    let close: () -> Void
    @State private var scrubbing: Double?

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title).font(.headline).lineLimit(1)
                    Text(model.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.headline).padding(10).background(Theme.card, in: .circle) }
            }

            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let duration = model.player.currentItem?.duration.seconds ?? 0
                let current = scrubbing ?? model.player.currentTime().seconds
                VStack(spacing: 2) {
                    Slider(value: Binding(get: { current.isFinite ? current : 0 }, set: { scrubbing = $0 }),
                           in: 0...max(duration.isFinite ? duration : 1, 1)) { editing in
                        if !editing, let t = scrubbing {
                            model.player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
                            scrubbing = nil
                        }
                    }
                    HStack {
                        Text(timeLabel(current)); Spacer(); Text("-" + timeLabel(max(0, duration - current)))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 36) {
                Button { model.skip(seconds: -10) } label: { Image(systemName: "gobackward.10") }
                Button { model.player.rate == 0 ? model.player.play() : model.player.pause() } label: {
                    TimelineView(.periodic(from: .now, by: 0.3)) { _ in
                        Image(systemName: model.player.rate == 0 ? "play.circle.fill" : "pause.circle.fill").font(.system(size: 56))
                    }
                }
                Button { model.skip(seconds: 85) } label: { Image(systemName: "forward.end.alt") } // salta sigla
                Button { model.skip(seconds: 10) } label: { Image(systemName: "goforward.10") }
            }
            .font(.title)
            .foregroundStyle(.white)

            if showEpisodes, let next = model.nextEpisode {
                Button { Task { await model.playNext() } } label: {
                    Label("Episodio \(next.numberLabel)", systemImage: "forward.end.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Theme.background)
    }

    private func timeLabel(_ s: Double) -> String {
        guard s.isFinite else { return "0:00" }
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Smaller player embedded at the top of the detail pane (two-pane layout).
struct InlinePlayer: View {
    let item: PlaybackItem
    let close: () -> Void
    @Environment(AppSession.self) private var session
    @State private var model: PlayerModel?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            if let model {
                SystemPlayer(player: model.player)
                NextUpOverlay(model: model)
            }
            Button { Task { await model?.stop(); close() } } label: {
                Image(systemName: "xmark").padding(8).background(.ultraThinMaterial, in: .circle)
            }
            .padding(8)
        }
        .task {
            let m = PlayerModel(api: session.api)
            model = m
            await m.load(item)
        }
        .onDisappear { Task { await model?.stop() } }
    }
}

private struct NextUpOverlay: View {
    let model: PlayerModel
    var body: some View {
        if model.showNextUp, let next = model.nextEpisode {
            VStack { Spacer(); HStack { Spacer()
                Button { Task { await model.playNext() } } label: {
                    Label("Episodio \(next.numberLabel)", systemImage: "forward.end.fill").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                .padding(.trailing, 24).padding(.bottom, 90)
            } }
        }
    }
}

private struct EpisodePanel: View {
    let model: PlayerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.headline)
                Text(model.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            ScrollViewReader { proxy in
                List(model.playlistEpisodes) { ep in
                    Button { Task { await model.play(ep) } } label: {
                        HStack {
                            Text("E\(ep.numberLabel)").font(.subheadline.monospacedDigit().bold()).frame(width: 44, alignment: .leading)
                            Text(ep.title ?? "Episodio").lineLimit(1)
                            Spacer()
                            if ep.id == model.currentEpisode?.id { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.accent) }
                            else if ep.completed { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                        }
                    }
                    .id(ep.id)
                    .listRowBackground(ep.id == model.currentEpisode?.id ? Theme.card : Color.clear)
                }
                .listStyle(.plain)
                .onAppear { proxy.scrollTo(model.currentEpisode?.id, anchor: .center) }
            }
        }
        .background(Theme.background)
    }
}

/// AVPlayerViewController: native controls, PiP, AirPlay, subtitles picker.
struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    var showsControls = true

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.showsPlaybackControls = showsControls
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
        if vc.showsPlaybackControls != showsControls { vc.showsPlaybackControls = showsControls }
    }
}
