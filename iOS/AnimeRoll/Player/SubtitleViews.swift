import AnimeRollKit
import SwiftUI

/// Track choice + sync nudge. The choice becomes the default for the next episodes,
/// the sync is remembered per series.
struct SubtitleMenu: View {
    let controller: SubtitleController
    var compact = false

    var body: some View {
        Menu {
            Section("Sottotitoli") {
                Button { controller.select(nil) } label: {
                    if controller.selected == nil { Label("Disattivati", systemImage: "checkmark") } else { Text("Disattivati") }
                }
                ForEach(controller.tracks) { track in
                    Button { controller.select(track) } label: {
                        if controller.selected == track { Label(track.label, systemImage: "checkmark") } else { Text(track.label) }
                    }
                }
            }
            if controller.selected != nil {
                Section("Sincronia: \(offsetLabel)") {
                    Button("Anticipa di 0,25 s", systemImage: "backward") { controller.nudge(by: -SubtitleController.offsetStep) }
                    Button("Ritarda di 0,25 s", systemImage: "forward") { controller.nudge(by: SubtitleController.offsetStep) }
                    if controller.offset != 0 {
                        Button("Ripristina", systemImage: "arrow.uturn.backward") { controller.resetOffset() }
                    }
                }
            }
        } label: {
            Image(systemName: controller.selected == nil ? "captions.bubble" : "captions.bubble.fill")
                .font(compact ? .subheadline : .headline)
                .padding(compact ? 8 : 10)
                .background(.ultraThinMaterial, in: .circle)
        }
        .disabled(controller.tracks.isEmpty)
        .opacity(controller.tracks.isEmpty ? 0.4 : 1)
        .accessibilityLabel("Sottotitoli")
    }

    private var offsetLabel: String {
        controller.offset == 0 ? "originale"
            : (controller.offset > 0 ? "+" : "") + controller.offset.formatted(.number.precision(.fractionLength(2))) + " s"
    }
}

/// Audio track / dub choice. Hidden when the episode has a single track.
struct AudioMenu: View {
    let model: PlayerModel
    var compact = false

    var body: some View {
        if model.audioOptions.count > 1 {
            Menu {
                Section("Audio") {
                    ForEach(model.audioOptions) { option in
                        Button { model.selectAudio(option.id) } label: {
                            if model.selectedAudio == option.id { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                        }
                    }
                }
            } label: {
                Image(systemName: "waveform")
                    .font(compact ? .subheadline : .headline)
                    .padding(compact ? 8 : 10)
                    .background(.ultraThinMaterial, in: .circle)
            }
            .accessibilityLabel("Audio")
        }
    }
}
