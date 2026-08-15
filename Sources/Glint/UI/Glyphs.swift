import SwiftUI

/// Marks drawn as simple geometry, so they stay crisp at any scale and carry no
/// bitmap assets.
enum Glyph: Equatable {
    case instagram
    case symbol(String)   // SF Symbol name
}

struct GlyphView: View {
    let glyph: Glyph
    let size: CGFloat
    var color: Color = .white

    var body: some View {
        switch glyph {
        case .instagram: instagram
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.78, weight: .bold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
        }
    }

    /// Rounded square + ring + corner pip.
    private var instagram: some View {
        let line = max(1, size * 0.115)
        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .strokeBorder(color, lineWidth: line)
            Circle()
                .strokeBorder(color, lineWidth: line)
                .frame(width: size * 0.44, height: size * 0.44)
            Circle()
                .fill(color)
                .frame(width: line * 1.5, height: line * 1.5)
                .offset(x: size * 0.21, y: -size * 0.21)
        }
        .frame(width: size, height: size)
    }
}
