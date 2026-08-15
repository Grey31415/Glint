import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats above the menu bar on every
/// Space, including over full-screen apps.
final class OverlayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // .statusBar (25) sits one above the menu bar's own level.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        // Off by default so the menu bar underneath stays usable; the controller
        // switches it on only while the cursor is genuinely over a dot.
        ignoresMouseEvents = true
    }

    /// Needed so clicks land, but `.nonactivatingPanel` keeps the app in the
    /// background - clicking a dot never steals focus from what you were doing.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// `NSHostingView` refuses the first click into an inactive window by default,
/// which would mean every dot needed clicking twice.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unavailable") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
