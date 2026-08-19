import AppKit
import CoreGraphics
import Foundation

/// Sizing and cursor-proximity maths for the single dot.
///
/// The Dock's magnification, reduced to the part that still applies when there
/// is only one item: it grows as the cursor approaches. The falloff is a raised
/// cosine - 1 under the cursor, 0 at the influence radius, flat at both ends -
/// so nothing visibly pops as the cursor enters or leaves the field.
enum DotGeometry {
    static func falloff(distance: CGFloat, radius: CGFloat) -> CGFloat {
        guard radius > 0 else { return 0 }
        let x = min(abs(distance) / radius, 1)
        return 0.5 * (1 + cos(.pi * x))
    }

    static func fontSize(height: CGFloat) -> CGFloat { height * 0.62 }

    /// The font the number is actually drawn in, so the capsule can be sized
    /// from the text rather than from a guess at its width.
    ///
    /// Monospaced digits are part of the identity here, not a detail: the
    /// capsule is sized from this and the glyphs have to keep to it, or a count
    /// ticking from 11 to 18 would breathe the whole dot in and out.
    static func countFont(height: CGFloat) -> NSFont {
        let size = fontSize(height: height)
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        let rounded = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        let tabular = rounded.addingAttributes([
            .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]
        ])
        return NSFont(descriptor: tabular, size: size) ?? base
    }

    /// What the number measures on screen.
    ///
    /// This used to be `digits * fontSize * 0.64`, described as erring high. It
    /// erred low - SF Rounded Bold advances 0.71em - so every extra digit ate
    /// into the padding instead of widening the pill, and a three-character
    /// count sat in a capsule cut for two.
    static func textWidth(_ text: String, height: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: countFont(height: height)]).width
    }

    /// How far the number has to rise to sit in the middle of the dot.
    ///
    /// Text is centred on its line box, and a line box reserves room for
    /// descenders that "42" has no use for, so centring the box leaves the
    /// digits sitting low. Centring their cap-height box instead is what the
    /// eye is actually asking for.
    static func countLift(height: CGFloat) -> CGFloat {
        let font = countFont(height: height)
        return (font.ascender + font.descender - font.capHeight) / 2
    }

    /// Width of a capsule holding `text`, padded so the digits never crowd the
    /// ends. Below two characters the padding alone already makes a pill.
    static func capsuleWidth(text: String, height: CGFloat) -> CGFloat {
        max(height, textWidth(text, height: height) + height * 0.70)
    }

    /// The widest the dot can get, for the hit region. Nines because they are
    /// no narrower than any other digit and the font is tabular anyway.
    static func capsuleWidth(digits: Int, height: CGFloat) -> CGFloat {
        capsuleWidth(text: String(repeating: "9", count: max(digits, 0)), height: height)
    }

    /// Height with the cursor far away: a quiet dot is a small circle, one with
    /// something waiting is a full-height capsule carrying the number.
    static func restHeight(count: Int, height: CGFloat, showCount: Bool) -> CGFloat {
        (showCount && count > 0) ? height : height * 0.60
    }

    static func restWidth(countText: String, count: Int, height: CGFloat, showCount: Bool) -> CGFloat {
        guard showCount, count > 0 else { return height * 0.60 }
        return capsuleWidth(text: countText, height: height)
    }

    /// Unscaled width under the cursor. With no mark to make room for, a lit
    /// dot is simply its capsule and a quiet one stays a dot - so hovering
    /// magnifies without also reflowing the shape.
    static func activeWidth(countText: String, count: Int, height: CGFloat) -> CGFloat {
        guard count > 0 else { return height * 0.60 }
        return capsuleWidth(text: countText, height: height)
    }

    /// How much of the number is on screen, 0 to 1.
    ///
    /// A ramp rather than a threshold, because the capsule is sized from it as
    /// well as the digits. The number used to blink on at a fixed point in the
    /// approach, which left the capsule a choice between staying circle-sized -
    /// and cutting the digits off against its own edge - or jumping to full
    /// width in a single frame. Fading it in across a stretch lets the shape
    /// grow with it, and both read the answer from here so they cannot
    /// disagree about whether there is room.
    static func countReveal(count: Int, showCount: Bool, progress: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        guard !showCount else { return 1 }
        return min(max((progress - 0.05) / 0.35, 0), 1)
    }

    /// The dot's height part-way through the approach, before magnification.
    static func liveHeight(rest: CGFloat, full: CGFloat, progress: CGFloat) -> CGFloat {
        rest + (full - rest) * progress
    }

    static func renderHeight(rest: CGFloat, full: CGFloat, progress: CGFloat, scale: CGFloat) -> CGFloat {
        liveHeight(rest: rest, full: full, progress: progress) * scale
    }

    /// Width across the approach, never narrower than the number inside it.
    ///
    /// The capsule used to interpolate straight from the resting circle to the
    /// full capsule while the digits were drawn at the size they end at. One
    /// digit fits a half-grown capsule by luck. "42" spent the first third of
    /// the approach wider than the shape holding it and "99+" the first half,
    /// and the surface's own clip cut them off square - the edge of the menu
    /// showing through the middle of the dot.
    ///
    /// The floor is measured at the height the dot has *now*, so the padding
    /// the resting dot has is the padding it keeps the whole way, and it is
    /// mixed in on `reveal` so the width never steps.
    static func renderWidth(rest: CGFloat, active: CGFloat, text: String,
                            height: CGFloat, reveal: CGFloat,
                            progress: CGFloat, scale: CGFloat) -> CGFloat {
        let base = rest + (active - rest) * progress
        let needed = capsuleWidth(text: text, height: height)
        return (base + max(0, needed - base) * reveal) * scale
    }

    /// Distance from the top of the screen to the top of a resting dot. Fixed,
    /// so magnification grows downwards out of the notch and never clips
    /// against the top edge of the display.
    static func topY(menuBarHeight: CGFloat, restHeight: CGFloat) -> CGFloat {
        max(1, menuBarHeight / 2 - restHeight / 2)
    }

    /// "3", "42", "99+" - capped so the capsule never has to grow unbounded.
    static func countText(_ count: Int) -> String {
        count > 99 ? "99+" : String(count)
    }
}

