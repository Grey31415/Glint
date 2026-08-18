import AppKit
import SwiftUI
import WebKit

/// A plain browser window for signing in.
///
/// It shares the website data store with the background view, so the cookies it
/// earns are immediately the cookies the background view uses - no session
/// juggling, and the sign-in survives a relaunch.
///
/// Because this is the one window in Glint where a password gets typed, it is
/// pinned: a `NavigationBridge` refuses main-frame navigation away from Meta's
/// sign-in hosts, and the banner is driven by whatever actually loaded rather
/// than asserting in advance whose page this is.
@MainActor
final class LoginWindowController {
    private var window: NSWindow?
    private var observer: NSObjectProtocol?
    private let onClose: () -> Void
    /// Delegates are held weakly by WebKit, so the bridge has to live here.
    private let bridge: NavigationBridge
    private let banner: LoginBannerModel

    init(title: String,
         url: URL,
         dataStore: WKWebsiteDataStore,
         userAgent: String,
         onClose: @escaping () -> Void) {
        self.onClose = onClose

        let banner = LoginBannerModel()
        self.banner = banner
        self.bridge = NavigationBridge(
            allowed: HostAllowlist.signIn,
            onCommitted: { url in banner.show(host: url?.host) },
            onBlocked: { url in banner.show(blocked: url.host ?? url.absoluteString) })

        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680),
                                configuration: config)
        webView.customUserAgent = userAgent
        webView.navigationDelegate = bridge
        webView.autoresizingMask = [.width, .height]
        webView.load(URLRequest(url: url))

        // A standing account of whose page this is, right where the password is
        // about to be typed.
        let bannerHeight: CGFloat = 54
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 680))
        let bannerView = NSHostingView(rootView: LoginBanner(model: banner))
        bannerView.frame = NSRect(x: 0, y: 680 - bannerHeight, width: 520, height: bannerHeight)
        bannerView.autoresizingMask = [.width, .minYMargin]
        webView.frame = NSRect(x: 0, y: 0, width: 520, height: 680 - bannerHeight)
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        container.addSubview(bannerView)

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
        if let window { AppPresence.follow(window) }
        // The app runs as an accessory, so it has to ask for focus explicitly
        // before a text field will accept typing.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
