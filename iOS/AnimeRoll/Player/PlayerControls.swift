import AVKit
import AnimeRollKit
import SwiftUI

/// Video surface for the custom player: an AVPlayerLayer with its own Picture in Picture controller
/// (AVPlayerViewController can't start PiP when its controls are hidden).
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let pip: PiPHolder

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        pip.attach(v.playerLayer)
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

@MainActor @Observable final class PiPHolder {
    @ObservationIgnored private var controller: AVPictureInPictureController?
    var available = false

    func attach(_ layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported(), controller == nil else { return }
        let c = AVPictureInPictureController(playerLayer: layer)
        c?.canStartPictureInPictureAutomaticallyFromInline = true
        controller = c
        available = c != nil
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() } else { controller.startPictureInPicture() }
    }
}

/// AirPlay route picker.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(DS.accent)
        v.prioritizesVideoDevices = true
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}

/// AnimeRoll player controls: title on top with PiP / AirPlay, glass ±10 and an orange play in the
/// middle, "Salta sigla", "Prossimo episodio", an orange scrubber with elapsed / remaining time,
/// Episodi, subtitles and next. Tap the video to show or hide them; they hide after 3 s of playback.
struct PlayerControls: View {
    let model: PlayerModel
    let pip: PiPHolder
    let isEpisode: Bool
    let close: () -> Void

