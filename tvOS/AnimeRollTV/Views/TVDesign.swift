import AnimeRollKit
import SwiftUI

/// Shared tvOS pieces of the AnimeRoll design system (10 ft sizes of the same tokens).

/// Focusable poster: portrait or wide, optional badge, meta line, progress line.
struct TVPoster: View {
    let title: String
    let url: URL?
    var badge: String? = nil
    var meta: String? = nil
    var progress: Double? = nil
    var wide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { DS.surface }
                .frame(width: wide ? 480 : 260, height: wide ? 270 : 390)
                .clipShape(.rect(cornerRadius: DS.rPoster))
                .overlay(alignment: .topLeading) { if let badge { TVBadge(text: badge).padding(12) } }
                .overlay(alignment: .bottom) {
                    if let progress {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.2))
                                Rectangle().fill(DS.accent).frame(width: g.size.width * progress)
                            }
                        }
                        .frame(height: 6).clipShape(.rect(cornerRadius: 3)).padding(10)
                    }
                }
            Text(title).font(DS.body(24, 600)).lineLimit(1).frame(width: wide ? 480 : 260, alignment: .leading)
            if let meta { Text(meta).font(DS.body(20)).foregroundStyle(DS.textTertiary).lineLimit(1).frame(width: wide ? 480 : 260, alignment: .leading) }
        }
    }
}

/// Top 10: big outlined rank number next to the poster.
struct TVRankedPoster: View {
    let rank: Int
    let title: String
    let url: URL?

    var body: some View {
        HStack(alignment: .bottom, spacing: -24) {
            Text("\(rank)").font(DS.display(150, 800)).foregroundStyle(DS.background)
                .shadow(color: DS.accent, radius: 0, x: 3, y: 3).shadow(color: DS.accent, radius: 0, x: -3, y: -3)
                .shadow(color: DS.accent, radius: 0, x: 3, y: -3).shadow(color: DS.accent, radius: 0, x: -3, y: 3)
                .frame(minWidth: 110, alignment: .trailing).offset(y: 30)
            TVPoster(title: title, url: url)
        }
    }
}

struct TVBadge: View {
    let text: String
    var tint: Color = DS.accent
    var body: some View {
        Text(text.uppercased()).font(DS.display(18, 700)).tracking(1.4).foregroundStyle(DS.onAccent)
            .padding(.horizontal, 12).padding(.vertical, 4).background(tint, in: .rect(cornerRadius: DS.rBadge))
    }
}

struct TVShelf<Item: Hashable, Content: View>: View {
    let title: String
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(DS.display(36, 700)).padding(.leading, 80)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 40) { ForEach(items, id: \.self) { content($0) } }
                        .padding(.horizontal, 80).padding(.vertical, 30)
                }
                .scrollClipDisabled()
            }
        }
    }
}

/// Genre / season / source chip for the remote: accent when selected.
struct TVChip: View {
    let title: String
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(DS.body(26, 600)).padding(.horizontal, 12)
                .foregroundStyle(selected ? DS.onAccent : .white)
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(selected ? DS.accent : nil)
    }
}

/// Screen title + optional subtitle.
struct TVScreenTitle: View {
    let text: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(DS.display(64, 800))
            if let subtitle { Text(subtitle).font(DS.body(26)).foregroundStyle(DS.textTertiary) }
        }
    }
}

/// Group card of the Profilo screen.
struct TVGroup<Content: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).font(DS.body(22, 700)).tracking(2).foregroundStyle(DS.textTertiary)
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.surface, in: .rect(cornerRadius: DS.rCard))
            if let note { Text(note).font(DS.body(20)).foregroundStyle(DS.textTertiary) }
        }
    }
}

struct TVRow: View {
    let icon: String
    let label: String
    var value: String? = nil
    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: icon).foregroundStyle(DS.textSecondary).frame(width: 40)
            Text(label).font(DS.body(28, 500))
            Spacer()
            if let value { Text(value).font(DS.body(26)).foregroundStyle(DS.textTertiary) }
        }
        .padding(.horizontal, 28).frame(minHeight: 84)
    }
}

enum AniListStatusLabel {
    static func text(_ s: String) -> String {
        ["CURRENT": "In corso", "PLANNING": "Pianificato", "COMPLETED": "Completato", "PAUSED": "In pausa",
         "DROPPED": "Abbandonato", "REPEATING": "Rewatch"][s] ?? s
    }
}
