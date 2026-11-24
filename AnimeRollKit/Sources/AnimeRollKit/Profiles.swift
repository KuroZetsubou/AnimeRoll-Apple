import SwiftUI

/// Round avatar: one of the 8 palette colours plus the initial of the name (same as the web client).
public struct AvatarView: View {
    let name: String
    let index: Int
    let size: CGFloat
    public init(name: String, index: Int, size: CGFloat = 40) { self.name = name; self.index = index; self.size = size }
    public var body: some View {
        Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
            .font(DS.display(size * 0.46, 700))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(AvatarPalette.color(index), in: .circle)
            .accessibilityHidden(true)
    }
}
