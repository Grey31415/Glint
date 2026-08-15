import CoreGraphics
import Foundation

/// One element to lay out. `restWidth` is the unscaled width with the cursor far
/// away; `activeWidth` is the unscaled width once the capsule has opened up.
struct MagnifiedItem: Equatable {
    let id: String
    let restWidth: CGFloat
    let activeWidth: CGFloat
}

struct MagnifiedPlacement: Equatable, Identifiable {
    let id: String
    /// 0 = untouched, 1 = directly under the cursor.
    let progress: CGFloat
    let scale: CGFloat
    /// Unscaled content width at the current progress.
    let contentWidth: CGFloat
    /// On-screen width, i.e. `contentWidth * scale`.
    let width: CGFloat
    let centerX: CGFloat

    var minX: CGFloat { centerX - width / 2 }
    var maxX: CGFloat { centerX + width / 2 }
}

/// The Dock's magnification, reduced to its two essential behaviours: items
/// under the cursor grow, and their neighbours are displaced to make room.
///
/// Everything here is pure so the window controller can run the exact same
/// layout as the view to decide where clicks should be accepted.
struct DockMagnifier {
    var maxScale: CGFloat = 2.1
    var influence: CGFloat = 84
    var spacing: CGFloat = 8

    enum Anchor {
        /// Items grow leftwards from a fixed right edge (used left of the notch).
        case trailing(CGFloat)
        /// Items grow rightwards from a fixed left edge (used right of the notch).
        case leading(CGFloat)
    }

    /// Raised cosine: 1 directly under the cursor, 0 at the influence radius,
    /// with zero slope at both ends so there is no visible seam when a dot
    /// enters or leaves the field.
    static func falloff(distance: CGFloat, radius: CGFloat) -> CGFloat {
        guard radius > 0 else { return 0 }
        let x = min(abs(distance) / radius, 1)
        return 0.5 * (1 + cos(.pi * x))
    }

    /// - Parameters:
    ///   - mouseX: cursor position in the same coordinate space as `anchor`,
    ///     or nil when the cursor is out of range.
    ///   - hoverAmount: 0…1 master fade, so the cluster eases in and out of
    ///     magnification instead of snapping when the cursor arrives.
    func layout(_ items: [MagnifiedItem],
                anchor: Anchor,
                mouseX: CGFloat?,
                hoverAmount: CGFloat) -> [MagnifiedPlacement] {
        guard !items.isEmpty else { return [] }

        // Pass 1 — where everything sits with the cursor far away. Distances are
        // measured against these rest positions, which keeps the layout stable
        // instead of chasing its own displacement.
        var restCenters = [CGFloat](repeating: 0, count: items.count)
        switch anchor {
        case .trailing(let edge):
            var cursor = edge
            for i in items.indices.reversed() {
                restCenters[i] = cursor - items[i].restWidth / 2
                cursor -= items[i].restWidth + spacing
            }
        case .leading(let edge):
            var cursor = edge
            for i in items.indices {
                restCenters[i] = cursor + items[i].restWidth / 2
                cursor += items[i].restWidth + spacing
            }
        }

        // Pass 2 — how magnified each item wants to be.
        let clampedHover = min(max(hoverAmount, 0), 1)
        var progress = [CGFloat](repeating: 0, count: items.count)
        if let mouseX {
            for i in items.indices {
                progress[i] = Self.falloff(distance: mouseX - restCenters[i],
                                           radius: influence) * clampedHover
            }
        }

        // Pass 3 — lay out again with the magnified sizes, pushing neighbours
        // outward from the anchored edge.
        var placements = [MagnifiedPlacement?](repeating: nil, count: items.count)
        func place(_ i: Int, cursor: inout CGFloat, growingLeft: Bool) {
            let p = progress[i]
            let scale = 1 + (maxScale - 1) * p
            let content = items[i].restWidth + (items[i].activeWidth - items[i].restWidth) * p
            let width = content * scale
            let centerX = growingLeft ? cursor - width / 2 : cursor + width / 2
            placements[i] = MagnifiedPlacement(id: items[i].id,
                                               progress: p,
                                               scale: scale,
                                               contentWidth: content,
                                               width: width,
                                               centerX: centerX)
            cursor += growingLeft ? -(width + spacing) : (width + spacing)
        }

        switch anchor {
        case .trailing(let edge):
            var cursor = edge
            for i in items.indices.reversed() { place(i, cursor: &cursor, growingLeft: true) }
        case .leading(let edge):
            var cursor = edge
            for i in items.indices { place(i, cursor: &cursor, growingLeft: false) }
        }

        return placements.compactMap { $0 }
    }
}

