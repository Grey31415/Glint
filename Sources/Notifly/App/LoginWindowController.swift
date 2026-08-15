import AppKit
import WebKit

/// A plain browser window for signing in to a web-backed source.
///
/// It shares the website data store with the background view, so the cookies it
/// earns are immediately the cookies the background view uses — no session
/// juggling, and the sign-in survives a relaunch.
@MainActor
final class LoginWindowController {
    private var window: NSWindow?
    private var observer: NSObjectProtocol?
    private let onClose: () -> Void

    init(recipe: WebRecipe,
         dataStore: WKWebsiteDataStore,
         userAgent: String,
         onClose: @escaping () -> Void) {
        self.onClose = onClose

        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680),
                                configuration: config)
        webView.customUserAgent = userAgent
        webView.autoresizingMask = [.width, .height]
        webView.load(URLRequest(url: recipe.loginURL))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Sign in to \(recipe.descriptor.name)"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let observer = self.observer {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    self.observer = nil
                    self.window = nil
                    self.onClose()
                }
            }
    }

    func show() {
        // The app runs as an accessory, so it has to ask for focus explicitly
        // before a text field will accept typing.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
