import SwiftUI

/// Per-source mark drawn inside the magnified capsule. Kept as simple geometry
/// so it stays crisp at any scale and carries no bitmap assets.
enum Glyph: Equatable {
    case instagram
    case whatsapp
    case symbol(String)   // SF Symbol name
}

struct GlyphView: View {
    let glyph: Glyph
    let size: CGFloat
    var color: Color = .white

    var body: some View {
        switch glyph {
        case .instagram: instagram
        case .whatsapp:  whatsapp
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.78, weight: .bold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
        }
    }

    // Rounded square + ring + corner pip.
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

    // Speech bubble with a tail, handset inside.
    private var whatsapp: some View {
        let line = max(1, size * 0.115)
        return ZStack {
            BubbleShape()
                .strokeBorder(color, lineWidth: line)
            Image(systemName: "phone.fill")
                .font(.system(size: size * 0.38, weight: .black))
                .foregroundStyle(color)
                .offset(y: -size * 0.03)
        }
        .frame(width: size, height: size)
    }
}

/// Circle with a small tail at the lower-left, drawn as an InsettableShape so it
/// can be stroked from the border inward without clipping.
private struct BubbleShape: InsettableShape {
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> BubbleShape {
        BubbleShape(inset: inset + amount)
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let radius = min(r.width, r.height) / 2
        let center = CGPoint(x: r.midX, y: r.midY)
        var p = Path()
        // Leave a gap at the lower-left where the tail joins.
        p.addArc(center: center, radius: radius,
                 startAngle: .degrees(125), endAngle: .degrees(100),
                 clockwise: false)
        let tip = CGPoint(x: r.minX + radius * 0.10, y: r.maxY - radius * 0.02)
        p.addLine(to: tip)
        p.closeSubpath()
        return p
    }
}
