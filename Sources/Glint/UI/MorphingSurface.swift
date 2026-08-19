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
    let animated: Bool
    /// Whether the dot's colour spreads into the menu. Off keeps it dot-sized
    /// and lets it leave with the dot.
    var blooms: Bool = true
    /// How much of the *resting* dot is glass rather than paint, 0...1. The menu
    /// is glass either way, so this fades out with the morph.
    var glassiness: CGFloat = 0
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
    ///
    /// The margin over the surface's own longest side was 1.15 and had to be a
    /// great deal wider. `MistyMask` fades the colour to nothing at about 0.42
    /// of this, so the paint reaches far less far than the number suggests: a
    /// magnified double-digit capsule is half as wide again as a single-digit
    /// one, its ends came out past where the colour had already faded, and the
    /// tips of a lit pill were plain glass.
    ///
    /// 2.80 rather than the 1.56 that first covers the tip, because the mask's
    /// lobes drift by a further 0.10 of this same number - enlarging the bloom
    /// enlarges the wander with it, so the margin buys less than it looks like
    /// it should. Measured against the drift over an hour of phases, the tip's
    /// worst moment goes from bare glass to 42% and its mean to 99%. It is not
    /// solid even here: only a mask with a flat core, or one applied to the
    /// menu rather than to the dot, closes the last of it, and both change how
    /// the colour field looks.
    ///
    /// The open menu's bloom is carried along by the same figure, which is the
    /// price of keeping the dot's colour and the menu's the same colour.
    private var bloomSide: CGFloat {
        max(closed.width, closed.height, 40) * 2.80 * (1 + (blooms ? 2.2 : 0) * t)
    }

    /// With the spread switched off the colour is the dot's alone, so it fades
    /// on the dot's curve and travels with it. Leaving it lit and stationary
    /// would put exactly the corner glow being switched off back on the glass.
    private var bloomOpacity: Double {
        (blooms ? 1 - 0.25 * Double(t) : dotOpacity) * paintShare
    }

    /// What the glassiness slider leaves of the dot's paint at rest.
    private var restPaint: Double {
        1 - Double(min(max(glassiness, 0), 1)) * Self.glassyPaint
    }

    /// How much paint a fully glassy dot gives up. The same figure ends the
    /// morph whatever the slider says, so the opening is always a glass
    /// expansion. A computed property because `MorphingSurface` is generic, and
    /// generic types cannot hold stored statics.
    private static var glassyPaint: Double { 0.88 }

    /// The paint across the morph: whatever the dot is made of at rest, thinning
    /// to glass as it opens.
    ///
    /// The expansion is the same animation for everyone. Glassiness describes
    /// the dot sitting there, not the act of becoming a menu - a menu carrying a
    /// dot's worth of opaque colour across it reads as a coloured panel rather
    /// than as glass with a bloom in the corner.
    ///
    /// It thins on `dotRetreat`'s curve, so the colour leaves with the dot it
    /// belongs to and is gone while the surface is still nearly dot-sized. That
    /// timing is the whole trick, and the reason two earlier versions of this
    /// looked wrong: the same change spread across the full morph lands when the
    /// surface is already wide, and a large area shifting tone after the shape
    /// has settled reads as the menu restyling itself.
    private var paintShare: Double {
        let opened = 1 - Self.glassyPaint
        let progress = Double(min(max(t, 0) / 0.4, 1))
        return restPaint + (opened - restPaint) * progress
    }

    private var dotOpacity: Double { Double(max(0, 1 - t / 0.45)) }
    private var menuOpacity: Double { Double(max(0, (t - 0.45) / 0.55)) }

    /// The dot's exit: it travels *towards* the notch as the menu takes over,
    /// and the surface's own clip - which sits on the notch-side edge - eats it.
    /// So it reads as ducking behind the camera housing rather than being
    /// dissolved on the spot while the surface sweeps out the other way.
    ///
    /// Safe despite the rule about horizontal travel, because this is one value
    /// interpolated by `t` alone. What broke before was arithmetic *across* two
    /// quantities on different springs, not motion as such.
    private var dotRetreat: CGFloat {
        let reach = closed.width * 0.9 + 4
        return (side == .left ? 1 : -1) * reach * min(max(t, 0) / 0.4, 1)
    }

    var body: some View {
        ZStack(alignment: pin) {
            scrim
            bloom
            menuContent()
                .frame(width: open.width, alignment: .topLeading)
                .opacity(menuOpacity)
                .allowsHitTesting(t > 0.9)
            dotContent()
                .frame(width: closed.width, height: closed.height)
                .offset(x: dotRetreat)
                .opacity(dotOpacity)
                .allowsHitTesting(false)
        }
        .frame(width: rect.width, height: rect.height, alignment: pin)
        // The glass carries a wash of the accent too. It goes with the bloom, or
        // "plain glass" would still be tinted and the switch would look
        // half-applied.
        //
        // One opacity for the whole morph, for the third time in this file. It
        // used to ramp with `t`, which meant the glass spent the entire opening
        // animation paler than the menu it was becoming and only arrived at its
        // colour once the shape stopped moving - the surface looked like it
        // stained itself at the end. The tint is invisible at rest anyway,
        // because a dot that is not glassy is covered by its own paint.
        // Always on. It used to switch in at `t > 0.02 || glassiness > 0.01`,
        // which meant that with the slider at 0 or 1 the surface began the morph
        // as plain paint and grew its glass a frame or two later - the opening
        // visibly changed material on the way out. At rest this costs nothing to
        // look at, because a dot that is not glassy is covered by its own paint.
        .liquidGlass(shape: shape,
                     tint: accent.glow.opacity(blooms ? 0.20 : 0),
                     enabled: true)
        .clipShape(shape)
        .overlay(
            // Light mode inverts this: a white rim on light glass is no rim at
            // all, so `Palette.rim` supplies black there and these opacities
            // multiply down into a hairline rather than a highlight.
            shape.strokeBorder(
                LinearGradient(colors: [Palette.rim.opacity(0.30 + 0.10 * Double(1 - t)),
                                        Palette.rim.opacity(0.06)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.6)
        )
        .shadow(color: accent.glow.opacity(isLit ? (0.30 + 0.32 * glowPhase) * (1 - Double(t) * 0.6) : 0),
                radius: 5 + 4 * glowPhase)
        .shadow(color: .black.opacity(0.30 + 0.20 * Double(t)),
                radius: 3 + 9 * t, y: 1 + 4 * t)
        .offset(x: rect.minX, y: rect.minY)
    }

    /// The dark-mode weight behind the glass, for the whole morph.
    ///
    /// Glass takes its tone from whatever is behind it, and what is behind this
    /// surface changes as it grows: the notch is black, the menu bar is not, and
    /// the desktop under an open menu is anything at all. In dark mode that made
    /// one surface look pale while it expanded and heavy once it settled, which
    /// is what "the animation is lighter than the popup" was describing.
    ///
    /// So it is constant, and not tied to the glassiness slider. Glassiness says
    /// how much paint the dot keeps; this says what colour glass is in the dark.
    /// In light mode it is nothing at all - `Palette.glassScrim` is clear there,
    /// because glass over a black notch already reads as an object.
    ///
    /// Bottom of the stack, so it darkens the glass and never the number or the
    /// menu text drawn above it.
    private var scrim: some View {
        Rectangle()
            .fill(Palette.glassScrim)
            .frame(width: rect.width, height: rect.height)
            .allowsHitTesting(false)
    }

    /// Sits in a dot-sized box pinned to the same edge, with the colour
    /// overflowing symmetrically out of it - so it stays centred on where the
    /// dot is without any position arithmetic of its own.
    private var bloom: some View {
        Color.clear
            .frame(width: closed.width, height: closed.height)
            .overlay(
                AuroraFill(accent: accent, side: bloomSide, paused: !animated)
                    .mask(MistyMask(side: bloomSide, paused: !animated))
                    .frame(width: bloomSide, height: bloomSide)
            )
            .offset(x: blooms ? 0 : dotRetreat)
            .opacity(bloomOpacity)
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
    var paused: Bool = false

    /// Sampled cosine falloff - smooth all the way to zero, no visible rim.
    private static let stops: [Gradient.Stop] = {
        let steps = 14
        return (0...steps).map { i in
            let x = Double(i) / Double(steps)
            let a = 0.5 * (1 + cos(.pi * x))       // 1 at centre, 0 at edge
            return Gradient.Stop(color: .white.opacity(a), location: x)
        }
    }()

    @ViewBuilder
    var body: some View {
        if paused {
            lobes(at: 0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                lobes(at: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func lobes(at t: TimeInterval) -> some View {
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
