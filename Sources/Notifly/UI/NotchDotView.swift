import SwiftUI

/// The dot itself: a small muted circle when nothing is waiting, a capsule
/// carrying the number when something is.
///
/// The colour carries one extra piece of information. When everything waiting
/// is noise — reactions on things you sent, likes — the dot drains to grey. Full
/// Instagram colour means a person actually wrote to you. That is the whole
/// point of the app: answering "does this need me?" without opening anything.
struct NotchDotView: View {
    let count: Int
    /// False when the total is made up entirely of reactions, likes and such.
    let hasSubstance: Bool
    let state: FeedState
    let dotSize: CGFloat
    let menuBarHeight: CGFloat
    let progress: CGFloat
    let scale: CGFloat
    let showCountAtRest: Bool
    let ambientBreathing: Bool
    let arrivalTick: Int

    @State private var glowPhase: CGFloat = 0

    private var accent: Accent { hasSubstance ? .instagram : .quiet }
    private var isLit: Bool { count > 0 }
    private var countText: String { DotGeometry.countText(count) }

    private var restHeight: CGFloat {
        DotGeometry.restHeight(count: count, height: dotSize, showCount: showCountAtRest)
    }

    private var height: CGFloat {
        DotGeometry.renderHeight(rest: restHeight, full: dotSize, progress: progress, scale: scale)
    }

    private var width: CGFloat {
        let rest = DotGeometry.restWidth(countText: countText, count: count,
                                         height: dotSize, showCount: showCountAtRest)
        let active = DotGeometry.activeWidth(countText: countText, count: count, height: dotSize)
        return (rest + (active - rest) * progress) * scale
    }

    /// Reference size every internal metric derives from, so text and mark grow
    /// exactly in step with the capsule instead of being scaled bitmaps.
    private var metric: CGFloat { dotSize * scale }

    /// Square canvas for the colour field, sized for a four-digit capsule so it
    /// can never run out from under the tile however long the number gets.
    private var fieldSide: CGFloat {
        max(width, height, DotGeometry.capsuleWidth(digits: 4, height: metric)) * 1.15
    }

    private var showsCount: Bool {
        count > 0 && (showCountAtRest || progress > 0.05)
    }

    var body: some View {
        ZStack {
            ArrivalRipple(tick: arrivalTick, color: accent.glow)
            statusRing
            content
        }
        .frame(width: width, height: height)
        // Behind, not inside: the fill keeps its own square size while the
        // capsule keeps the layout size, and the clip below trims the overlap.
        .background(alignment: .center) { fillLayer }
        .overlay { specularHighlight }
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(isLit ? Color.white.opacity(0.22) : Palette.hairline,
                              lineWidth: max(0.5, 0.5 * scale))
        )
        .shadow(color: accent.glow.opacity(isLit ? 0.30 + 0.32 * glowPhase : 0),
                radius: (5 + 4 * glowPhase) * scale)
        .shadow(color: .black.opacity(0.45), radius: 3 * scale, x: 0, y: 1 * scale)
        .onChange(of: isLit, initial: true) { _, lit in
            if lit {
                withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) {
                    glowPhase = 1
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) { glowPhase = 0 }
            }
        }
    }

    @ViewBuilder
    private var fillLayer: some View {
        if isLit {
            AuroraFill(accent: accent, side: fieldSide)
        } else if state == .needsAuth {
            Palette.surface
        } else {
            Palette.idle
                .opacity(0.55 + 0.30 * progress)
                .breathe(active: ambientBreathing, from: 0.92, to: 1.06, period: 4.2)
        }
    }

    @ViewBuilder
    private var specularHighlight: some View {
        if isLit {
            RadialGradient(colors: [.white.opacity(0.30), .clear],
                           center: .init(x: 0.30, y: 0.18),
                           startRadius: 0,
                           endRadius: max(width, height) * 0.75)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var statusRing: some View {
        switch state {
        case .loading:
            arc(color: Palette.textLo.opacity(0.8), period: 1.1)
        case .needsAuth:
            arc(color: Palette.warning, period: 2.6)
        default:
            EmptyView()
        }
    }

    private func arc(color: Color, period: Double) -> some View {
        Circle()
            .trim(from: 0, to: 0.3)
            .stroke(color, style: .init(lineWidth: max(1, 1.4 * scale), lineCap: .round))
            .padding(max(0.75, 1.2 * scale))
            .spin(active: true, period: period)
            .frame(width: min(width, height), height: min(width, height))
    }

    @ViewBuilder
    private var content: some View {
        HStack(spacing: dotSize * 0.22 * scale * progress) {
            if progress > 0.01 {
                GlyphView(glyph: .instagram,
                          size: DotGeometry.glyphSize(height: metric) * progress,
                          color: .white.opacity(isLit ? 0.98 : 0.85))
                    .opacity(Double(min(1, progress * 1.6)))
            }
            if showsCount {
                Text(countText)
                    .font(.system(size: DotGeometry.fontSize(height: metric),
                                  weight: .bold,
                                  design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 0.5 * scale, y: 0.5)
                    .fixedSize()
                    .lineLimit(1)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
    }
}

/// Expanding ring fired when the total goes up.
private struct ArrivalRipple: View {
    let tick: Int
    let color: Color
    @State private var t: CGFloat = 1

    var body: some View {
        Capsule(style: .continuous)
            .strokeBorder(color.opacity(Double(1 - t) * 0.85), lineWidth: 1.5)
            .scaleEffect(1 + t * 1.4)
            .opacity(t >= 1 ? 0 : 1)
            .onChange(of: tick) { _, _ in
                t = 0
                withAnimation(.easeOut(duration: 0.85)) { t = 1 }
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Reusable looping animations

private struct Spin: ViewModifier {
    let active: Bool
    let period: Double
    @State private var angle: Double = 0

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(angle))
            .onChange(of: active, initial: true) { _, on in
                if on {
                    withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) {
                        angle = 360
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.25)) { angle = 0 }
                }
            }
    }
}

private struct Breathe: ViewModifier {
    let active: Bool
    let from: CGFloat
    let to: CGFloat
    let period: Double
    @State private var value: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(value)
            .onChange(of: active, initial: true) { _, on in
                if on {
                    value = from
                    withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) {
                        value = to
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.3)) { value = 1 }
                }
            }
    }
}

extension View {
    /// Continuous rotation. Runs on Core Animation, so it costs no main-thread work.
    func spin(active: Bool, period: Double) -> some View {
        modifier(Spin(active: active, period: period))
    }

    /// Gentle scale oscillation.
    func breathe(active: Bool, from: CGFloat, to: CGFloat, period: Double) -> some View {
        modifier(Breathe(active: active, from: from, to: to, period: period))
    }
}
