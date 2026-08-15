import AppKit
import Combine
import WebKit

/// What the injected script reports back.
struct WebPayload {
    let status: String
    let count: Int?
    let method: String?
    let detail: String?
    let href: String?

    init(_ dict: [String: Any]) {
        status = dict["status"] as? String ?? "unknown"
        count = (dict["count"] as? NSNumber)?.intValue
        method = dict["method"] as? String
        detail = dict["detail"] as? String
        href = dict["href"] as? String
    }
}

/// A source backed by a signed-in web session kept loaded off-screen.
///
/// This is how Instagram and WhatsApp are read: there is no public unread-count
/// API for either, but both surface the number in the page you are already
/// logged into. Notifly keeps that page alive in the background and reads the
/// same number the browser tab would show you.
@MainActor
final class WebSource: BaseSource, NotificationSource {
    let recipe: WebRecipe
    private let preferences: Preferences

    private var webView: WKWebView?
    private var bridge: WebBridge?
    private var pollTimer: Timer?
    private var reloadTimer: Timer?
    private var loginWindow: LoginWindowController?

    private var lastPayloadAt: Date?
    private var installedExtractor: String?
    private var interstitialBounces = 0
    private var running = false

    /// Surfaced in Settings so a user can see *how* the number was found and
    /// tell "quietly reporting zero" apart from "silently broken".
    @Published private(set) var diagnostics: String = "Not started"

    init(recipe: WebRecipe, preferences: Preferences) {
        self.recipe = recipe
        self.preferences = preferences
        super.init()
    }

    var descriptor: SourceDescriptor { recipe.descriptor }
    var state: SourceState { currentState }

    var remedy: SourceRemedy? {
        switch currentState {
        case .needsAuth:
            return SourceRemedy(title: "Sign in to \(descriptor.name)") { [weak self] in
                self?.presentLogin()
            }
        case .failed:
            return SourceRemedy(title: "Retry") { [weak self] in self?.refresh() }
        default:
            return nil
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
        set(.loading)
        diagnostics = "Loading \(recipe.trackingURL.host ?? "page")…"
        buildWebView()
        load()
        startTimers()
    }

    func stop() {
        running = false
        pollTimer?.invalidate(); pollTimer = nil
        reloadTimer?.invalidate(); reloadTimer = nil
        if let webView {
            webView.stopLoading()
            webView.configuration.userContentController.removeAllUserScripts()
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "notifly")
            HiddenWebHost.shared.release(webView)
        }
        webView = nil
        bridge = nil
        set(.idle)
    }

    func refresh() {
        guard running else { return }
        // A changed custom extractor needs a fresh user script, which means a
        // fresh content controller.
        if installedExtractor != currentExtractor {
            let wasRunning = running
            stop()
            running = wasRunning
            if wasRunning { start() }
            return
        }
        load()
    }

    // MARK: - Web view

    private var currentExtractor: String {
        preferences.customExtractor(for: recipe.kind) ?? recipe.defaultExtractor
    }

    /// Persistent so the login survives quitting the app. Falls back to an
    /// in-memory store when running unbundled, where WebKit has nowhere to put
    /// its data and would otherwise trap.
    private static let dataStore: WKWebsiteDataStore = {
        Bundle.main.bundleIdentifier == nil ? .nonPersistent() : .default()
    }()

    private static let desktopUserAgent =
        ProcessInfo.processInfo.environment["NOTIFLY_UA"]
        ?? ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15")

