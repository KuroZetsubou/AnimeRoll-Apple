import AnimeRollKit
import SwiftUI

enum Theme {
    static let accent = Color(red: 1.0, green: 0.45, blue: 0.2)
    static let background = Color(red: 0.06, green: 0.06, blue: 0.08)
    static let card = Color.white.opacity(0.08)
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

/// Netflix-style vertical poster.
struct PosterCard: View {
    let title: String
    let url: URL?
    var badge: String? = nil
    var width: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: url)
                .frame(width: width, height: width * 1.5)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if let badge {
                        Text(badge).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Theme.accent, in: .capsule).padding(6)
                    }
                }
            Text(title).font(.caption).lineLimit(2).frame(width: width, alignment: .leading)
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
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title3.bold()).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items, id: \.self) { content($0) }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

struct ProgressLine: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(Theme.accent).frame(width: g.size.width * value)
            }
        }
        .frame(height: 3)
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote).foregroundStyle(.white)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.8), in: .rect(cornerRadius: 10))
            .padding(.horizontal)
    }
}

extension Int64 {
    var fileSize: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension Double {
    var durationLabel: String {
        let m = Int(self) / 60
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m) min"
    }
}
