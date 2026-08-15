import AppKit
import SwiftUI

/// First-run window. Explains the privacy model before asking for anything.
@MainActor
final class WelcomeWindowController {
    private var window: NSWindow?
    private var observer: NSObjectProtocol?

    init(onConnect: @escaping () -> Void, onLater: @escaping () -> Void) {
        let root = WelcomeView(
            onConnect: { [weak self] in self?.close(); onConnect() },
            onLater: { [weak self] in self?.close(); onLater() })

        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Welcome to Glint"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 560))
        window.center()
        self.window = window

        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.detach() }
            }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
    }

    private func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        window = nil
    }
}
