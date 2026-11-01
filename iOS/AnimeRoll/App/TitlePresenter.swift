import AnimeRollKit
import SwiftUI

/// How any screen opens a title page. The root installs `TitleSheetHost` (detail as a sheet over
/// the app); the two-pane layout overrides it to show the title in the right pane instead.
struct OpenTitleAction {
    let open: @MainActor (TitleRef) -> Void
    @MainActor func callAsFunction(_ ref: TitleRef) { open(ref) }
}

extension EnvironmentValues {
    @Entry var openTitle = OpenTitleAction { _ in }
    /// Set inside the sheet so the detail can show its close button and track its scroll.
    @Entry var titleSheet: TitleSheetContext? = nil
}

/// Lets the detail tell the sheet whether it is scrolled to the top (drag-to-close only then).
@MainActor @Observable final class TitleSheetContext {
    var atTop = true
    let close: () -> Void
    init(close: @escaping () -> Void) { self.close = close }
}

/// Detail page presented over the app, as in docs/UI-REWORK.md:
/// the app behind scales to 0.92 and dims; drag down (at the top) or right (from the left edge) to close.
struct TitleSheetHost: ViewModifier {
    @State private var presented: TitleRef?
    @State private var drag: CGSize = .zero
    @State private var context: TitleSheetContext?
    @State private var size: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let closeDistance: CGFloat = 120

    func body(content: Content) -> some View {
        ZStack {
                content
                    .environment(\.openTitle, OpenTitleAction { show($0) })
                    .scaleEffect(presented == nil || reduceMotion ? 1 : 0.92 + 0.08 * progress(size))
                    // No clipping while closed: the tab bar and home indicator area must stay visible.
                    .clipShape(SheetBackgroundShape(clipped: presented != nil))
                    .overlay { if presented != nil { Color.black.opacity(0.5 * (1 - progress(size))).ignoresSafeArea() } }
                    .allowsHitTesting(presented == nil)

                if let presented, let context {
                    NavigationStack {
                        TitleDetailView(ref: presented)
                            .environment(\.titleSheet, context)
                            .environment(\.openTitle, OpenTitleAction { show($0) })
                    }
                    .id(presented)
                    .clipShape(.rect(cornerRadius: DS.rSheet))
                    .offset(x: max(0, drag.width), y: max(0, drag.height))
                    .simultaneousGesture(closeGesture)
                    .transition(.move(edge: .bottom))
                    .ignoresSafeArea(edges: .bottom)
                    .zIndex(1)
                }
        }
        .background(Color.black.ignoresSafeArea())
        .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .showDownloads)) { _ in close() }
    }

    /// 0 while the sheet is fully open, 1 when dragged to the closing point.
    private func progress(_ size: CGSize) -> CGFloat {
        min(1, max(drag.height, drag.width, 0) / max(size.height * 0.5, 1))
    }

    private var closeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                let fromLeftEdge = v.startLocation.x < 30 && abs(v.translation.width) > abs(v.translation.height)
                let downAtTop = (context?.atTop ?? true) && v.translation.height > 0 && abs(v.translation.height) > abs(v.translation.width)
                if fromLeftEdge { drag = CGSize(width: v.translation.width, height: 0) }
                else if downAtTop { drag = CGSize(width: 0, height: v.translation.height) }
            }
            .onEnded { _ in
                if max(drag.width, drag.height) > Self.closeDistance { close() }
                else { withAnimation(.easeOut(duration: 0.3)) { drag = .zero } }
            }
    }

    private func show(_ ref: TitleRef) {
        Haptics.tick()
        drag = .zero
        context = TitleSheetContext { [self] in close() }
        withAnimation(.easeOut(duration: 0.35)) { presented = ref }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.3)) { presented = nil; drag = .zero }
    }
}

/// Rounded clip while a title sheet is open; while closed it reaches far outside the view,
/// so nothing (tab bar, safe areas) is cut.
private struct SheetBackgroundShape: Shape {
    var clipped: Bool
    func path(in rect: CGRect) -> Path {
        clipped ? Path(roundedRect: rect, cornerRadius: 16) : Path(rect.insetBy(dx: -2000, dy: -2000))
    }
}
