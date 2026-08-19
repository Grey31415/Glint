import SwiftUI

/// What sits *inside* the surface while it is still dot-shaped: the number, the
/// service mark once magnified, and the arc for states that are neither quiet
/// nor lit. The surface itself - shape, glass, colour, glow - is drawn by
/// `MorphingSurface`, because the dot and the menu are the same object.
struct DotContentView: View {
    let count: Int
    let state: FeedState
    let dotSize: CGFloat
    let progress: CGFloat
    let scale: CGFloat
    let showCountAtRest: Bool
    let arrivalTick: Int
    let accentGlow: Color
    let animated: Bool

    /// Reference size every internal metric derives from, so text and mark grow
    /// exactly in step with the capsule instead of being scaled bitmaps.
    ///
    /// The dot's height *now*, which is only `dotSize * scale` once the
    /// approach has finished. With the number hidden at rest the dot starts as
    /// a small circle and grows into a capsule, so digits sized from the full
    /// dot arrived wider than the shape holding them - see
    /// `DotGeometry.renderWidth`, which sizes that shape from the same number.
    private var metric: CGFloat {
        DotGeometry.renderHeight(rest: DotGeometry.restHeight(count: count,
                                                              height: dotSize,
                                                              showCount: showCountAtRest),
                                 full: dotSize,
                                 progress: progress,
                                 scale: scale)
    }
    private var countText: String { DotGeometry.countText(count) }

    /// How much of the number is on screen. The capsule reads the same figure,
    /// so it is never asked to hold a number it has no room for.
    private var reveal: CGFloat {
        DotGeometry.countReveal(count: count, showCount: showCountAtRest, progress: progress)
    }

    var body: some View {
        ZStack {
            if animated {
                ArrivalRipple(tick: arrivalTick, color: accentGlow)
            }
            statusRing
            // No service mark here. It only appeared mid-hover, which read as
            // clutter arriving and leaving for no reason; the number alone is
            // what the dot is for.
            HStack(spacing: 0) {
                if reveal > 0 {
                    Text(countText)
                        .font(.system(size: DotGeometry.fontSize(height: metric),
                                      weight: .bold,
                                      design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 0.5 * scale, y: 0.5)
                        .fixedSize()
                        .lineLimit(1)
                        // Lifts the digits off the line box's descender space,
                        // which they never use, and onto the dot's real centre.
                        .offset(y: -DotGeometry.countLift(height: metric))
                        // Driven by proximity rather than by a transition: the
                        // capsule's width is mixed in on the same ramp, and a
                        // transition running on its own clock would put the
                        // digits at full size inside a shape still growing.
                        .scaleEffect(0.4 + 0.6 * reveal)
                        .opacity(Double(reveal))
                }
            }
        }
    }

    @ViewBuilder
    private var statusRing: some View {
        switch state {
        case .loading:
            arc(color: Palette.textLo.opacity(0.8), period: 1.1)
        case .needsAuth:
            arc(color: Palette.warning, period: 2.6)
        case .offline:
            // Dimmer and slower than the signed-out ring. Nothing is wrong with
            // Glint or your account, and a dot that looks alarmed about the
            // café wifi would be crying wolf - but a count nobody is refreshing
            // has to look different from a live one.
            arc(color: Palette.textLo.opacity(0.75), period: 3.6)
        default:
            EmptyView()
        }
    }

    /// The modifier is dropped entirely rather than handed `active: false`. A
    /// `repeatForever` animation can outlive the value change meant to end it,
    /// so the only certain stop is to remove the view that owns it.
    @ViewBuilder
    private func arc(color: Color, period: Double) -> some View {
        let ring = Circle()
            .trim(from: 0, to: 0.3)
            .stroke(color, style: .init(lineWidth: max(1, 1.4 * scale), lineCap: .round))
            .padding(max(0.75, 1.2 * scale))

        if animated {
            ring.spin(active: true, period: period)
                .frame(width: metric, height: metric)
        } else {
            ring.frame(width: metric, height: metric)
        }
    }
}

/// Expanding ring fired when the total goes up.
struct ArrivalRipple: View {
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
