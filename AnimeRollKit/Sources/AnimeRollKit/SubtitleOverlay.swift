import SwiftUI

/// Subtitles drawn over the picture itself (not the black bars), sized to the video width.
public struct SubtitleOverlay: View {
    let controller: SubtitleController
    /// Natural size of the video; zero until known (then the whole area is used).
    var videoSize: CGSize

    public init(controller: SubtitleController, videoSize: CGSize = .zero) {
        self.controller = controller
        self.videoSize = videoSize
    }

    public var body: some View {
        GeometryReader { outer in
            let rect = Self.fittedRect(video: videoSize, in: outer.size)
            content(width: rect.width, height: rect.height)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
        .allowsHitTesting(false)
    }

    /// Aspect-fit rect of the video inside the player area, like AVPlayerLayer draws it.
    public static func fittedRect(video: CGSize, in area: CGSize) -> CGRect {
        guard video.width > 0, video.height > 0, area.width > 0, area.height > 0 else { return CGRect(origin: .zero, size: area) }
        let scale = min(area.width / video.width, area.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: (area.width - size.width) / 2, y: (area.height - size.height) / 2, width: size.width, height: size.height)
    }

    @ViewBuilder
    private func content(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            if let text = controller.text {
                #if os(tvOS)
                let size = min(max(width * 0.03, 28), 56)
                #else
                let size = min(max(width * 0.034, 15), 40)
                #endif
                Text(text)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    // Outline made of four tight shadows: readable on any background without a box.
                    .shadow(color: .black, radius: 0, x: 1.5, y: 1.5)
                    .shadow(color: .black, radius: 0, x: -1.5, y: -1.5)
                    .shadow(color: .black, radius: 0, x: 1.5, y: -1.5)
                    .shadow(color: .black, radius: 0, x: -1.5, y: 1.5)
                    .padding(.horizontal, width * 0.08)
                    .padding(.bottom, height * 0.07)
                    .frame(width: width, height: height, alignment: .bottom)
                    .transaction { $0.animation = nil }
            }
        }
    }
}
