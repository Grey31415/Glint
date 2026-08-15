import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()

    private var model: GlintModel!
    private var overlay: OverlayController!
    private var statusItem: StatusItemController!
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = GlintModel(preferences: preferences)

        overlay = OverlayController(model: model, preferences: preferences)
        overlay.onOpenSettings = { [weak self] in self?.openSettings() }
        overlay.onQuit = { NSApp.terminate(nil) }

        statusItem = StatusItemController(
            model: model,
            preferences: preferences,
            onOpenSettings: { [weak self] in self?.openSettings() })

        model.start()
        overlay.start()
        statusItem.start()

        // Nothing is connected on a fresh install, so open Settings rather than
        // leaving a single grey dot with no explanation.
        let key = "hasLaunchedBefore"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            openSettings()
        }
    }

    /// Launching Glint again — from Spotlight, Finder or the Dock — opens
    /// Settings rather than doing nothing.
    ///
    /// This is the way back in when both the menu bar item and the dot are
    /// switched off, which is exactly the configuration hidden mode is for.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay?.stop()
        model?.stop()
        statusItem?.stop()
    }

    func openSettings() {
        if settings == nil {
            settings = SettingsWindowController(model: model, preferences: preferences)
        }
        settings?.show()
    }
}
