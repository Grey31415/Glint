import AppKit

/// Everything Glint needs to know about where the notch is on a given screen.
///
/// On notched Macs `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` describe the
/// usable menu bar strips on either side of the camera housing, so the gap
/// between them *is* the notch. On every other display we fabricate a notch of
/// the same proportions in the middle of the menu bar, which keeps the app
/// looking deliberate on an external monitor instead of broken.
struct NotchGeometry {
    let screen: NSScreen
    /// Height of the menu bar strip, in points.
    let menuBarHeight: CGFloat
    /// The notch itself in screen coordinates - real or synthesised.
    let notchRect: CGRect
    /// False when we invented the notch for a display that has none.
    let hasPhysicalNotch: Bool

    var topY: CGFloat { screen.frame.maxY }

    /// Screen-space x of the edge the cluster docks against.
    func anchorX(side: DockSide, offset: CGFloat) -> CGFloat {
        switch side {
        case .left:  return notchRect.minX - offset
        case .right: return notchRect.maxX + offset
        }
    }

    /// nil when there is no screen at all - every display asleep or unplugged.
    static func current(preferred: NSScreen? = nil) -> NotchGeometry? {
        guard let screen = preferred ?? notchedScreen() ?? NSScreen.main ?? NSScreen.screens.first
        else { return nil }
        return NotchGeometry(screen: screen)
    }

    /// Prefer the built-in display when it actually has a notch - that is where
    /// the user expects the dots to live.
    static func notchedScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }
    }

    init(screen: NSScreen) {
        self.screen = screen

        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            self.menuBarHeight = max(left.height, right.height)
            self.notchRect = CGRect(x: left.maxX,
                                    y: screen.frame.maxY - menuBarHeight,
                                    width: right.minX - left.maxX,
                                    height: menuBarHeight)
            self.hasPhysicalNotch = true
        } else {
            // visibleFrame excludes the menu bar; the difference is its height.
            // Fall back to the classic 24pt if the Dock is on top and confuses it.
            let measured = screen.frame.maxY - screen.visibleFrame.maxY
            let height = (measured > 8 && measured < 80) ? measured : 24
            let width: CGFloat = 200
            self.menuBarHeight = height
            self.notchRect = CGRect(x: screen.frame.midX - width / 2,
                                    y: screen.frame.maxY - height,
                                    width: width,
                                    height: height)
            self.hasPhysicalNotch = false
        }
    }
}