/// The dot and the menu are not two views - they are one surface at two points
/// along a morph. These are the endpoints, so the view that draws it and the
/// controller that hit-tests it derive the same rectangle from the same numbers.
enum MorphMetrics {
    /// Corner radius the surface settles at when fully open.
    static let openRadius: CGFloat = 22

    /// The dot as drawn, including any cursor magnification.
    ///
    /// Magnification is pinned on the *far* edge - the outer end of the resting
    /// dot - so growing towards the cursor carries the dot towards the notch and
    /// under the housing. Pinning the notch-side edge instead is the obvious
    /// reading of "the anchor never moves" and looks wrong: every point of
    /// magnification shoves the dot out along the menu bar, so approaching it
    /// makes it lunge away from the notch before the menu has even opened.
    ///
    /// This does not resurrect the bug that anchoring cost us before. That was
    /// *centring*, which put the pinned edge halfway into the magnification and
    /// left the morph and the magnify spring fighting over it mid-flight. Both
    /// edges here are still fixed points: the far one during magnification, the
    /// notch-side one across the morph - which is safe because the view holds
    /// this rect at rest size for as long as the menu is open, so magnification
    /// is never in flight at the same time as the morph.
    static func closedRect(anchorX: CGFloat,
                           side: DockSide,
                           menuBarHeight: CGFloat,
                           dotSize: CGFloat,
                           count: Int,
                           showCount: Bool,
                           progress: CGFloat,
                           scale: CGFloat) -> CGRect {
        let text = DotGeometry.countText(count)
        let restH = DotGeometry.restHeight(count: count, height: dotSize, showCount: showCount)
        let restW = DotGeometry.restWidth(countText: text, count: count,
                                          height: dotSize, showCount: showCount)
        let activeW = DotGeometry.activeWidth(countText: text, count: count, height: dotSize)
        let reveal = DotGeometry.countReveal(count: count, showCount: showCount, progress: progress)
        // Unmagnified height first: the capsule's floor is measured against the
        // height the dot has at this point in the approach, not the one it ends
        // at, or a half-grown capsule would be padded for a full-grown number.
        let liveH = DotGeometry.liveHeight(rest: restH, full: dotSize, progress: progress)
        let h = liveH * scale
        let w = DotGeometry.renderWidth(rest: restW, active: activeW, text: text,
                                        height: liveH, reveal: reveal,
                                        progress: progress, scale: scale)
        let top = DotGeometry.topY(menuBarHeight: menuBarHeight, restHeight: restH)
        // Where the resting dot ends, away from the notch. Fixed, whatever the
        // magnification does.
        let far = side == .left ? anchorX - restW : anchorX + restW
        return CGRect(x: side == .left ? far : far - w, y: top, width: w, height: h)
    }

    /// The menu, sharing the dot's anchor and top edge, so the only quantities
    /// that change across the morph are width, height and corner radius. With
    /// nothing travelling horizontally there is no way for the surface to
    /// appear to fly in from the far corner.
    static func openRect(anchorX: CGFloat,
                         side: DockSide,
                         closed: CGRect,
                         cardWidth: CGFloat,
                         cardHeight: CGFloat) -> CGRect {
        CGRect(x: side == .left ? anchorX - cardWidth : anchorX,
               y: closed.minY,
               width: cardWidth,
               height: max(cardHeight, closed.height))
    }

    static func rect(closed: CGRect, open: CGRect, t: CGFloat) -> CGRect {
        let e = min(max(t, 0), 1)
        return CGRect(x: closed.minX + (open.minX - closed.minX) * e,
                      y: closed.minY + (open.minY - closed.minY) * e,
                      width: closed.width + (open.width - closed.width) * e,
                      height: closed.height + (open.height - closed.height) * e)
    }

    /// Starts as a true capsule and relaxes into the menu's corner radius,
    /// never exceeding what the current rectangle can actually round.
    static func radius(closed: CGRect, current: CGRect, t: CGFloat) -> CGFloat {
        let e = min(max(t, 0), 1)
        let start = closed.height / 2
        return min(start + (openRadius - start) * e, min(current.width, current.height) / 2)
    }
}
