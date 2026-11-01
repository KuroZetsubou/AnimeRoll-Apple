import CoreText
import SwiftUI

/// AnimeRoll design system tokens shared by the iOS and tvOS apps:
/// colors, type (Outfit for display, Figtree for body), radii, spacing and motion.
public enum DS {
    // MARK: Color
    public static let orange400 = Color(hex: 0xFF8A4C)
    public static let orange500 = Color(hex: 0xFF6A1F)
    public static let orange600 = Color(hex: 0xE5530A)
    public static let ink950 = Color(hex: 0x0A0A0D)
    public static let ink900 = Color(hex: 0x111116)
    public static let ink800 = Color(hex: 0x1A1A21)
    public static let ink700 = Color(hex: 0x24242D)
    public static let ink600 = Color(hex: 0x32323E)
    public static let ink400 = Color(hex: 0x7A7A8A)
    public static let ink300 = Color(hex: 0xA8A8B6)
    public static let teal = Color(hex: 0x2BD4BD)
    public static let yellow = Color(hex: 0xFFC93C)
    public static let pink = Color(hex: 0xFF4D7E)
    public static let green = Color(hex: 0x3DDC84)

    public static let accent = orange500
    public static let accentSoft = orange500.opacity(0.16)
    public static let background = ink950
    public static let surface = ink800          // cards, placeholders
    public static let surfaceRaised = ink700    // secondary buttons, selected segment
    public static let textPrimary = Color.white
    public static let textSecondary = ink300
    public static let textTertiary = ink400
    public static let onAccent = ink950
    public static let hairline = Color.white.opacity(0.08)
    public static let borderStrong = Color.white.opacity(0.18)

    /// Protection gradient at the bottom of key art.
    public static let scrimBottom = LinearGradient(
        stops: [.init(color: ink950.opacity(0), location: 0), .init(color: ink950.opacity(0.6), location: 0.55), .init(color: ink950.opacity(0.97), location: 1)],
        startPoint: .top, endPoint: .bottom)

    // MARK: Radii and spacing
    public static let rBadge: CGFloat = 6
    public static let rPoster: CGFloat = 10
    public static let rCard: CGFloat = 14
    public static let rHero: CGFloat = 20
    public static let rSheet: CGFloat = 28
    public static let side: CGFloat = 16

    // MARK: Motion (120 / 220 / 420 ms, ease-out)
    public static let fast = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.12)
    public static let base = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)
    public static let slow = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.42)

    // MARK: Type
    /// Outfit (display, buttons, titles): weights 600 to 800.
    public static func display(_ size: CGFloat, _ weight: CGFloat = 700) -> Font { font("Outfit", size, weight) }
    /// Figtree (body): weights 400 to 700.
    public static func body(_ size: CGFloat, _ weight: CGFloat = 400) -> Font { font("Figtree", size, weight) }

    private static func font(_ family: String, _ size: CGFloat, _ weight: CGFloat) -> Font {
        registerFonts()
        let wght = 0x77676874   // 'wght' axis
        let desc = UIFontDescriptor(fontAttributes: [.family: family, kCTFontVariationAttribute as UIFontDescriptor.AttributeName: [wght: weight]])
        return Font(UIFont(descriptor: desc, size: size))
    }

    private static let registered: Void = {
        for name in ["Outfit", "Figtree"] {
            if let url = Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()
    /// Called on first use; apps may also call it at launch.
    public static func registerFonts() { _ = registered }
}

public extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
