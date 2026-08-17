import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: GlintModel
    private let preferences: Preferences

    init(model: GlintModel, preferences: Preferences) {
        self.model = model
        self.preferences = preferences
    }

    func show() {
        if window == nil { build() }
        // Accessory apps do not activate on their own, and an inactive window
        // will not take keystrokes.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    private func build() {
        let hosting = NSHostingController(rootView: SettingsView(model: model, prefs: preferences))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Glint"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 580, height: 560))

        // The glass has to start at the top of the window or the tab bar floats
        // under an opaque strip and the illusion breaks. The title is already
        // on every card below it, so hiding it costs nothing.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // The vibrancy itself is a background inside the SwiftUI view rather
        // than a layer injected into the window's theme frame. Reaching into
        // the frame works until AppKit rearranges it, and the failure mode
        // there is a transparent window.
        self.window = window
    }
}
