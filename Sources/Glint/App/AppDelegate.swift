import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()

    private var model: GlintModel!
    private var overlay: OverlayController!
    private var settings: SettingsWindowController?
    private var welcome: WelcomeWindowController?
    private let hotkey = Hotkey()
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPresence.installMenuIfNeeded()
        model = GlintModel(preferences: preferences)

        overlay = OverlayController(model: model, preferences: preferences)
        overlay.onOpenSettings = { [weak self] in self?.openSettings() }
        overlay.onQuit = { NSApp.terminate(nil) }

        model.start()
        overlay.start()

        hotkey.onPress = { [weak self] in self?.overlay.toggleFromKeyboard() }
        applyHotkey()
        // The shortcut can be switched off, and a registration that outlived the
        // switch would be a key combination nobody can account for.
        preferences.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.applyHotkey() }
            .store(in: &bag)

        // A fresh install explains itself before asking for anything. Glint
        // wants an Instagram sign-in, which deserves a straight answer about
        // where the password goes before the field appears.
        let key = "hasLaunchedBefore"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            // A dot beside the notch is only useful if it is there. Switching
            // this on for the first launch rather than asking is the right
            // default for something with no window and no Dock icon - and it is
            // one tick in Settings to undo, which the Welcome window points at.
            preferences.launchAtLogin = true
            showWelcome()
        }
    }

    /// Claims or releases the shortcut to match the setting.
    private func applyHotkey() {
        if preferences.hotkeyEnabled { hotkey.register() } else { hotkey.unregister() }
    }

    /// Launching Glint again - from Spotlight, Finder or the Dock - opens
    /// Settings rather than doing nothing.
    ///
    /// This is the only way back in when the dot is hidden, which is exactly
    /// what hidden mode is for, so it is not optional.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay?.stop()
        model?.stop()
    }

    func showWelcome() {
        welcome = WelcomeWindowController(
            onConnect: { [weak self] in self?.model.source.presentLogin() },
            onLater: { [weak self] in self?.openSettings() })
        welcome?.show()
    }

    func openSettings() {
        if settings == nil {
            settings = SettingsWindowController(model: model, preferences: preferences)
        }
        settings?.show()
    }
}
