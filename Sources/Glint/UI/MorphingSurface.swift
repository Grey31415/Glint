import SwiftUI

/// The dot and the menu are one surface.
///
/// Rather than a dot that disappears and a panel that appears, this is a single
/// shape whose rectangle and corner radius interpolate between the two: the
/// dot's own edges stretch into the menu's edges, and its top and notch-side
/// borders never move at all. The contents cross-fade inside it while the
/// geometry does the work.
struct MorphingSurface<DotContent: View, MenuContent: View>: View {
    /// The dot as drawn, including cursor magnification.
    let closed: CGRect
    /// The menu at full size.
    let open: CGRect
    /// 0 = dot, 1 = menu.
    let t: CGFloat
    let side: DockSide
    let accent: Accent
    let isLit: Bool
    let glowPhase: CGFloat
    @ViewBuilder let dotContent: () -> DotContent
    @ViewBuilder let menuContent: () -> MenuContent

    /// Contents are pinned to the anchored edge by *alignment*, not by computed
    /// offsets.
    ///
    /// Offsetting worked out to `rect.minX + (rect.width - contentWidth)`, which
    /// is only stationary while both terms ease on the same curve. Closing
    /// changes the morph and the magnification together, SwiftUI animates them
    /// on their own curves, the cancellation breaks, and the dot visibly flies
    /// across the menu. Letting the layout system pin the edge removes the
    /// arithmetic, and with it the failure mode.
    private var pin: Alignment { side == .left ? .topTrailing : .topLeading }

    private var rect: CGRect { MorphMetrics.rect(closed: closed, open: open, t: t) }
    private var radius: CGFloat { MorphMetrics.radius(closed: closed, current: rect, t: t) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    /// The dot's colour does not vanish when the menu opens - it spreads into
    /// the glass as a bloom anchored where the dot was, so the surface still
    /// reads as having grown out of it.
    private var bloomSide: CGFloat {
        max(closed.width, closed.height, 40) * 1.15 * (1 + 2.2 * t)
    }

    private var dotOpacity: Double { Double(max(0, 1 - t / 0.3)) }
    private var menuOpacity: Double { Double(max(0, (t - 0.45) / 0.55)) }

    var body: some View {
        ZStack(alignment: pin) {
            bloom
            menuContent()
                .frame(width: open.width, alignment: .topLeading)
                .opacity(menuOpacity)
                .allowsHitTesting(t > 0.9)
            dotContent()
                .frame(width: closed.width, height: closed.height)
                .opacity(dotOpacity)
                .allowsHitTesting(false)
        }
        .frame(width: rect.width, height: rect.height, alignment: pin)
        .liquidGlass(shape: shape, tint: accent.glow.opacity(0.20 * Double(t)), enabled: t > 0.02)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.30 + 0.10 * Double(1 - t)),
                                        .white.opacity(0.06)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.6)
        )
        .shadow(color: accent.glow.opacity(isLit ? (0.30 + 0.32 * glowPhase) * (1 - Double(t) * 0.6) : 0),
                radius: 5 + 4 * glowPhase)
        .shadow(color: .black.opacity(0.30 + 0.20 * Double(t)),
                radius: 3 + 9 * t, y: 1 + 4 * t)
        .offset(x: rect.minX, y: rect.minY)
    }

    /// Sits in a dot-sized box pinned to the same edge, with the colour
    /// overflowing symmetrically out of it - so it stays centred on where the
    /// dot is without any position arithmetic of its own.
    private var bloom: some View {
        Color.clear
            .frame(width: closed.width, height: closed.height)
            .overlay(
                AuroraFill(accent: accent, side: bloomSide)
                    .mask(MistyMask(side: bloomSide))
                    .frame(width: bloomSide, height: bloomSide)
            )
            .opacity(1 - 0.25 * Double(t))
            .allowsHitTesting(false)
    }
}

/// Fades the colour bloom out without leaving a visible rim.
///
/// A single radial gradient gives itself away twice: the last stop lands on
/// `.clear` at a fixed radius, which reads as a drawn circle, and the shape is
/// perfectly symmetrical. This uses a many-stop falloff so there is no step at
/// the edge, and overlaps several lobes drifting on the same non-repeating
/// paths as the colour underneath, so the outline is irregular and keeps
/// moving.
private struct MistyMask: View {
    let side: CGFloat

    /// Sampled cosine falloff - smooth all the way to zero, no visible rim.
    private static let stops: [Gradient.Stop] = {
        let steps = 14
        return (0...steps).map { i in
            let x = Double(i) / Double(steps)
            let a = 0.5 * (1 + cos(.pi * x))       // 1 at centre, 0 at edge
            return Gradient.Stop(color: .white.opacity(a), location: x)
        }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    RadialGradient(gradient: Gradient(stops: Self.stops),
                                   center: .center,
                                   startRadius: 0,
                                   endRadius: side * (0.30 + 0.06 * Double(i % 3)))
                        .frame(width: side, height: side)
                        .offset(AuroraFill.drift(index: i + 2,
                                                 time: t * 0.6,
                                                 amplitude: side * 0.10))
                        .blendMode(.plusLighter)
                }
            }
            .compositingGroup()
        }
    }
}

extension View {
    /// Real Liquid Glass on macOS 26, a hand-built approximation before it.
    func liquidGlass(shape: some Shape, tint: Color, enabled: Bool) -> some View {
        modifier(LiquidGlass(shape: shape, tint: tint, enabled: enabled))
    }
}

private struct LiquidGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(tint), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(shape.fill(Palette.card.opacity(0.55)))
                .background(shape.fill(tint))
        }
    }
}
