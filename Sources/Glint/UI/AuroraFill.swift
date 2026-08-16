import SwiftUI

/// The lit interior of a dot: soft colour blobs wandering behind the mask.
///
/// Two things matter here. First, the canvas is a **square**, sized by the
/// caller to cover the widest capsule the dot could ever become - a fill that
/// merely matches the current shape runs out from under the tile the moment a
/// number gets longer or the blobs drift.
///
/// Second, the blobs translate rather than rotate. Each follows its own pair of
/// summed sines whose frequency ratios are irrational, so no blob repeats its
/// own path and no two ever fall back into step with each other. The result
/// keeps rearranging itself instead of cycling.
struct AuroraFill: View {
    let accent: Accent
    let side: CGFloat
    var paused: Bool = false

    /// 30fps is plenty for something this slow, and halves the cost of keeping
    /// several lit dots alive at once.
    private static let frameInterval = 1.0 / 30.0

    /// Blob radius and drift, as fractions of `side`. Tuned together: blobs
    /// small enough - and roaming far enough - that the ones painted first are
    /// not permanently buried by the ones painted last. Widen the radius and
    /// the last two colours simply win forever.
    private static let blobRadius: CGFloat = 0.30
    private static let driftAmplitude: CGFloat = 0.34
    /// Slightly translucent so lower layers tint through rather than being
    /// occluded outright. Additive blending was the obvious alternative and is
    /// wrong here: overlaps blow out to white and every brand ends up pink.
    private static let blobOpacity: Double = 0.90

    /// Paused drops the `TimelineView` rather than asking it to hold still. Its
    /// schedule is captured when the view is created, so flipping `paused` on a
    /// live one is not reliable. Swapping the branch changes the view's
    /// identity and takes the clock with it.
    var body: some View {
        Group {
            if paused {
                blobs(at: 0)
            } else {
                TimelineView(.animation(minimumInterval: Self.frameInterval)) { timeline in
                    blobs(at: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func blobs(at t: TimeInterval) -> some View {
        ZStack {
            accent.base
            ForEach(Array(accent.colors.enumerated()), id: \.offset) { index, color in
                RadialGradient(colors: [color, color.opacity(0.55), color.opacity(0)],
                               center: .center,
                               startRadius: 0,
                               endRadius: side * Self.blobRadius)
                    .frame(width: side, height: side)
                    .offset(Self.drift(index: index,
                                       time: t,
                                       amplitude: side * Self.driftAmplitude))
                    .opacity(Self.blobOpacity)
            }
        }
        .frame(width: side, height: side)
    }

    /// Bounded, smooth, and non-repeating: a slow carrier plus a faster harmonic
    /// at φ (and its reciprocal) so the two never share a common period.
    static func drift(index: Int, time: Double, amplitude: CGFloat) -> CGSize {
        let seed = Double(index) + 1
        let fx = 0.16 + 0.037 * seed
        let fy = 0.13 + 0.043 * seed
        let phaseX = seed * 1.7
        let phaseY = seed * 2.3
        let x = 0.68 * sin(time * fx + phaseX) + 0.32 * sin(time * fx * 1.618 + phaseX * 2)
        let y = 0.68 * cos(time * fy + phaseY) + 0.32 * cos(time * fy * 1.382 + phaseY * 2)
        return CGSize(width: amplitude * x, height: amplitude * y)
    }
}
