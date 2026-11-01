import AnimeRollKit
import SwiftUI

/// App-level aliases for the shared design system (AnimeRollKit/DesignSystem.swift).
enum Theme {
    static let accent = DS.accent
    static let background = DS.background
    static let card = DS.surface
    static let surfaceStrong = DS.surfaceRaised
    static let textSecondary = DS.textSecondary
    static let textTertiary = DS.textTertiary
    static let heroGradient = LinearGradient(colors: [Color(hex: 0x3A1A0B).opacity(0.55), background], startPoint: .top, endPoint: .bottom)
}

/// Light haptic tick for tab changes, Play, downloads, chips.
@MainActor enum Haptics {
    private static let generator = UIImpactFeedbackGenerator(style: .light)
    static func tick() { generator.impactOccurred() }
}

/// Primary pill button (accent, dark text) and the raised secondary one.
struct PrimaryButtonStyle: ButtonStyle {
    var prominent = true
    var small = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.display(small ? 13 : 15, 700))
            .padding(.horizontal, small ? 14 : 20)
            .frame(height: small ? 36 : 46)
            .frame(maxWidth: small ? nil : .infinity)
            .foregroundStyle(prominent ? DS.onAccent : .white)
            .background(prominent ? (configuration.isPressed ? DS.orange600 : DS.accent) : DS.surfaceRaised, in: .capsule)
            .overlay(Capsule().strokeBorder(prominent ? .clear : DS.hairline))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(DS.fast, value: configuration.isPressed)
    }
}

/// Rounded chip: accent when selected, outline otherwise.
struct Chip: View {
    let title: String
    var selected = false
    var trailingIcon: String? = nil
    let action: () -> Void

    var body: some View {
        Button { Haptics.tick(); action() } label: {
            HStack(spacing: 4) {
                Text(title)
                if let trailingIcon { Image(systemName: trailingIcon).font(.caption2.bold()) }
            }
            .font(DS.body(14, 600))
            .padding(.horizontal, 16).frame(height: 36)
            .foregroundStyle(selected ? DS.onAccent : .white)
            .background(selected ? DS.accent : .clear, in: .capsule)
            .overlay(Capsule().strokeBorder(selected ? DS.accent : DS.borderStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Uppercase badge (NAS, 12 ep).
struct BadgeLabel: View {
    let text: String
    var tint: Color = DS.accent
    var body: some View {
        Text(text.uppercased()).font(DS.display(11, 700)).tracking(0.9).foregroundStyle(DS.onAccent)
            .padding(.horizontal, 8).frame(height: 20).background(tint, in: .rect(cornerRadius: DS.rBadge))
    }
}

/// Screen title (Outfit 32 extra bold).
struct ScreenTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text).font(DS.display(32, 800)).foregroundStyle(.white) }
}

/// Pill segmented control.
struct PillSegmented: View {
    let options: [String]
    @Binding var selection: Int
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                Button { Haptics.tick(); withAnimation(DS.base) { selection = i } } label: {
                    Text(options[i]).font(DS.body(14, 600)).frame(maxWidth: .infinity).frame(height: 34)
                        .foregroundStyle(i == selection ? .white : DS.textTertiary)
                        .background(i == selection ? DS.surfaceRaised : .clear, in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3).background(DS.surface, in: .capsule).overlay(Capsule().strokeBorder(DS.hairline))
    }
}

/// Icon over a small label (detail page action row).
struct IconAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button { Haptics.tick(); action() } label: {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.title3).frame(height: 24)
                Text(title).font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

/// Remote image with a neutral placeholder.
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    var body: some View {
        AsyncImage(url: url, transaction: .init(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: contentMode)
            default: Rectangle().fill(Theme.card).overlay { Image(systemName: "film").foregroundStyle(.secondary) }
            }
        }
        .clipped()
    }
}

/// Vertical poster with optional badge and meta line.
struct PosterCard: View {
    let title: String
    let url: URL?
    var badge: String? = nil
    var meta: String? = nil
    var width: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RemoteImage(url: url)
                .frame(width: width, height: width * 1.5)
                .clipShape(.rect(cornerRadius: DS.rPoster))
                .shadow(color: .black.opacity(0.45), radius: 9, y: 4)
                .overlay(alignment: .topLeading) { if let badge { BadgeLabel(text: badge).padding(8) } }
            Text(title).font(DS.body(13, 600)).lineLimit(2).frame(width: width, alignment: .leading).padding(.top, 8)
            if let meta { Text(meta).font(DS.body(12)).foregroundStyle(DS.textTertiary).lineLimit(1).frame(width: width, alignment: .leading).padding(.top, 2) }
        }
    }
}

/// Horizontal row with a title, like Netflix shelves.
struct Shelf<Item: Hashable, Content: View>: View {
    let title: String
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(DS.display(20, 700)).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 8) {
                        ForEach(items, id: \.self) { content($0) }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

/// "Top 10" poster: big rank number with an orange outline next to the poster.
struct RankedPoster: View {
    let rank: Int
    let url: URL?

    var body: some View {
        HStack(alignment: .bottom, spacing: -12) {
            Text("\(rank)")
                .font(DS.display(72, 800))
                .foregroundStyle(DS.background)
                .shadow(color: DS.accent, radius: 0, x: 1.5, y: 1.5).shadow(color: DS.accent, radius: 0, x: -1.5, y: -1.5)
                .shadow(color: DS.accent, radius: 0, x: 1.5, y: -1.5).shadow(color: DS.accent, radius: 0, x: -1.5, y: 1.5)
                .frame(minWidth: 44, alignment: .trailing)
                .offset(y: 14)
            RemoteImage(url: url).frame(width: 112, height: 168).clipShape(.rect(cornerRadius: DS.rPoster))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Numero \(rank)")
    }
}


struct ProgressLine: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule().fill(Theme.accent).frame(width: g.size.width * value)
            }
        }
        .frame(height: 4)
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote).foregroundStyle(.white)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.pink.opacity(0.85), in: .rect(cornerRadius: DS.rCard))
            .padding(.horizontal)
    }
}

extension View {
    /// Liquid Glass on iOS 26+, a blurred translucent capsule before.
    @ViewBuilder func glassCapsule() -> some View {
        if #available(iOS 26.0, *) { glassEffect(.regular, in: .capsule) }
        else { background(.ultraThinMaterial, in: .capsule).overlay(Capsule().strokeBorder(.white.opacity(0.14))) }
    }
}

/// Small outlined pill (Pausa tutto, Pulisci, Avvia subito).
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.display(13, 700)).padding(.horizontal, 14).frame(height: 36)
            .foregroundStyle(.white)
            .background(configuration.isPressed ? Color.white.opacity(0.08) : .clear, in: .capsule)
            .overlay(Capsule().strokeBorder(DS.borderStrong))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

extension View {
    /// Round glass button background (back chevron, big play).
    @ViewBuilder func glassCircle() -> some View {
        if #available(iOS 26.0, *) { glassEffect(.regular.interactive(), in: .circle) }
        else { background(.ultraThinMaterial, in: .circle).overlay(Circle().strokeBorder(.white.opacity(0.3))) }
    }
}
