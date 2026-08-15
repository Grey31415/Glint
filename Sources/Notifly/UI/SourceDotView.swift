import SwiftUI

/// One source, rendered as a dot that grows into a capsule.
///
/// Resting shape depends on the state: nothing waiting is a small muted circle,
/// unread messages make it a colour-cycling capsule carrying the number. Under
/// the cursor it magnifies and opens up to show the service mark as well.
struct SourceDotView: View {
    let snapshot: SourceSnapshot
    let placement: MagnifiedPlacement
    let layout: OverlayLayout
    let showCountAtRest: Bool
    let ambientBreathing: Bool
    let onTap: () -> Void

    @State private var rippleTick = 0

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

    private var showsCount: Bool {
        snapshot.displayCount > 0 && (showCountAtRest || progress > 0.05)
    }

    var body: some View {
        ZStack {
            fill
            ArrivalRipple(tick: rippleTick, color: accent.glow)
            statusRing
            content
        }
        .frame(width: width, height: height)
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(isAttention ? 0.22 : 0.10),
                              lineWidth: max(0.5, 0.5 * scale))
        )
        .shadow(color: accent.glow.opacity(isAttention ? 0.55 : 0),
                radius: 6 * scale, x: 0, y: 0)
        .shadow(color: .black.opacity(0.45), radius: 3 * scale, x: 0, y: 1 * scale)
        .contentShape(Capsule(style: .continuous))
        .onTapGesture(perform: onTap)
        .onChange(of: snapshot.displayCount) { old, new in
            if new > old { rippleTick &+= 1 }
        }
        .help("\(snapshot.descriptor.name) — \(snapshot.state.summary)")
    }

    // MARK: - Layers

    @ViewBuilder
    private var fill: some View {
        if isAttention {
            // The signature move: a conic gradient turning slowly inside the dot.
            AngularGradient(colors: accent.stops, center: .center)
                .spin(active: true, period: 7)
                .overlay(
                    // Soft highlight so it reads as a lit object, not a flat swatch.
                    RadialGradient(colors: [.white.opacity(0.35), .clear],
                                   center: .init(x: 0.32, y: 0.22),
                                   startRadius: 0,
                                   endRadius: max(width, height) * 0.7)
                )
                .breathe(active: true, from: 1.0, to: 1.05, period: 1.9)
        } else if snapshot.state.isBlocked {
            Palette.surface
        } else {
            Palette.idle
                .opacity(0.55 + 0.30 * progress)
                .breathe(active: ambientBreathing, from: 0.92, to: 1.06, period: 4.2)
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
                    .shadow(color: .black.opacity(0.3), radius: 0.5 * scale, y: 0.5)
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
