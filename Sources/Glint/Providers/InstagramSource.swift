import AppKit
import Combine
import WebKit

/// Keeps a signed-in instagram.com session loaded off-screen and reads the
/// inbox and activity feed out of it.
///
/// Instagram has no public unread API. Its own web client calls the endpoints
/// in `InstagramScript`, so Glint runs the same requests from inside the same
/// page: the cookies come along automatically and the result is exactly what
/// the site would show. Nothing leaves the machine.
@MainActor
final class InstagramSource: ObservableObject {
    @Published private(set) var feed = InstagramFeed()
    @Published private(set) var state: FeedState = .loading
    @Published private(set) var diagnostics = "Not started"
    @Published private(set) var lastUpdate: Date?

    private let preferences: Preferences
    private var webView: WKWebView?
    private var bridge: NavigationBridge?
    private var pollTimer: Timer?
    private var reloadTimer: Timer?
    private var loginWindow: LoginWindowController?
    private var interstitialBounces = 0
    private var inFlight = false
    /// Set once a real instagram.com page has finished loading.
    private var hasLoadedPage = false
    private var hasProbed = false
    private var running = false

    static let trackingURL = URL(string: "https://www.instagram.com/direct/inbox/")!
    static let loginURL = URL(string: "https://www.instagram.com/accounts/login/")!
    static let activityURL = URL(string: "https://www.instagram.com/accounts/activity/")!

