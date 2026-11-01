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
    /// Opened from "schermo intero": one big video, ignoring the fold.
    var startFullScreen = false
    var body: some View {
        PlayerScreenContent(item: item, startFullScreen: startFullScreen).trackingFoldPosture()
    }
}

private struct PlayerScreenContent: View {
    let item: PlaybackItem
    init(item: PlaybackItem, startFullScreen: Bool) { self.item = item; _fullScreen = State(initialValue: startFullScreen) }
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.foldPosture) private var posture
    @State private var model: PlayerModel?
    @State private var showEpisodes = true
    @State private var pip = PiPHolder()
    /// Full screen: one big video ignoring the fold; the half-open layouts are one tap away.
    @State private var fullScreen = false

    private var isEpisode: Bool { if case .episode = item { true } else { false } }

    var body: some View {
        GeometryReader { geo in
            Group {
                if fullScreen { standard(geo.size) } else { switch posture {
                case .tabletop: tabletop(geo.size)
                // Book layout only when each page is wide enough for its content.
                case .book where geo.size.width >= 600: book(geo.size)
                default: standard(geo.size)
                } }
            }
        }
        .animation(DS.base, value: fullScreen)
        .background(.black)
        .overlay { if let model { LoadingOverlay(model: model) } else { ProgressView().controlSize(.large).tint(.white) } }
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
                if let model {
                    SystemPlayer(player: model.player, showsControls: false)
                    SubtitleOverlay(controller: model.subtitles, videoSize: model.videoSize)
                }
            }
            .frame(height: size.height / 2)
            if let model {
                TabletopControls(model: model, showEpisodes: isEpisode, close: close, expand: { fullScreen = true })
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
                    SubtitleOverlay(controller: model.subtitles, videoSize: model.videoSize)
                    NextUpOverlay(model: model)
                }
                HStack {
                    closeButton
                    Spacer()
                    if let model { SubtitleMenu(controller: model.subtitles) }
                    fullScreenButton(expand: true)
                }
                .padding()
            }
            .frame(width: size.width / 2)
            if let model {
                if isEpisode { EpisodePanel(model: model).frame(width: size.width / 2) }
                else { TabletopControls(model: model, showEpisodes: false, close: close, expand: { fullScreen = true }).frame(width: size.width / 2) }
            }
        }
    }

    /// Phone and iPad: custom AnimeRoll controls over the video; on wide screens the episode list can sit beside it.
    private func standard(_ size: CGSize) -> some View {
        let wide = (hSize == .regular || posture == .flat) && size.width > 900
        return HStack(spacing: 0) {
            ZStack {
                if let model {
                    PlayerSurface(player: model.player, pip: pip).ignoresSafeArea()
                    SubtitleOverlay(controller: model.subtitles, videoSize: model.videoSize).ignoresSafeArea().allowsHitTesting(false)
                    PlayerControls(model: model, pip: pip, isEpisode: isEpisode && !(wide && showEpisodes), close: close)
                }
            }
            .overlay(alignment: .topTrailing) {
                if posture.isHalfOpen && fullScreen { fullScreenButton(expand: false).padding(.top, 70).padding(.trailing, wide && isEpisode ? 76 : 20) }
            }
            .overlay(alignment: .topTrailing) {
                if wide, isEpisode {
                    Button { withAnimation(DS.base) { showEpisodes.toggle() } } label: {
                        Image(systemName: "sidebar.right").font(.headline).frame(width: 44, height: 44).glassCircle()
                    }
                    .buttonStyle(.plain).padding(.top, 70).padding(.trailing, 20).accessibilityLabel("Episodi")
                }
            }
            if wide, showEpisodes, let model, isEpisode {
                EpisodePanel(model: model).frame(width: min(380, size.width * 0.32))
                    .transition(.move(edge: .trailing))
            }
        }
    }

    /// Full screen on / off: the video takes the whole display regardless of the fold.
    private func fullScreenButton(expand: Bool) -> some View {
        Button { Haptics.tick(); fullScreen = expand } label: {
            Image(systemName: expand ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                .font(.headline).frame(width: 44, height: 44).glassCircle()
        }
        .buttonStyle(.plain).accessibilityLabel(expand ? "Schermo intero" : "Esci dallo schermo intero")
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark").font(.headline).padding(10).background(.ultraThinMaterial, in: .circle)
        }
    }
}

/// Touch controls for the lower half in tabletop posture. Everything is centred in the half:
/// title row on top (clear of the fold), then big transport buttons in the middle, the scrubber
/// under them, and the quick actions (skip intro, next episode) at the bottom.
private struct TabletopControls: View {
    let model: PlayerModel
    let showEpisodes: Bool
    let close: () -> Void
    var expand: (() -> Void)? = nil
    @State private var scrubbing: Double?

