import AnimeRollKit
import AVKit
import SwiftUI

/// Full-screen AVPlayerViewController (native tvOS transport bar, subtitles, audio tracks).
struct TVPlayerView: View {
    let item: PlaybackItem
    @Environment(AppSession.self) private var session
    @State private var model: PlayerModel?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let model {
                TVSystemPlayer(player: model.player, title: model.title, subtitle: model.subtitle,
                               subtitles: model.subtitles, menuState: menuState(model.subtitles))
                    .ignoresSafeArea()
                SubtitleOverlay(controller: model.subtitles, videoSize: model.videoSize).ignoresSafeArea()
                if let left = model.autoNextIn, let next = model.nextEpisode {
                    HStack(spacing: 24) {
                        Text("Episodio \(next.numberLabel) tra \(left) s")
                        Button("Annulla") { model.cancelAutoNext() }
                        Button("Avvia") { Task { await model.playNext() } }
                    }
                    .padding(80)
                } else if model.showNextUp, let next = model.nextEpisode {
                    Button("Episodio \(next.numberLabel) ▸") { Task { await model.playNext() } }
                        .padding(80)
                }
            }
        }
        .task {
            let m = PlayerModel(api: session.api)
            model = m
            await m.load(item)
        }
        .onDisappear { Task { await model?.stop() } }
    }

    /// Reading these here makes SwiftUI refresh the transport-bar menu when they change.
    private func menuState(_ c: SubtitleController) -> String {
        "\(c.tracks.map(\.index))|\(c.selected?.index ?? -1)|\(c.offset)"
    }
}

/// AVPlayerViewController with a "Sottotitoli" menu in the native transport bar
/// (tracks, off, sync nudge), reachable with the Siri Remote like Apple's own menus.
struct TVSystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let title: String
    let subtitle: String
    let subtitles: SubtitleController
    let menuState: String

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        let t = AVMutableMetadataItem(); t.identifier = .commonIdentifierTitle; t.value = title as NSString
        let s = AVMutableMetadataItem(); s.identifier = .iTunesMetadataTrackSubTitle; s.value = subtitle as NSString
        player.currentItem?.externalMetadata = [t, s]
        vc.transportBarCustomMenuItems = subtitles.tracks.isEmpty ? [] : [subtitleMenu()]
    }

    private func subtitleMenu() -> UIMenu {
        let c = subtitles
        let off = UIAction(title: "Disattivati", state: c.selected == nil ? .on : .off) { _ in c.select(nil) }
        let tracks = c.tracks.map { track in
            UIAction(title: track.label, state: c.selected == track ? .on : .off) { _ in c.select(track) }
        }
        var children: [UIMenuElement] = [UIMenu(options: .displayInline, children: [off] + tracks)]
        if c.selected != nil {
            let current = c.offset == 0 ? "originale" : String(format: "%+.2f s", c.offset)
            children.append(UIMenu(title: "Sincronia: \(current)", options: .displayInline, children: [
                UIAction(title: "Anticipa di 0,25 s", image: UIImage(systemName: "backward")) { _ in c.nudge(by: -SubtitleController.offsetStep) },
                UIAction(title: "Ritarda di 0,25 s", image: UIImage(systemName: "forward")) { _ in c.nudge(by: SubtitleController.offsetStep) },
                UIAction(title: "Ripristina", image: UIImage(systemName: "arrow.uturn.backward"),
                         attributes: c.offset == 0 ? .disabled : []) { _ in c.resetOffset() },
            ]))
        }
        return UIMenu(title: "Sottotitoli", image: UIImage(systemName: "captions.bubble"), children: children)
    }
}