extension Array where Element == MagnifiedPlacement {
    /// Horizontal extent of the laid-out cluster, or nil when empty.
    var horizontalBounds: ClosedRange<CGFloat>? {
        guard let lo = map(\.minX).min(), let hi = map(\.maxX).max(), lo <= hi else { return nil }
        return lo...hi
    }
}

/// Turns a source snapshot into the widths the magnifier needs. Uses a
/// monospaced-digit font so these estimates match what actually renders.
enum DotMetrics {
    static func fontSize(height: CGFloat) -> CGFloat { height * 0.62 }
    /// SF Rounded Bold advances a touch under 0.62em; erring high keeps text
    /// from ever overflowing the capsule the magnifier sized for it.
    static func digitWidth(height: CGFloat) -> CGFloat { fontSize(height: height) * 0.64 }
    static func glyphSize(height: CGFloat) -> CGFloat { height * 0.70 }

    /// Height of the dot with the cursor far away. A source with nothing to say
    /// stays a small circle; one with unread messages is a full-height capsule.
    static func restHeight(for snapshot: SourceSnapshot, height: CGFloat, showCount: Bool) -> CGFloat {
        (showCount && snapshot.displayCount > 0) ? height : height * 0.60
    }

    static func renderHeight(rest: CGFloat, full: CGFloat, progress: CGFloat, scale: CGFloat) -> CGFloat {
        (rest + (full - rest) * progress) * scale
    }

    /// Distance from the top of the screen to the top of a resting dot. Fixed,
    /// so magnification grows downwards out of the notch and never clips against
    /// the top edge of the display.
    static func topY(menuBarHeight: CGFloat, restHeight: CGFloat) -> CGFloat {
        max(1, menuBarHeight / 2 - restHeight / 2)
    }

    static func textWidth(_ text: String, height: CGFloat) -> CGFloat {
        CGFloat(text.count) * digitWidth(height: height)
    }

    /// Width of a capsule holding `digits` characters. Also used to size the
    /// colour field, which is why it takes a count rather than a string.
    static func capsuleWidth(digits: Int, height: CGFloat) -> CGFloat {
        max(height, CGFloat(digits) * digitWidth(height: height) + height * 0.70)
    }

    static func restWidth(for snapshot: SourceSnapshot, height: CGFloat, showCount: Bool) -> CGFloat {
        let bare = height * 0.60   // the quiet dot
        guard showCount, snapshot.displayCount > 0 else { return bare }
        return capsuleWidth(digits: snapshot.countText.count, height: height)
    }

    static func activeWidth(for snapshot: SourceSnapshot, height: CGFloat) -> CGFloat {
        let pad = height * 0.34
        let glyph = glyphSize(height: height)
        guard snapshot.displayCount > 0 else { return pad * 2 + glyph }
        return pad * 2 + glyph + height * 0.22 + textWidth(snapshot.countText, height: height)
    }

    static func item(for snapshot: SourceSnapshot, height: CGFloat, showCount: Bool) -> MagnifiedItem {
        MagnifiedItem(id: snapshot.id,
                      restWidth: restWidth(for: snapshot, height: height, showCount: showCount),
                      activeWidth: activeWidth(for: snapshot, height: height))
    }
}