    private func buildWebView() {
        let extractor = currentExtractor
        installedExtractor = extractor

        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: notiflyBootstrapScript(sourceID: recipe.kind.rawValue, extractor: extractor),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))

        let bridge = WebBridge(
            onPayload: { [weak self] payload in self?.handle(payload) },
            onFinished: { [weak self] url in self?.handleNavigation(to: url) },
            onFailed: { [weak self] error in self?.handleFailure(error) })
        controller.add(bridge, name: "notifly")
        self.bridge = bridge

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = Self.dataStore
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // A realistic viewport: both sites serve a different (or no) layout to
        // something that looks like a tiny headless window.
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900),
                             configuration: config)
        view.customUserAgent = Self.desktopUserAgent
        view.navigationDelegate = bridge
        HiddenWebHost.shared.adopt(view)
        webView = view
    }

    private func load() {
        guard let webView else { return }
        lastPayloadAt = nil
        webView.load(URLRequest(url: recipe.trackingURL,
                                cachePolicy: .reloadRevalidatingCacheData,
                                timeoutInterval: 30))
    }

    private func startTimers() {
        pollTimer?.invalidate()
        let poll = Timer(timeInterval: preferences.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll

        reloadTimer?.invalidate()
        let reload = Timer(timeInterval: preferences.webReloadMinutes * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
        RunLoop.main.add(reload, forMode: .common)
        reloadTimer = reload
    }

    /// Drives the in-page extractor from Swift. WebKit throttles the page's own
    /// timers when the view is off-screen; this one is never throttled.
    /// `NOTIFLY_DEBUG=1` logs every payload plus a survey of the live DOM, which
    /// is the only practical way to work out why a site's markup stopped
    /// matching — the session lives in the app bundle and cannot be inspected
    /// from outside it.
    static let debugLogging = ProcessInfo.processInfo.environment["NOTIFLY_DEBUG"] == "1"

    private func tick() {
        guard let webView else { return }
        webView.evaluateJavaScript("window.__notifly && window.__notifly.tick()") { _, _ in }
        if Self.debugLogging { logDOMSurvey() }

        // Nothing at all for two minutes means the page is wedged — reload it.
        if let last = lastPayloadAt, Date().timeIntervalSince(last) > 120 {
            diagnostics = "No response for 2 min — reloading"
            load()
        }
    }

    // MARK: - Results

    private func logDOMSurvey() {
        let js = #"""
        (function () {
          var out = {
            title: document.title,
            url: location.href,
            paneSide: !!document.querySelector('#pane-side'),
            canvases: document.querySelectorAll('canvas').length,
            listitems: document.querySelectorAll('[role="listitem"]').length,
            rows: document.querySelectorAll('[role="row"]').length,
            gridcells: document.querySelectorAll('[role="gridcell"]').length,
            bodyLen: document.body ? document.body.innerHTML.length : 0,
            text: document.body ? (document.body.innerText || '').replace(/\s+/g, ' ').slice(0, 500) : '',
            labels: []
          };
          var seen = {}, all = document.querySelectorAll('[aria-label]');
          for (var i = 0; i < all.length && out.labels.length < 60; i++) {
            var l = (all[i].getAttribute('aria-label') || '').slice(0, 70);
            if (l && !seen[l]) { seen[l] = 1; out.labels.push(l); }
          }
          return JSON.stringify(out);
        })()
        """#
        webView?.evaluateJavaScript(js) { value, error in
            if let error {
                NSLog("[Notifly:%@] survey error %@", self.recipe.kind.rawValue, error.localizedDescription)
            } else if let text = value as? String {
                NSLog("[Notifly:%@] SURVEY %@", self.recipe.kind.rawValue, text)
            }
        }
    }

    private func handle(_ payload: WebPayload) {
        lastPayloadAt = Date()
        if Self.debugLogging {
            NSLog("[Notifly:%@] payload status=%@ count=%@ method=%@ href=%@",
                  recipe.kind.rawValue, payload.status,
                  payload.count.map(String.init) ?? "-",
                  payload.method ?? "-", payload.href ?? "-")
        }
        switch payload.status {
        case "ok":
            let count = max(0, payload.count ?? 0)
            interstitialBounces = 0
            set(.ok(count: count))
            diagnostics = "\(count) unread — via \(payload.method ?? "?")"
        case "auth":
            set(.needsAuth)
            diagnostics = "Signed out"
        case "error":
            set(.failed(payload.detail ?? "script error"))
            diagnostics = "Extractor error: \(payload.detail ?? "unknown")"
        default:
            // Page not recognisable yet. Don't throw away a good count over a
            // transient re-render — only fall back while we have never had one.
            if currentState.count == nil { set(.loading) }
            diagnostics = "Page not recognised yet"
        }
    }

    private func handleNavigation(to url: URL?) {
        guard let url else { return }

        // Instagram bounces to a "save your login info?" page straight after
        // signing in. The session is fine — just steer back to the inbox. Give
        // up after a few tries so a sticky interstitial cannot spin forever.
        if url.path.contains("/accounts/onetap") {
            guard interstitialBounces < 3 else {
                set(.needsAuth)
                diagnostics = "Stuck on Instagram's save-login prompt — sign in and dismiss it"
                return
            }
            interstitialBounces += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.load() }
            return
        }

        if url.path.contains("/accounts/login") || url.path.contains("/accounts/signup") {
            set(.needsAuth)
            diagnostics = "Signed out"
        }
    }

    private func handleFailure(_ error: Error) {
        let nsError = error as NSError
        // Cancelled loads are routine during redirects; they are not failures.
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        if currentState.count == nil {
            set(.failed(nsError.localizedDescription))
        }
        diagnostics = "Load failed: \(nsError.localizedDescription)"
    }

    // MARK: - Login

    func presentLogin() {
        if let loginWindow {
            loginWindow.show()
            return
        }
        let controller = LoginWindowController(
            recipe: recipe,
            dataStore: Self.dataStore,
            userAgent: Self.desktopUserAgent) { [weak self] in
                self?.loginWindow = nil
                // Cookies are shared with the background view, so a reload is
                // all it takes to pick up the new session.
                self?.set(.loading)
                self?.load()
            }
        loginWindow = controller
        controller.show()
    }
}

/// Bridges WebKit's `@objc` delegates onto the main actor. WebKit already calls
/// these on the main thread; `assumeIsolated` states that instead of hopping.
private final class WebBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let onPayload: @MainActor (WebPayload) -> Void
    private let onFinished: @MainActor (URL?) -> Void
    private let onFailed: @MainActor (Error) -> Void

    init(onPayload: @escaping @MainActor (WebPayload) -> Void,
         onFinished: @escaping @MainActor (URL?) -> Void,
         onFailed: @escaping @MainActor (Error) -> Void) {
        self.onPayload = onPayload
        self.onFinished = onFinished
        self.onFailed = onFailed
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any] else { return }
        let payload = WebPayload(dict)
        MainActor.assumeIsolated { onPayload(payload) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url
        MainActor.assumeIsolated { onFinished(url) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { onFailed(error) }
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        MainActor.assumeIsolated { onFailed(error) }
    }
}

/// Off-screen parent for the background web views. WKWebView needs a window and
/// a sensible frame to lay pages out properly; it does not need to be seen.
@MainActor
final class HiddenWebHost {
    static let shared = HiddenWebHost()
    private let window: NSWindow

    private init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900),
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        window.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces]
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900))
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderBack(nil)
    }

    func adopt(_ view: NSView) {
        view.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1280, height: 900)
        window.contentView?.addSubview(view)
    }

    func release(_ view: NSView) {
        view.removeFromSuperview()
    }
}
