import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let hub: NotificationHub
    private let preferences: Preferences

    init(hub: NotificationHub, preferences: Preferences) {
        self.hub = hub
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
        let root = SettingsView(hub: hub, prefs: preferences)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Notifly"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 580, height: 500))
        self.window = window
    }
}
