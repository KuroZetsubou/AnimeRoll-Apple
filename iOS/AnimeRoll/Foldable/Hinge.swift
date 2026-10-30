import SwiftUI
import UIKit

/// How the foldable is being held, derived from the hinge (iOS 27.1+ `UIHingeInteraction`)
/// and the screen shape.
enum FoldPosture: Equatable {
    /// No hinge (regular iPhone, iPad, iOS < 27.1).
    case none
    /// Folded: the app runs on the outer screen.
    case closed
    /// Fully open and flat: one big screen with the crease in the middle.
    case flat
    /// Half open with the crease horizontal (held like a small laptop / standing on a table):
    /// top half for the video, bottom half for controls.
    case tabletop
    /// Half open with the crease vertical (held like a book): left half / right half.
    case book

    var isHalfOpen: Bool { self == .tabletop || self == .book }
}

/// Live hinge state for the whole app.
@MainActor
@Observable
final class HingeMonitor {
    static let shared = HingeMonitor()

    enum Status: Equatable { case unavailable, unknown, closed, partiallyOpen, fullyOpen }

    private(set) var status: Status = .unavailable
    /// Hinge angle in degrees (180 = flat), when the system provides it.
    private(set) var angle: Double?

    var hasHinge: Bool { status != .unavailable }

    private init() {
        #if DEBUG
        // Dev only: SIMCTL_CHILD_AR_DEBUG_HINGE=closed|partial|open to try the layouts in the simulator.
        switch ProcessInfo.processInfo.environment["AR_DEBUG_HINGE"] {
        case "closed": status = .closed; angle = 0; forced = true
        case "partial": status = .partiallyOpen; angle = 100; forced = true
        case "open": status = .fullyOpen; angle = 180; forced = true
        default: break
        }
        #endif
    }

    @ObservationIgnored private var forced = false

    func update(status: Status, angleRadians: Double?) {
        guard !forced else { return }
        self.status = status
        angle = angleRadians.map { $0 * 180 / .pi }
    }

    /// The crease runs vertically when the open device is held upright (taller than wide)
    /// and horizontally once it's turned sideways.
    func posture(in size: CGSize) -> FoldPosture {
        switch status {
        case .unavailable, .unknown: return .none
        case .closed: return .closed
        case .fullyOpen: return .flat
        case .partiallyOpen: return size.width > size.height ? .tabletop : .book
        }
    }
}

/// Invisible view that hosts the UIHingeInteraction. Put it once near the root.
struct HingeReader: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        if #available(iOS 27.1, *) {
            let interaction = UIHingeInteraction { _, update in
                guard let hinge = update.hinge else {
                    HingeMonitor.shared.update(status: .unavailable, angleRadians: nil)
                    return
                }
                let status: HingeMonitor.Status = switch hinge.status {
                case .closed: .closed
                case .partiallyOpen: .partiallyOpen
                case .fullyOpen: .fullyOpen
                default: .unknown
                }
                HingeMonitor.shared.update(status: status, angleRadians: Double(hinge.angle))
            }
            view.addInteraction(interaction)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct FoldPostureKey: EnvironmentKey {
    static let defaultValue: FoldPosture = .none
}

extension EnvironmentValues {
    /// Current posture of a foldable, `.none` elsewhere.
    var foldPosture: FoldPosture {
        get { self[FoldPostureKey.self] }
        set { self[FoldPostureKey.self] = newValue }
    }
}

extension View {
    /// Reads the hinge and publishes `\.foldPosture` to everything inside.
    func trackingFoldPosture() -> some View { modifier(FoldPostureModifier()) }
}

private struct FoldPostureModifier: ViewModifier {
    @State private var size: CGSize = .zero
    private var hinge = HingeMonitor.shared

    func body(content: Content) -> some View {
        content
            .environment(\.foldPosture, hinge.posture(in: size))
            .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
            .background(HingeReader().frame(width: 0, height: 0))
            .animation(.smooth, value: hinge.posture(in: size))
    }
}
