import AppKit
import SwiftUI
import WebKit

/// A plain browser window for signing in.
///
/// It shares the website data store with the background view, so the cookies it
/// earns are immediately the cookies the background view uses — no session
/// juggling, and the sign-in survives a relaunch.
@MainActor
final class LoginWindowController {
    private var window: NSWindow?
    private var observer: NSObjectProtocol?
    private let onClose: () -> Void

    init(title: String,
         url: URL,
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
        webView.load(URLRequest(url: url))

        // A standing reminder of whose page this is, right where the password
        // is about to be typed.
        let bannerHeight: CGFloat = 54
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 680))
        let banner = NSHostingView(rootView: LoginBanner())
        banner.frame = NSRect(x: 0, y: 680 - bannerHeight, width: 520, height: bannerHeight)
        banner.autoresizingMask = [.width, .minYMargin]
        webView.frame = NSRect(x: 0, y: 0, width: 520, height: 680 - bannerHeight)
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        container.addSubview(banner)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = title
        window.contentView = container
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
