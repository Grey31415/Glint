import CoreGraphics
import Foundation

/// Sizing and cursor-proximity maths for the single dot.
///
/// The Dock's magnification, reduced to the part that still applies when there
/// is only one item: it grows as the cursor approaches. The falloff is a raised
/// cosine — 1 under the cursor, 0 at the influence radius, flat at both ends —
/// so nothing visibly pops as the cursor enters or leaves the field.
enum DotGeometry {
    static func falloff(distance: CGFloat, radius: CGFloat) -> CGFloat {
        guard radius > 0 else { return 0 }
        let x = min(abs(distance) / radius, 1)
        return 0.5 * (1 + cos(.pi * x))
    }

    static func fontSize(height: CGFloat) -> CGFloat { height * 0.62 }
    /// SF Rounded Bold advances a touch under 0.62em; erring high keeps text
    /// from ever overflowing the capsule.
    static func digitWidth(height: CGFloat) -> CGFloat { fontSize(height: height) * 0.64 }
    static func glyphSize(height: CGFloat) -> CGFloat { height * 0.70 }

    /// Width of a capsule holding `digits` characters. Also used to size the
    /// colour field, which is why it takes a count rather than a string.
    static func capsuleWidth(digits: Int, height: CGFloat) -> CGFloat {
        max(height, CGFloat(digits) * digitWidth(height: height) + height * 0.70)
    }

    /// Height with the cursor far away: a quiet dot is a small circle, one with
    /// something waiting is a full-height capsule carrying the number.
    static func restHeight(count: Int, height: CGFloat, showCount: Bool) -> CGFloat {
        (showCount && count > 0) ? height : height * 0.60
    }

    static func restWidth(countText: String, count: Int, height: CGFloat, showCount: Bool) -> CGFloat {
        guard showCount, count > 0 else { return height * 0.60 }
        return capsuleWidth(digits: countText.count, height: height)
    }

    /// Unscaled width once the capsule has fully opened to show the mark too.
    static func activeWidth(countText: String, count: Int, height: CGFloat) -> CGFloat {
        let pad = height * 0.34
        let glyph = glyphSize(height: height)
        guard count > 0 else { return pad * 2 + glyph }
        return pad * 2 + glyph + height * 0.22 + CGFloat(countText.count) * digitWidth(height: height)
    }

    static func renderHeight(rest: CGFloat, full: CGFloat, progress: CGFloat, scale: CGFloat) -> CGFloat {
        (rest + (full - rest) * progress) * scale
    }

    /// Distance from the top of the screen to the top of a resting dot. Fixed,
    /// so magnification grows downwards out of the notch and never clips
    /// against the top edge of the display.
    static func topY(menuBarHeight: CGFloat, restHeight: CGFloat) -> CGFloat {
        max(1, menuBarHeight / 2 - restHeight / 2)
    }

    /// "3", "42", "99+" — capped so the capsule never has to grow unbounded.
    static func countText(_ count: Int) -> String {
        count > 99 ? "99+" : String(count)
    }
}
