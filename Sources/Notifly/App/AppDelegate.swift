import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()

    private var hub: NotificationHub!
    private var overlay: OverlayController!
    private var statusItem: StatusItemController!
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hub = NotificationHub(preferences: preferences)

        overlay = OverlayController(hub: hub, preferences: preferences)
        overlay.onOpenSettings = { [weak self] in self?.openSettings() }
        overlay.onQuit = { NSApp.terminate(nil) }

        statusItem = StatusItemController(
            hub: hub,
            preferences: preferences,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onRefresh: { [weak self] in self?.hub.refreshAll() })

        hub.start()
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

    func applicationWillTerminate(_ notification: Notification) {
        overlay?.stop()
        hub?.stop()
        statusItem?.stop()
    }

    func openSettings() {
        if settings == nil {
            settings = SettingsWindowController(hub: hub, preferences: preferences)
        }
        settings?.show()
    }
}
