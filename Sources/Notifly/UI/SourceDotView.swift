import SwiftUI

/// One source, rendered as a dot that grows into a capsule.
///
/// Resting shape depends on the state: nothing waiting is a small muted circle,
/// unread messages make it a capsule carrying the number over a drifting colour
/// field. Under the cursor it magnifies and opens up to show the service mark.
struct SourceDotView: View {
    let snapshot: SourceSnapshot
    let placement: MagnifiedPlacement
    let layout: OverlayLayout
    let showCountAtRest: Bool
    let ambientBreathing: Bool
    let onTap: () -> Void

    @State private var rippleTick = 0
    @State private var glowPhase: CGFloat = 0

    private var accent: Accent { snapshot.descriptor.accent }
    private var isAttention: Bool { snapshot.state.isAttention }
    private var progress: CGFloat { placement.progress }
    private var scale: CGFloat { placement.scale }

    private var restHeight: CGFloat {
        DotMetrics.restHeight(for: snapshot, height: layout.dotSize, showCount: showCountAtRest)
    }

    /// Height on screen. The rest height is preserved at progress 0 so a quiet
    /// dot really is a small circle rather than a squashed pill.
    private var height: CGFloat {
        (restHeight + (layout.dotSize - restHeight) * progress) * scale
    }

    private var width: CGFloat { placement.width }

    /// Reference size every internal metric is derived from, so text and glyph
    /// grow exactly in step with the capsule instead of being scaled bitmaps.
    private var metric: CGFloat { layout.dotSize * scale }

    /// Side of the square the colour field is painted on. Sized for a
    /// four-digit capsule — comfortably wider than anything that can actually
    /// be displayed — so the fill never runs out from under the tile.
    private var fieldSide: CGFloat {
        max(width, height, DotMetrics.capsuleWidth(digits: 4, height: metric)) * 1.15
    }

    private var showsCount: Bool {
        snapshot.displayCount > 0 && (showCountAtRest || progress > 0.05)
    }

    var body: some View {
        ZStack {
            ArrivalRipple(tick: rippleTick, color: accent.glow)
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
                .strokeBorder(isAttention ? Color.white.opacity(0.22) : Palette.hairline,
                              lineWidth: max(0.5, 0.5 * scale))
        )
        .shadow(color: accent.glow.opacity(isAttention ? 0.30 + 0.32 * glowPhase : 0),
                radius: (5 + 4 * glowPhase) * scale)
        .shadow(color: .black.opacity(0.45), radius: 3 * scale, x: 0, y: 1 * scale)
        .contentShape(Capsule(style: .continuous))
        .onTapGesture(perform: onTap)
        .onChange(of: snapshot.displayCount) { old, new in
            if new > old { rippleTick &+= 1 }
        }
        .onChange(of: isAttention, initial: true) { _, lit in
            if lit {
                withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) {
                    glowPhase = 1
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) { glowPhase = 0 }
            }
        }
        .help("\(snapshot.descriptor.name) — \(snapshot.state.summary)")
    }

    // MARK: - Layers

    @ViewBuilder
    private var fillLayer: some View {
        if isAttention {
            AuroraFill(accent: accent, side: fieldSide)
        } else if snapshot.state.isBlocked {
            Palette.surface
        } else {
            Palette.idle
                .opacity(0.55 + 0.30 * progress)
                .breathe(active: ambientBreathing, from: 0.92, to: 1.06, period: 4.2)
        }
    }

    /// Sized to the capsule rather than to the colour field, so the sheen stays
    /// pinned to the tile's own top-left as it grows.
    @ViewBuilder
    private var specularHighlight: some View {
        if isAttention {
            RadialGradient(colors: [.white.opacity(0.30), .clear],
                           center: .init(x: 0.30, y: 0.18),
                           startRadius: 0,
                           endRadius: max(width, height) * 0.75)
                .allowsHitTesting(false)
        }
    }

    /// Rotating arc for the two states that are neither quiet nor lit: still
    /// connecting, or blocked on a permission the user has to grant.
    @ViewBuilder
    private var statusRing: some View {
        switch snapshot.state {
        case .loading:
            arc(color: Palette.textLo.opacity(0.8), period: 1.1)
        case .needsAuth, .needsPermission:
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
        HStack(spacing: layout.dotSize * 0.22 * scale * progress) {
            if progress > 0.01 {
                GlyphView(glyph: snapshot.descriptor.glyph,
                          size: DotMetrics.glyphSize(height: metric) * progress,
                          color: .white.opacity(isAttention ? 0.98 : 0.85))
                    .opacity(Double(min(1, progress * 1.6)))
            }
            if showsCount {
                Text(snapshot.countText)
                    .font(.system(size: DotMetrics.fontSize(height: metric),
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

/// Expanding ring fired when a source's count goes up.
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