    @State private var visible = true
    @State private var lastTouch = Date()
    @State private var scrubbing: Double?
    @State private var showEpisodes = false
    @State private var wasPlaying = false
    /// Short screens (the closed iPhone Duo): one bottom row instead of scrubber + times + actions stacked.
    @State private var compact = false
    /// Safe area of the screen (before the controls ignore it): the large side is the camera cutout of the closed Duo.
    @State private var insets = EdgeInsets()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let duration = finite(model.player.currentItem?.duration.seconds)
            let current = scrubbing ?? finite(model.player.currentTime().seconds)
            let playing = model.player.rate != 0
            ZStack {
                Color.clear.allowsHitTesting(false).onGeometryChange(for: EdgeInsets.self, of: { $0.safeAreaInsets }) { insets = $0 }
                // Tap target over the video.
                Color.black.opacity(0.001)
                    .onTapGesture { withAnimation(DS.base) { visible.toggle() }; lastTouch = .now }
                if visible {
                    controls(current: current, duration: duration, playing: playing)
                        .transition(.opacity)
                }
            }
            .onChange(of: visible) { _, v in model.controlsVisible = v }
            .onChange(of: ctx.date) { _, now in
                // The countdown starts when playback actually starts (or resumes), not when the screen opens.
                if playing != wasPlaying { wasPlaying = playing; lastTouch = now }
                if visible, playing, scrubbing == nil, !showEpisodes, now.timeIntervalSince(lastTouch) > 4 {
                    withAnimation(DS.slow) { visible = false }
                }
            }
        }
        .sheet(isPresented: $showEpisodes) {
            PlayerEpisodesSheet(model: model) { showEpisodes = false }
                .presentationDetents([.medium, .large])
                .presentationBackground(DS.surfaceRaised)
        }
    }

    private func controls(current: Double, duration: Double, playing: Bool) -> some View {
        ZStack {
        // Centre of the picture (not of what is left between the top and bottom rows): -10, play / pause, +10.
        GeometryReader { geo in
            let video = SubtitleOverlay.fittedRect(video: model.videoSize, in: geo.size)
        HStack(spacing: 32) {
                glassRound("gobackward.10", 56, "Indietro 10 secondi") { touch(); model.skip(seconds: -10) }
                Button { touch(); Haptics.tick(); model.togglePlayPause() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 32, weight: .bold))
                        .foregroundStyle(DS.onAccent).frame(width: 76, height: 76)
                        .background(DS.accent, in: .circle).shadow(color: DS.accent.opacity(0.4), radius: 24)
                }
                .buttonStyle(.plain).accessibilityLabel(playing ? "Pausa" : "Riproduci")
                glassRound("goforward.10", 56, "Avanti 10 secondi") { touch(); model.skip(seconds: 10) }
            }
            .position(x: geo.size.width / 2, y: video.midY)
        }
        VStack(spacing: 0) {
            // Top: close, title, PiP, AirPlay.
            HStack(alignment: .top, spacing: 8) {
                roundButton("chevron.down", "Chiudi", action: close)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title).font(DS.display(compact ? 16 : 22, 800)).lineLimit(1)
                    if !compact { Text(model.subtitle).font(DS.body(13)).foregroundStyle(DS.textSecondary).lineLimit(1) }
                }
                .frame(minHeight: compact ? 44 : 0, alignment: .leading)
                Spacer()
                if pip.available { roundButton("pip.enter", "Picture in Picture") { pip.toggle() } }
                AirPlayButton().frame(width: 44, height: 44)
            }
            .padding(.leading, cutLeading ? insets.leading : 0)

            Spacer()

            // The camera cutout sits in one corner of the closed Duo: only the row next to it stays out of that side.
            VStack(spacing: 0) {

            // Bottom: skip intro / next up, scrubber, times, actions.
            HStack(alignment: .bottom) {
                if current < 150 && duration > 300 {
                    Button { touch(); model.skip(seconds: 85) } label: {
                        Label("Salta sigla", systemImage: "forward.fill").font(DS.display(14, 700)).padding(.horizontal, 16).frame(height: 40).glassCapsule()
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if model.showNextUp, let next = model.nextEpisode {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Prossimo episodio").font(DS.body(11)).foregroundStyle(DS.textSecondary)
                            Text("E\(next.numberLabel)\(next.title.map { " · \($0)" } ?? "")").font(DS.body(14, 700)).lineLimit(1)
                        }
                        Button("Avvia") { Task { await model.playNext() } }.buttonStyle(PrimaryButtonStyle(small: true))
                    }
                    .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 10)
                    .glassRect()
                }
            }
            .frame(minHeight: 40).padding(.bottom, compact ? 4 : 12)

            if compact {
                // One row at the bottom: episodes, time, bar, remaining, audio / subtitles / next.
                HStack(spacing: 10) {
                    if isEpisode { roundButton("list.bullet.rectangle", "Episodi") { showEpisodes = true } }
                    Text(timeLabel(current)).font(DS.body(12, 600).monospacedDigit())
                    scrubber(current: current, duration: duration)
                    Text("-" + timeLabel(max(0, duration - current))).font(DS.body(12, 600).monospacedDigit()).foregroundStyle(DS.textSecondary)
                    AudioMenu(model: model, compact: true)
                    SubtitleMenu(controller: model.subtitles, compact: true)
                    if model.nextEpisode != nil { roundButton("forward.end.fill", "Episodio successivo") { Task { await model.playNext() } } }
                }
                .padding(.trailing, cutTrailing ? insets.trailing : 0)
            } else {
            scrubber(current: current, duration: duration)
            HStack {
                Text(timeLabel(current)); Spacer(); Text("-" + timeLabel(max(0, duration - current))).foregroundStyle(DS.textSecondary)
            }
            .font(DS.body(13, 600).monospacedDigit()).padding(.top, 4).padding(.bottom, 10)

            HStack(spacing: 4) {
                if isEpisode {
                    Button { touch(); showEpisodes = true } label: { Label("Episodi", systemImage: "list.bullet.rectangle") }
                        .buttonStyle(GhostButtonStyle())
                }
                Spacer()
                AudioMenu(model: model)
                SubtitleMenu(controller: model.subtitles)
                if model.nextEpisode != nil {
                    roundButton("forward.end.fill", "Episodio successivo") { Task { await model.playNext() } }
                }
            }
            .padding(.trailing, cutTrailing ? insets.trailing : 0)
            }
            }
        }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20).padding(.vertical, compact ? 6 : 16)
        // Use the whole width: the empty strip the system reserves would otherwise stay unused.
        .ignoresSafeArea(.container, edges: .horizontal)
        .onGeometryChange(for: Bool.self, of: { $0.size.height < 430 }) { compact = $0 }
        .background {
            LinearGradient(stops: [.init(color: DS.ink950.opacity(0.55), location: 0), .init(color: .clear, location: 0.3),
                                   .init(color: .clear, location: 0.55), .init(color: DS.ink950.opacity(0.85), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
        }
    }

    private var cutLeading: Bool { insets.leading > insets.trailing && insets.leading > 40 }
    private var cutTrailing: Bool { insets.trailing > insets.leading && insets.trailing > 40 }

    private func scrubber(current: Double, duration: Double) -> some View {
        Scrubber(value: current, duration: duration) { t in touch(); scrubbing = t } onEnd: { t in
            model.player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            scrubbing = nil
        }
    }

    private func touch() { lastTouch = .now }

    private func roundButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button { touch(); action() } label: { Image(systemName: icon).font(.headline).frame(width: 44, height: 44).contentShape(.rect) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }

    private func glassRound(_ icon: String, _ size: CGFloat, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.title2.weight(.semibold)).frame(width: size, height: size).glassCircle() }
            .buttonStyle(.plain).accessibilityLabel(label)
    }

    private func finite(_ v: Double?) -> Double { guard let v, v.isFinite else { return 0 }; return v }

    private func timeLabel(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Orange track with a white knob; drag anywhere on it.
struct Scrubber: View {
    let value: Double
    let duration: Double
    let onChange: (Double) -> Void
    let onEnd: (Double) -> Void

    var body: some View {
        GeometryReader { g in
            let f = duration > 0 ? min(1, max(0, value / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height: 5)
                Capsule().fill(DS.accent).frame(width: g.size.width * f, height: 5)
                Circle().fill(.white).frame(width: 16, height: 16).shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                    .offset(x: g.size.width * f - 8)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in onChange(position(v.location.x, g.size.width)) }
                .onEnded { v in onEnd(position(v.location.x, g.size.width)) })
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityLabel("Posizione")
        .accessibilityValue("\(Int(value)) secondi su \(Int(duration))")
        .accessibilityAdjustableAction { dir in
            let t = dir == .increment ? value + 10 : value - 10
            onEnd(min(max(0, t), duration))
        }
    }

    private func position(_ x: CGFloat, _ width: CGFloat) -> Double { duration * Double(min(1, max(0, x / max(width, 1)))) }
}

/// Episode list as a drawer from the player.
struct PlayerEpisodesSheet: View {
    let model: PlayerModel
    let done: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Episodi").font(DS.display(20, 700)).padding(.top, 24).padding(.bottom, 8)
                    ForEach(model.playlistEpisodes) { ep in
                        let current = ep.id == model.currentEpisode?.id
                        Button { done(); Task { await model.play(ep) } } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle().fill(current ? DS.accent : ep.completed ? DS.accentSoft : DS.surface)
                                    if ep.completed && !current { Image(systemName: "checkmark").font(.subheadline.bold()).foregroundStyle(DS.accent) }
                                    else { Text(ep.numberLabel).font(DS.display(14, 700)).foregroundStyle(current ? DS.onAccent : DS.textSecondary) }
                                }
                                .frame(width: 36, height: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ep.title ?? "Episodio \(ep.numberLabel)").font(DS.body(15, 600)).lineLimit(1)
                                    if let d = ep.durationSeconds { Text(d.durationLabel).font(DS.body(12)).foregroundStyle(DS.textTertiary) }
                                }
                                Spacer()
                                if current { Image(systemName: "speaker.wave.2.fill").foregroundStyle(DS.accent) }
                            }
                            .padding(.vertical, 12).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .id(ep.id)
                        Rectangle().fill(DS.hairline).frame(height: 1)
                    }
                }
                .padding(.horizontal, 20)
            }
            .onAppear { proxy.scrollTo(model.currentEpisode?.id, anchor: .center) }
        }
    }
}

extension View {
    /// Glass rounded card (next-up).
    @ViewBuilder func glassRect() -> some View {
        if #available(iOS 26.0, *) { glassEffect(.regular, in: .rect(cornerRadius: DS.rCard)) }
        else { background(.ultraThinMaterial, in: .rect(cornerRadius: DS.rCard)) }
    }
}