    var body: some View {
        VStack(spacing: 0) {
            // Title and the two round buttons.
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title).font(DS.display(22, 800)).lineLimit(1)
                    Text(model.subtitle).font(DS.body(14)).foregroundStyle(DS.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                SubtitleMenu(controller: model.subtitles)
                if let expand {
                    Button { Haptics.tick(); expand() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.headline).frame(width: 44, height: 44).background(DS.surface, in: .circle)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Schermo intero")
                }
                Button(action: close) {
                    Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44).background(DS.surface, in: .circle)
                }
                .buttonStyle(.plain).accessibilityLabel("Chiudi")
            }
            .padding(.top, 32)

            Spacer(minLength: 16)

            // Transport, centred.
            HStack(spacing: 40) {
                Button { Haptics.tick(); model.skip(seconds: -10) } label: {
                    Image(systemName: "gobackward.10").font(.title.weight(.semibold)).frame(width: 68, height: 68).glassCircle()
                }
                .buttonStyle(.plain).accessibilityLabel("Indietro 10 secondi")
                Button { Haptics.tick(); model.togglePlayPause() } label: {
                    TimelineView(.periodic(from: .now, by: 0.3)) { _ in
                        Image(systemName: model.player.rate == 0 ? "play.fill" : "pause.fill").font(.system(size: 38, weight: .bold))
                            .foregroundStyle(DS.onAccent).frame(width: 92, height: 92)
                            .background(DS.accent, in: .circle).shadow(color: DS.accent.opacity(0.45), radius: 26)
                    }
                }
                .buttonStyle(.plain).accessibilityLabel("Riproduci o pausa")
                Button { Haptics.tick(); model.skip(seconds: 10) } label: {
                    Image(systemName: "goforward.10").font(.title.weight(.semibold)).frame(width: 68, height: 68).glassCircle()
                }
                .buttonStyle(.plain).accessibilityLabel("Avanti 10 secondi")
            }
            .foregroundStyle(.white)

            Spacer(minLength: 20)

            // Scrubber with elapsed / remaining time.
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let duration = model.player.currentItem?.duration.seconds ?? 0
                let current = scrubbing ?? model.player.currentTime().seconds
                VStack(spacing: 4) {
                    Scrubber(value: current.isFinite ? current : 0, duration: duration.isFinite ? duration : 0) { scrubbing = $0 } onEnd: { t in
                        model.player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
                        scrubbing = nil
                    }
                    HStack {
                        Text(timeLabel(current)); Spacer(); Text("-" + timeLabel(max(0, duration - current))).foregroundStyle(DS.textSecondary)
                    }
                    .font(DS.body(13, 600).monospacedDigit())
                }
            }

            // Quick actions.
            HStack(spacing: 12) {
                Button { Haptics.tick(); model.skip(seconds: 85) } label: { Label("Salta sigla", systemImage: "forward.fill") }
                    .buttonStyle(GhostButtonStyle())
                Spacer()
                if showEpisodes, let next = model.nextEpisode {
                    Button { Task { await model.playNext() } } label: { Label("Episodio \(next.numberLabel)", systemImage: "forward.end.fill") }
                        .buttonStyle(PrimaryButtonStyle(small: true))
                }
            }
            .padding(.top, 18).padding(.bottom, 24)
        }
        .padding(.horizontal, 28)
        .frame(maxHeight: .infinity)
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
    /// "Schermo intero": stops this player and reopens the episode full screen, ignoring the fold.
    var expand: (() -> Void)? = nil
    @Environment(AppSession.self) private var session
    @State private var model: PlayerModel?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            if let model {
                SystemPlayer(player: model.player)
                SubtitleOverlay(controller: model.subtitles, videoSize: model.videoSize)
                NextUpOverlay(model: model)
                LoadingOverlay(model: model)
            }
            HStack(spacing: 8) {
                if let model { SubtitleMenu(controller: model.subtitles, compact: true) }
                if let expand {
                    Button { Task { await model?.stop(); expand() } } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").padding(8).background(.ultraThinMaterial, in: .circle)
                    }
                    .accessibilityLabel("Schermo intero")
                }
                Button { Task { await model?.stop(); close() } } label: {
                    Image(systemName: "xmark").padding(8).background(.ultraThinMaterial, in: .circle)
                }
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

/// Spinner while the first frames load, or the error if the video can't play.
private struct LoadingOverlay: View {
    let model: PlayerModel
    var body: some View {
        if let error = model.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .padding().background(.ultraThinMaterial, in: .rect(cornerRadius: 12)).padding()
        } else if model.isLoading {
            ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
        }
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
                .buttonStyle(PrimaryButtonStyle(small: true))
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
                            if ep.id == model.currentEpisode?.id { Image(systemName: "speaker.wave.2.fill").foregroundStyle(DS.accent) }
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
