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
            Group {
                if controller.usesAss, let image = controller.assImage {
                    Image(decorative: image, scale: 1).resizable().frame(width: rect.width, height: rect.height)
                } else {
                    content(width: rect.width, height: rect.height)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .onChange(of: rect.size, initial: true) { _, size in controller.setRenderSize(Self.pixels(size)) }
        }
        .allowsHitTesting(false)
    }

    /// libass draws at screen resolution, capped so heavy signs stay cheap.
    static func pixels(_ size: CGSize) -> CGSize {
        #if os(tvOS)
        let scale: CGFloat = 1
        #else
        let scale: CGFloat = 2
        #endif
        let w = min(size.width * scale, 1920)
        let k = size.width > 0 ? w / size.width : 1
        return CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
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
        #if os(tvOS)
        let size = min(max(width * 0.03, 28), 56)
        #else
        let size = min(max(width * 0.034, 15), 40)
        #endif
        let plain = controller.active.filter { $0.layout == nil }
        let placed = controller.active.filter { $0.layout != nil }
        ZStack {
            if !plain.isEmpty {
                label(plain.dropFirst().reduce(plain[0].text) { $0 + AttributedString("\n") + $1.text }, size: size, align: .center)
                    .padding(.horizontal, width * 0.08)
                    .padding(.bottom, height * 0.07)
                    .frame(width: width, height: height, alignment: .bottom)
            }
            ForEach(Array(placed.enumerated()), id: \.offset) { _, cue in
                if let l = cue.layout {
                    CueAnchor(layout: l, area: CGSize(width: width, height: height)) {
                        label(cue.text, size: size, align: l.align == .left ? .leading : l.align == .right ? .trailing : .center)
                    }
                    .frame(width: width, height: height)
                }
            }
        }
        .transaction { $0.animation = nil }
    }

    private func label(_ text: AttributedString, size: CGFloat, align: TextAlignment) -> some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(align)
            // Outline made of four tight shadows: readable on any background without a box.
            .shadow(color: .black, radius: 0, x: 1.5, y: 1.5)
            .shadow(color: .black, radius: 0, x: -1.5, y: -1.5)
            .shadow(color: .black, radius: 0, x: 1.5, y: -1.5)
            .shadow(color: .black, radius: 0, x: -1.5, y: 1.5)
    }
}

/// Puts one cue where its WebVTT settings say: the box is `size` wide (default 90%), its left / center / right edge
/// sits at `position` and its top / middle / bottom at `line`, then it is kept inside the picture.
private struct CueAnchor<Content: View>: View {
    let layout: CueLayout
    let area: CGSize
    @ViewBuilder let content: Content

    var body: some View {
        AnchorLayout(layout: layout, area: area) { content }
    }
}

private struct AnchorLayout: Layout {
    let layout: CueLayout
    let area: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { area }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let maxWidth = area.width * (layout.size ?? 0.9)
        let size = view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        let ax: CGFloat = layout.align == .left ? 0 : layout.align == .right ? 1 : 0.5
        let defaultX: CGFloat = layout.align == .left ? 0.04 : layout.align == .right ? 0.96 : 0.5
        let x = (layout.position ?? defaultX) * area.width
        let ay: CGFloat = layout.lineAnchor == .start ? 0 : layout.lineAnchor == .center ? 0.5 : 1
        let y = (layout.line ?? 0.93) * area.height
        var origin = CGPoint(x: x - size.width * ax, y: y - size.height * ay)
        origin.x = min(max(origin.x, area.width * 0.01), max(area.width * 0.99 - size.width, 0))
        origin.y = min(max(origin.y, area.height * 0.01), max(area.height * 0.99 - size.height, 0))
        view.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), anchor: .topLeading,
                   proposal: ProposedViewSize(width: size.width, height: size.height))
    }
}
