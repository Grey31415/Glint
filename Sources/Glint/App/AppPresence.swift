import AppKit

/// Puts Glint in the Dock and the app switcher for exactly as long as it has a
/// real window open, and takes it back out afterwards.
///
/// `LSUIElement` buys the thing the dot is for: no Dock icon, no switcher entry,
/// nothing in the way. It also means Settings and the sign-in page cannot be
/// tabbed back to once another window covers them, because Cmd-Tab lists apps
/// rather than windows and an accessory app is not on that list. Both facts are
/// wanted, just not at the same moment - so the activation policy follows the
/// windows instead of being decided once at launch.
///
/// There is no halfway house to aim for. The Dock icon and the switcher entry
/// are the same switch (`.regular`), so a window you can tab back to necessarily
/// has an icon for as long as it is open. What the user does not want is an icon
/// sitting there with nothing open, and that is what this avoids.
@MainActor
enum AppPresence {
    private static var open: Set<ObjectIdentifier> = []
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Call as a window is about to be shown, before activating it: a window
    /// ordered front while the app is still an accessory does not reliably come
    /// forward. Closing is handled here, so callers have nothing to balance.
    static func follow(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard !open.contains(key) else { return }
        open.insert(key)
        observers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main) { _ in
                MainActor.assumeIsolated { forget(key) }
            }
        apply()
    }

    private static func forget(_ key: ObjectIdentifier) {
        if let observer = observers.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(observer)
        }
        open.remove(key)
        apply()
    }

    private static func apply() {
        let policy: NSApplication.ActivationPolicy = open.isEmpty ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    /// Glint had no menu bar at all, which is invisible until you notice that
    /// Cmd-W will not close a window and Cmd-V will not paste a password into
    /// the sign-in page. Those key equivalents come from menu items and nowhere
    /// else - including in the reply field beside the notch, which activates the
    /// app without opening any window, so this is installed at launch rather
    /// than when the first window appears.
    ///
    /// Built once and left in place. An accessory app's menu is never drawn, so
    /// there is nothing to tear down and nothing to see the rest of the time.
    static func installMenuIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let name = ProcessInfo.processInfo.processName

        let app = NSMenuItem()
        app.submenu = NSMenu()
        app.submenu?.items = [
            NSMenuItem(title: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            .separator(),
            NSMenuItem(title: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]

        let edit = NSMenuItem()
        edit.submenu = NSMenu(title: "Edit")
        edit.submenu?.items = [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"),
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ]

        let window = NSMenuItem()
        window.submenu = NSMenu(title: "Window")
        window.submenu?.items = [
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
            NSMenuItem(title: "Minimise", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
        ]

        let menu = NSMenu()
        menu.items = [app, edit, window]
        NSApp.mainMenu = menu
        NSApp.windowsMenu = window.submenu
    }
}
