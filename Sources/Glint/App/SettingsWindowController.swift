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
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 580, height: 540))
        self.window = window
    }
}