    static let debugLogging = ProcessInfo.processInfo.environment["GLINT_DEBUG"] == "1"

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
        state = .loading
        diagnostics = "Loading instagram.com…"
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
            HiddenWebHost.shared.release(webView)
        }
        webView = nil
        bridge = nil
    }

    func refresh() {
        guard running else { return }
        poll()
    }

    /// Full page reload — heavier than `refresh`, used when the session looks wedged.
    func reload() { load() }

    /// `GLINT_PROBE=1` dumps the taxonomy of both endpoints: every distinct
    /// notification type with one sample, so a new category can be classified
    /// from what Instagram actually sends rather than from guesswork.
    func probeTaxonomy() {
        guard let webView else { return }
        let js = #"""
        const H = { 'x-ig-app-id': '936619743392459', 'x-requested-with': 'XMLHttpRequest' };
        const out = { itemTypes: {}, storyTypes: {}, reelShareKeys: null };

        const r = await fetch('/api/v1/direct_v2/inbox/?limit=40&thread_message_limit=3',
                              { headers: H, credentials: 'include' });
        if (r.ok) {
          const j = await r.json();
          for (const t of ((j.inbox && j.inbox.threads) || [])) {
            for (const it of (t.items || [])) {
              const ty = it.item_type || 'none';
              if (!out.itemTypes[ty]) {
                out.itemTypes[ty] = {
                  n: 0,
                  mine: !!it.is_sent_by_viewer,
                  sample: String((it.text) || (it.action_log && it.action_log.description) || '').slice(0, 40),
                  sub: it.reel_share ? Object.keys(it.reel_share).slice(0, 12)
                     : (it.story_share ? Object.keys(it.story_share).slice(0, 12) : null),
                  subType: (it.reel_share && it.reel_share.type) || null,
                  reaction: !!(it.action_log && it.action_log.is_reaction_log)
                };
              }
              out.itemTypes[ty].n++;
            }
          }
        }

        const r2 = await fetch('/api/v1/news/inbox/', { headers: H, credentials: 'include' });
        if (r2.ok) {
          const n = await r2.json();
          for (const s of (n.new_stories || []).concat(n.old_stories || [])) {
            const key = String(s.story_type) + '/' + String(s.notif_name || '?');
            if (!out.storyTypes[key]) {
              out.storyTypes[key] = {
                n: 0,
                sample: String((s.args && s.args.text) || '').slice(0, 55)
              };
            }
            out.storyTypes[key].n++;
          }
        }
        return JSON.stringify(out);
        """#
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): NSLog("[Glint:taxonomy] %@", (value as? String) ?? "nil")
            case .failure(let error): NSLog("[Glint:taxonomy] FAILED %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Web view

    private static let dataStore: WKWebsiteDataStore = {
        Bundle.main.bundleIdentifier == nil ? .nonPersistent() : .default()
    }()

    private static let userAgent =
        ProcessInfo.processInfo.environment["GLINT_UA"]
        ?? ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15")

    private func buildWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.dataStore
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let bridge = NavigationBridge(
            onFinished: { [weak self] url in self?.handleNavigation(to: url) },
            onFailed: { [weak self] error in self?.handleFailure(error) })
        self.bridge = bridge

        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900),
                             configuration: config)
        view.customUserAgent = Self.userAgent
        view.navigationDelegate = bridge
        HiddenWebHost.shared.adopt(view)
        webView = view
    }

    private func load() {
        guard let webView else { return }
        hasLoadedPage = false
        webView.load(URLRequest(url: Self.trackingURL,
                                cachePolicy: .reloadRevalidatingCacheData,
                                timeoutInterval: 30))
    }

    private func startTimers() {
        pollTimer?.invalidate()
        let poll = Timer(timeInterval: max(preferences.pollInterval, 5), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
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

    // MARK: - Polling

    private func poll() {
        guard running, let webView, !inFlight else { return }
        // Relative fetches cannot resolve until a real page is loaded — on
        // about:blank they fail with "URL is not valid", which is noise rather
        // than a fault worth showing.
        guard hasLoadedPage, let host = webView.url?.host, host.contains("instagram.com") else {
            diagnostics = "Waiting for instagram.com to load…"
            if Self.debugLogging {
                NSLog("[Glint:wait] loaded=%@ url=%@ loading=%@",
                      hasLoadedPage ? "y" : "n",
                      webView.url?.absoluteString ?? "nil",
                      webView.isLoading ? "y" : "n")
            }
            return
        }
        inFlight = true
        webView.callAsyncJavaScript(InstagramScript.payload,
                                    arguments: [:],
                                    in: nil,
                                    in: .page) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inFlight = false
                switch result {
                case .success(let value):
                    if let json = value as? String { self.apply(json) }
                    else { self.diagnostics = "Unexpected script result" }
                case .failure(let error):
                    // A page mid-navigation cannot run the script; that is
                    // routine, not a failure worth surfacing.
                    self.diagnostics = "Script unavailable: \(error.localizedDescription)"
                }
            }
        }
    }

    private func apply(_ json: String) {
        if Self.debugLogging { NSLog("[Glint:ig] %@", json.prefix(1200).description) }

        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            diagnostics = "Could not parse response"
            return
        }

        switch root["status"] as? String {
        case "auth":
            state = .needsAuth
            diagnostics = "Signed out of Instagram"
            return
        case "error":
            let detail = root["detail"] as? String ?? "unknown"
            // Keep the last good feed rather than blanking the dot on a blip.
            if case .ready = state { diagnostics = "Refresh failed: \(detail)" }
            else { state = .failed(detail); diagnostics = detail }
            return
        default:
            break
        }

        var next = InstagramFeed()
        next.unseenDirect = root["unseenDM"] as? Int ?? 0
        next.pendingRequests = root["pending"] as? Int ?? 0

        for raw in root["threads"] as? [[String: Any]] ?? [] {
            guard let id = raw["id"] as? String, !id.isEmpty else { continue }
            next.threads.append(DirectThread(
                id: id,
                title: raw["title"] as? String ?? "Instagram user",
                fullName: raw["fullName"] as? String ?? "",
                preview: raw["preview"] as? String ?? "",
                kind: MessageKind(rawValue: raw["kind"] as? String ?? "other") ?? .other,
                isUnread: raw["unread"] as? Bool ?? false,
                isMine: raw["mine"] as? Bool ?? false,
                isGroup: raw["group"] as? Bool ?? false,
                isMuted: raw["muted"] as? Bool ?? false,
                date: Self.date(fromMilliseconds: raw["ts"])))
        }

        if let counts = root["counts"] as? [String: Any] {
            for kind in ActivityKind.allCases where !kind.isDirect {
                next.activityCounts[kind] = counts[kind.rawValue] as? Int ?? 0
            }
        }

        for raw in root["activity"] as? [[String: Any]] ?? [] {
            guard let text = raw["text"] as? String, !text.isEmpty else { continue }
            let kindRaw = raw["kind"] as? String ?? "other"
            guard let kind = ActivityKind(rawValue: kindRaw) else { continue }
            next.activity.append(ActivityItem(
                id: (raw["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString,
                text: text,
                kind: kind,
                isNew: raw["isNew"] as? Bool ?? false,
                date: Self.date(fromMilliseconds: raw["ts"])))
        }

        feed = next
        state = .ready
        lastUpdate = Date()
        if Self.debugLogging {
            let byKind = Dictionary(grouping: next.activity, by: \.kind)
                .map { "\($0.key.rawValue):\($0.value.count)" }
                .sorted()
                .joined(separator: " ")
            NSLog("[Glint:parsed] threads=%d unreadMsg=%d unreadReact=%d counts=%@ activity[%d] %@",
                  next.threads.count, next.unreadMessages.count, next.unreadReactions.count,
                  String(describing: next.activityCounts), next.activity.count, byKind)
        }
        let unread = next.unreadMessages.count
        let reactions = next.unreadReactions.count
        diagnostics = "\(next.threads.count) threads · \(unread) unread · \(reactions) reaction"
            + (reactions == 1 ? "" : "s")
    }

    private static func date(fromMilliseconds value: Any?) -> Date {
        guard let ms = (value as? NSNumber)?.doubleValue, ms > 0 else { return .distantPast }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    // MARK: - Navigation

    private func handleNavigation(to url: URL?) {
        guard let url else { return }
        if Self.debugLogging { NSLog("[Glint:nav] %@", url.absoluteString) }
        if url.path.contains("/accounts/onetap") {
            guard interstitialBounces < 3 else {
                state = .needsAuth
                diagnostics = "Stuck on Instagram's save-login prompt"
                return
            }
            interstitialBounces += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.load() }
            return
        }
        if url.path.contains("/accounts/login") || url.path.contains("/accounts/signup") {
            state = .needsAuth
            diagnostics = "Signed out of Instagram"
            return
        }
        interstitialBounces = 0
        hasLoadedPage = url.host?.contains("instagram.com") ?? false
        if hasLoadedPage, ProcessInfo.processInfo.environment["GLINT_PROBE"] == "1", !hasProbed {
            hasProbed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.probeTaxonomy() }
        }
        // Give the SPA a moment to settle before the first read.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.poll() }
    }

    private func handleFailure(_ error: Error) {
        let nsError = error as NSError
        if Self.debugLogging {
            NSLog("[Glint:navfail] %@ (%d)", nsError.localizedDescription, nsError.code)
        }
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        if case .ready = state {
            diagnostics = "Load failed: \(nsError.localizedDescription)"
        } else {
            state = .failed(nsError.localizedDescription)
            diagnostics = nsError.localizedDescription
        }
    }

    // MARK: - Login

    var remedy: (title: String, perform: @MainActor () -> Void)? {
        switch state {
        case .needsAuth:
            return ("Sign in to Instagram", { [weak self] in self?.presentLogin() })
        case .failed:
            return ("Retry", { [weak self] in self?.reload() })
        default:
            return nil
        }
    }

    /// Erases the stored Instagram session from this Mac.
    ///
    /// The privacy promise is only worth as much as the ability to undo it, so
    /// this clears the cookies and local storage WebKit holds for the domain
    /// rather than merely forgetting them in memory.
    func signOut(completion: (() -> Void)? = nil) {
        let store = Self.dataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let instagram = records.filter { $0.displayName.localizedCaseInsensitiveContains("instagram") }
            store.removeData(ofTypes: types, for: instagram) {
                MainActor.assumeIsolated {
                    self.state = .needsAuth
                    self.feed = InstagramFeed()
                    self.diagnostics = "Signed out — session erased from this Mac"
                    self.load()
                    completion?()
                }
            }
        }
    }

    func presentLogin() {
        if let loginWindow { loginWindow.show(); return }
        let controller = LoginWindowController(
            title: "Sign in to Instagram",
            url: Self.loginURL,
            dataStore: Self.dataStore,
            userAgent: Self.userAgent) { [weak self] in
                self?.loginWindow = nil
                self?.state = .loading
                self?.interstitialBounces = 0
                self?.load()
            }
        loginWindow = controller
        controller.show()
    }
}

/// Bridges WebKit's `@objc` navigation delegate onto the main actor. WebKit
/// already calls these on the main thread; `assumeIsolated` states that.
private final class NavigationBridge: NSObject, WKNavigationDelegate {
    private let onFinished: @MainActor (URL?) -> Void
    private let onFailed: @MainActor (Error) -> Void

    init(onFinished: @escaping @MainActor (URL?) -> Void,
         onFailed: @escaping @MainActor (Error) -> Void) {
        self.onFinished = onFinished
        self.onFailed = onFailed
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

/// Off-screen parent for the background web view. WKWebView needs a window and
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

    func release(_ view: NSView) { view.removeFromSuperview() }
}
