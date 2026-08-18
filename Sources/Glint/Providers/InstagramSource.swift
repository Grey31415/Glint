import AppKit
import Combine
import Network
import WebKit

/// Keeps a signed-in instagram.com session loaded off-screen and reads the
/// inbox and activity feed out of it.
///
/// Instagram has no public unread API. Its own web client calls the endpoints
/// in `InstagramScript`, so Glint runs the same requests from inside the same
/// page: the cookies come along automatically and the result is exactly what
/// the site would show. Nothing leaves the machine.
/// Outcome of a reply. Deliberately not `Bool`: a send that fails because the
/// session lapsed needs a different answer from one that Instagram refused.
enum SendResult: Equatable {
    case sent
    /// `GLINT_DRY_RUN=1`. The request was built and logged, not sent.
    case dryRun(String)
    case needsAuth
    case failed(String)
}

@MainActor
final class InstagramSource: ObservableObject {
    @Published private(set) var feed = InstagramFeed()
    @Published private(set) var state: FeedState = .loading
    @Published private(set) var diagnostics = "Not started"
    /// When the last poll actually came back with data. The card and Settings
    /// both show it: an app whose whole surface is one dot has to be able to
    /// answer "is this still working" without being taken apart.
    @Published private(set) var lastUpdate: Date?
    /// Whether this Mac has a route to the internet at all.
    @Published private(set) var isOnline = true
    /// Whether the page's own realtime channel is up, and Glint is therefore
    /// reading because something arrived rather than because a timer expired.
    @Published private(set) var isRealtime = false

    /// True when the last successful poll is old enough that the numbers on the
    /// dot should not be taken at face value.
    ///
    /// Three intervals rather than one: a single missed poll is a blip, and a
    /// warning that appears every time a request is slow teaches people to
    /// ignore it. The floor keeps a five-second poll interval from calling
    /// itself stale fifteen seconds later.
    var isStale: Bool {
        guard let lastUpdate else { return true }
        // Three of whatever gap is actually being kept, not three of the one in
        // Settings: with the realtime hook up the heartbeat is minutes apart on
        // purpose, and measuring against the slider would call that overdue.
        let window = max(pollInterval * 3, 90)
        return Date().timeIntervalSince(lastUpdate) > window
    }

    private let preferences: Preferences
    private var webView: WKWebView?
    private var bridge: NavigationBridge?
    private var pollTimer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var reloadTimer: Timer?
    private var loginWindow: LoginWindowController?
    private var interstitialBounces = 0
    private var inFlight = false
    /// Set once a real instagram.com page has finished loading.
    private var hasLoadedPage = false
    private var hasProbed = false
    private var hasProbedSend = false
    private var running = false
    /// Consecutive failed polls, which set how long to wait before the next one.
    private var failures = 0
    private var realtime: RealtimeBridge?
    /// A poll queued by the realtime hook, waiting out its debounce.
    private var realtimeTimer: Timer?
    /// When a poll last actually left, whatever asked for it. The floor under
    /// realtime-triggered reads is measured from this.
    private var lastPoll: Date?
    /// When the feed last came back different. Quiet stretches widen the gap
    /// between heartbeats; anything new narrows it again.
    private var lastChange: Date?
    /// Identity of the feed as last seen, over the fields that mean something.
    /// `InstagramFeed` is `Equatable`, but items without an id of their own get
    /// a fresh `UUID`, so comparing whole feeds reports every poll as a change.
    private var signature = ""
    /// True while the display is asleep or the screen is locked. Nobody can see
    /// the dot, so nothing needs fetching.
    private var dormant = false
    private var sleepObservers: [NSObjectProtocol] = []

    static let trackingURL = URL(string: "https://www.instagram.com/direct/inbox/")!
    static let loginURL = URL(string: "https://www.instagram.com/accounts/login/")!
    static let activityURL = URL(string: "https://www.instagram.com/accounts/activity/")!

    static let debugLogging = ProcessInfo.processInfo.environment["GLINT_DEBUG"] == "1"
    /// Builds and logs the reply request without sending it. The way to work on
    /// the send path without putting a real account near an action block.
    static let dryRun = ProcessInfo.processInfo.environment["GLINT_DRY_RUN"] == "1"

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
        watchForSleep()
        watchForNetwork()
    }

    func stop() {
        running = false
        pathMonitor?.cancel(); pathMonitor = nil
        pollTimer?.invalidate(); pollTimer = nil
        reloadTimer?.invalidate(); reloadTimer = nil
        for observer in sleepObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        sleepObservers = []
        realtimeTimer?.invalidate(); realtimeTimer = nil
        if let webView {
            webView.stopLoading()
            webView.configuration.userContentController
                .removeScriptMessageHandler(forName: RealtimeBridge.name)
            HiddenWebHost.shared.release(webView)
        }
        webView = nil
        bridge = nil
        realtime = nil
        isRealtime = false
    }

    func refresh() {
        guard running else { return }
        poll()
    }

    /// A read because somebody is looking, rather than because a timer expired.
    ///
    /// The heartbeat stretches to minutes on a quiet account, so the menu would
    /// otherwise open on numbers from several minutes ago - the one moment they
    /// are actually being read. Rate limited, because sweeping the cursor past
    /// the dot a few times is one gesture rather than four requests.
    func refreshForViewing() {
        guard running, !dormant else { return }
        if let lastPoll, Date().timeIntervalSince(lastPoll) < 5 { return }
        poll()
    }

    /// Full page reload - heavier than `refresh`, used when the session looks wedged.
    func reload() { load() }

    /// `GLINT_PROBE=1` dumps the taxonomy of both endpoints: every distinct
    /// notification type with one sample, so a new category can be classified
    /// from what Instagram actually sends rather than from guesswork.
    func probeTaxonomy() {
        guard let webView else { return }
        let js = #"""
        const H = { 'x-ig-app-id': '936619743392459', 'x-requested-with': 'XMLHttpRequest' };
        const out = { itemTypes: {}, storyTypes: {}, reelShareKeys: null, threadShape: [] };

        const r = await fetch('/api/v1/direct_v2/inbox/?limit=40&thread_message_limit=10',
                              { headers: H, credentials: 'include' });
        if (r.ok) {
          const j = await r.json();
          for (const t of ((j.inbox && j.inbox.threads) || [])) {
            // How many messages a thread is holding and what marks the point
            // the viewer has read up to. Grouping a chat's unread messages
            // depends entirely on this being present and comparable.
            if (out.threadShape.length < 6) {
              const seen = (t.last_seen_at || {})[String(t.viewer_id)] || null;
              const newest = (t.items || [])[0];
              out.threadShape.push({
                items: (t.items || []).length,
                read_state: t.read_state,
                viewer: String(t.viewer_id || ''),
                lastSeenKeys: t.last_seen_at ? Object.keys(t.last_seen_at) : null,
                seenTs: seen ? String(seen.timestamp) : null,
                seenItem: seen ? String(seen.item_id) : null,
                newestTs: newest ? String(newest.timestamp) : null,
                newerThanSeen: (t.items || []).filter(i =>
                  seen && Number(i.timestamp) > Number(seen.timestamp) && !i.is_sent_by_viewer).length
              });
            }
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

        // Sub-frames as well as the main one: the client has moved this traffic
        // into an embedded document before, and a hook only in the top frame
        // would go silent without saying so.
        let content = WKUserContentController()
        let realtime = RealtimeBridge { [weak self] signal in self?.realtimeSignal(signal) }
        content.add(realtime, name: RealtimeBridge.name)
        content.addUserScript(WKUserScript(source: InstagramScript.realtimeHook,
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: false))
        config.userContentController = content
        self.realtime = realtime

        let bridge = NavigationBridge(
            allowed: HostAllowlist.instagram,
            onFinished: { [weak self] url in self?.handleNavigation(to: url) },
            onFailed: { [weak self] error in self?.handleFailure(error) },
            onBlocked: { [weak self] url in self?.handleBlocked(url) })
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
        // The socket goes with the document, and a page being torn down is not
        // reliable about saying so. The new one announces itself.
        isRealtime = false
        webView.load(URLRequest(url: Self.trackingURL,
                                cachePolicy: .reloadRevalidatingCacheData,
                                timeoutInterval: 30))
    }

    /// How long until the next poll, if nothing asks sooner.
    ///
    /// Three things move it, in this order. Failures double it up to eight
    /// times: a session that has been signed out or throttled does not become
    /// less signed out for being asked every fifteen seconds, it just spends
    /// battery and gives Instagram a reason to throttle harder. With the
    /// realtime hook up, the timer stops being how news arrives and becomes
    /// only the net under it, so it stretches to a minute. And failing both of
    /// those, a feed that has not changed in a while is unlikely to change in
    /// the next fifteen seconds either.
    ///
    /// Every one of these is a ceiling on waiting, never on reading: a frame
    /// from the page, waking, or opening the menu all read immediately.
    private var pollInterval: TimeInterval {
        let base = max(preferences.pollInterval, 5)
        if failures > 0 { return base * min(pow(2, Double(failures)), 8) }
        let raw = isRealtime ? max(base * 4, 60) : base * idleMultiplier
        return min(raw, max(base, 300))
    }

    /// How far the gap has stretched for want of anything happening. Steps
    /// rather than a curve, because the only thing that has to be true is that
    /// an account nobody has written to overnight is not still being asked four
    /// times a minute by morning.
    private var idleMultiplier: Double {
        guard let lastChange else { return 1 }
        switch Date().timeIntervalSince(lastChange) {
        case ..<120:   return 1
        case ..<600:   return 2
        case ..<3_600: return 4
        default:       return 8
        }
    }

    /// Arms the heartbeat for one poll.
    ///
    /// One-shot rather than repeating: the interval now depends on when the
    /// last change was, so it has to be recomputed each time, and timers do not
    /// have a mutable interval. The timer re-arms itself before polling, so a
    /// poll that returns early at one of its guards still leaves a heartbeat
    /// behind it.
    ///
    /// The jitter is for Instagram's benefit rather than ours: a fleet of
    /// clients asking on an exact cadence is a pattern worth rate limiting, and
    /// a few seconds of scatter costs nothing.
    private func scheduleNextPoll() {
        pollTimer?.invalidate()
        guard running, !dormant else { return }
        let delay = pollInterval * Double.random(in: 0.9...1.1)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleNextPoll()
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - Realtime

    /// What the page's own traffic reported.
    ///
    /// `hello` says the hook is installed on a fresh document, `open` and
    /// `close` track the socket, and anything else means a frame arrived. The
    /// frame carries no information Glint can use - see `InstagramScript`
    /// `realtimeHook` for why it is not parsed - so it is treated purely as
    /// permission to read now instead of at the heartbeat.
    private func realtimeSignal(_ signal: String) {
        switch signal {
        case "hello":
            if Self.debugLogging { NSLog("[Glint:rt] hook installed") }
        case "open", "close":
            let up = signal == "open"
            guard isRealtime != up else { return }
            isRealtime = up
            if Self.debugLogging { NSLog("[Glint:rt] channel %@", up ? "up" : "down") }
            // The heartbeat means something different either side of this.
            scheduleNextPoll()
            // Whatever arrived while the socket was down arrived unannounced.
            if up { queueRealtimePoll(floor: min(preferences.pollInterval, 8)) }
        default:
            // A frame on a channel we never saw open still proves one is there.
            if !isRealtime {
                isRealtime = true
                if Self.debugLogging { NSLog("[Glint:rt] channel up (inferred)") }
            }
            let size = signal.split(separator: ":").last.flatMap { Int($0) } ?? 0
            if Self.debugLogging { NSLog("[Glint:rt] frame %d", size) }
            // A ping is not news. Everything else is, to one degree or another.
            guard size > Self.keepaliveFrame else { return }
            queueRealtimePoll(floor: size >= Self.significantFrame
                              ? min(preferences.pollInterval, 8)
                              : preferences.pollInterval)
        }
    }

    /// Frames this size and under are the socket keeping itself alive, about
    /// one a second, and mean nothing at all.
    private static let keepaliveFrame = 2

    /// Frames this size and over are carrying something, and get read at once.
    /// Below it the frame is real but ambiguous - presence, typing, a receipt -
    /// and is read no faster than the fixed timer would have, so a signal
    /// nobody has identified yet still cannot make Glint slower than it was.
    ///
    /// Both numbers are measured rather than guessed; see the working notes in
    /// `CLAUDE.md` for the distribution they came from.
    private static let significantFrame = 64

    /// Turns a burst of frames into one read.
    ///
    /// The debounce is for the burst a single message arrives as - the frame,
    /// the delivery receipt, the typing indicator going away - and the floor is
    /// how much the frame was worth: eight seconds for one carrying something,
    /// and the whole of the old fixed interval for one that might be nothing.
    private func queueRealtimePoll(floor: TimeInterval) {
        guard running, !dormant, isOnline, realtimeTimer == nil else { return }
        // A backoff that a frame can walk straight past is not a backoff. If
        // the last few reads failed, the socket saying something happened does
        // not make this a good moment to ask again.
        guard failures == 0 else { return }
        let sinceLast = lastPoll.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let delay = max(0.8, floor - sinceLast)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.realtimeTimer = nil
                if Self.debugLogging { NSLog("[Glint:rt] read") }
                self.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        realtimeTimer = timer
    }

    /// Stops polling while nobody can see the dot, and catches up on waking.
    ///
    /// Two different notification centres, because macOS reports these in two
    /// different places: display sleep is a workspace notification, and the lock
    /// screen is a distributed one that has no constant to name it.
    private func watchForSleep() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        func on(_ name: Notification.Name, in centre: NotificationCenter, _ body: @escaping @MainActor () -> Void) {
            sleepObservers.append(centre.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { body() }
            })
        }
        func onDistributed(_ name: String, _ body: @escaping @MainActor () -> Void) {
            sleepObservers.append(distributed.addObserver(forName: Notification.Name(name),
                                                          object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { body() }
            })
        }

        on(NSWorkspace.screensDidSleepNotification, in: workspace) { [weak self] in self?.goDormant() }
        on(NSWorkspace.willSleepNotification, in: workspace) { [weak self] in self?.goDormant() }
        on(NSWorkspace.screensDidWakeNotification, in: workspace) { [weak self] in self?.wake() }
        on(NSWorkspace.didWakeNotification, in: workspace) { [weak self] in self?.wake() }
        onDistributed("com.apple.screenIsLocked") { [weak self] in self?.goDormant() }
        onDistributed("com.apple.screenIsUnlocked") { [weak self] in self?.wake() }
    }

    private func goDormant() {
        guard running, !dormant else { return }
        dormant = true
        pollTimer?.invalidate(); pollTimer = nil
        realtimeTimer?.invalidate(); realtimeTimer = nil
        if Self.debugLogging { NSLog("[Glint:poll] dormant") }
    }

    /// Comes back with one immediate poll rather than waiting out the interval:
    /// the whole point of looking at the screen again is to see what arrived.
    private func wake() {
        guard running, dormant else { return }
        dormant = false
        if Self.debugLogging { NSLog("[Glint:poll] awake") }
        scheduleNextPoll()
        poll()
    }

    private func startTimers() {
        scheduleNextPoll()

        reloadTimer?.invalidate()
        let reload = Timer(timeInterval: preferences.webReloadMinutes * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
        RunLoop.main.add(reload, forMode: .common)
        reloadTimer = reload
    }

    /// `GLINT_PROBE_SEND=1`. Reports which send path the site actually routes.
    func probeSendEndpoints() {
        guard let webView else { return }
        webView.callAsyncJavaScript(InstagramScript.probeSendEndpoints,
                                    arguments: [:],
                                    in: nil,
                                    in: .page) { result in
            switch result {
            case .success(let value): NSLog("[Glint:sendprobe] %@", (value as? String) ?? "nil")
            case .failure(let error): NSLog("[Glint:sendprobe] FAILED %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Sending

    /// Sends one reply. Only ever called from a deliberate press.
    func send(_ text: String, to threadID: String) async -> SendResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("Nothing to send") }
        // Says which precondition failed. "Not connected" on its own sent the
        // last round of debugging looking in the wrong place.
        guard let webView else { return .failed("No web view") }
        guard hasLoadedPage else { return .failed("Page still loading, try again in a moment") }
        guard HostAllowlist.allows(webView.url, HostAllowlist.instagram) else {
            return .failed("Page is on \(webView.url?.host ?? "nothing"), not instagram.com")
        }

        let raw: String? = await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(
                InstagramScript.sendTextGraphQL,
                arguments: ["threadID": threadID,
                            "text": trimmed,
                            "dryRun": Self.dryRun,
                            "docID": InstagramScript.sendDocID,
                            "friendlyName": InstagramScript.sendFriendlyName],
                in: nil,
                in: .page) { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value as? String)
                    case .failure: continuation.resume(returning: nil)
                    }
                }
        }

        // Always logged. One line per deliberate press is not noise, and a
        // refusal is unreadable without the body Instagram sent back.
        NSLog("[Glint:send] %@", raw ?? "no result from script")

        guard let raw,
              let data = raw.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failed("The page could not run the send script")
        }

        let detail = root["detail"] as? String ?? ""
        switch root["status"] as? String {
        case "ok":
            // Pull the thread list straight away so the row reflects the reply
            // instead of waiting out the poll interval.
            refresh()
            return .sent
        case "dry":
            return .dryRun(detail)
        case "auth":
            state = .needsAuth
            return .needsAuth
        case "stale":
            // The one failure with a known cure, so it says so instead of
            // handing back whatever Instagram happened to answer with.
            NSLog("[Glint:send] doc_id looks stale: %@", detail)
            return .failed("Instagram changed its send endpoint. Sending needs a new doc_id.")
        default:
            return .failed(detail.isEmpty ? "Instagram refused the message" : detail)
        }
    }

    // MARK: - Polling

    private func poll() {
        guard running, !dormant, let webView, !inFlight else { return }
        // Nothing to gain from a request that cannot leave the machine, and the
        // failures it would bank push the next real attempt into a backoff.
        guard isOnline else { return }
        // Relative fetches cannot resolve until a real page is loaded - on
        // about:blank they fail with "URL is not valid", which is noise rather
        // than a fault worth showing.
        guard hasLoadedPage, HostAllowlist.allows(webView.url, HostAllowlist.instagram) else {
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
        lastPoll = Date()
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

        // Whatever this poll turns out to say, the next heartbeat is measured
        // from here rather than from whenever the last timer happened to fire.
        defer { scheduleNextPoll() }

        switch root["status"] as? String {
        case "auth":
            // Signed out counts as a failure for pacing purposes. It cannot fix
            // itself, and asking faster will not make it.
            failures = min(failures + 1, 3)
            state = .needsAuth
            diagnostics = "Signed out of Instagram"
            return
        case "error":
            failures = min(failures + 1, 3)
            let detail = root["detail"] as? String ?? "unknown"
            // Keep the last good feed rather than blanking the dot on a blip.
            if case .ready = state { diagnostics = "Refresh failed: \(detail)" }
            else { state = .failed(detail); diagnostics = detail }
            return
        default:
            failures = 0
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
                date: Self.date(fromMilliseconds: raw["ts"]),
                messages: (raw["messages"] as? [[String: Any]] ?? []).map { m in
                    ThreadMessage(id: m["id"] as? String ?? UUID().uuidString,
                                  preview: m["preview"] as? String ?? "",
                                  kind: MessageKind(rawValue: m["kind"] as? String ?? "other") ?? .other,
                                  image: (m["image"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
                                  date: Self.date(fromMilliseconds: m["ts"]))
                },
                unreadCount: raw["unreadCount"] as? Int ?? 0))
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
                actor: raw["actor"] as? String ?? "",
                actorID: raw["actorID"] as? String ?? "",
                kind: kind,
                isNew: raw["isNew"] as? Bool ?? false,
                date: Self.date(fromMilliseconds: raw["ts"])))
        }

        let fresh = Self.signature(of: next)
        if fresh != signature {
            signature = fresh
            lastChange = Date()
        }

        feed = next
        state = .ready
        lastUpdate = Date()
        if Self.debugLogging {
            // Actors are named here because grouping the card by person is
            // only as good as this field: an empty one falls out of the
            // grouping and back into a bare per-kind tally.
            let byKind = Dictionary(grouping: next.activity, by: \.kind)
                .map { kind, items -> String in
                    let named = items.filter { !$0.actor.isEmpty }.count
                    return "\(kind.rawValue):\(items.count)(named \(named))"
                }
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

    /// A short string that changes when the feed says something new.
    ///
    /// Only fields Instagram supplies go in: ids, timestamps and counts. Ones
    /// Glint invents when a payload has none would differ on every poll, and a
    /// feed that always looks new would hold the interval at its floor forever
    /// - which is the fixed timer again, wearing a hat.
    private static func signature(of feed: InstagramFeed) -> String {
        var parts = ["\(feed.unseenDirect)", "\(feed.pendingRequests)"]
        for thread in feed.threads {
            parts.append("\(thread.id):\(thread.unreadCount):\(thread.date.timeIntervalSince1970)")
        }
        for kind in ActivityKind.allCases {
            parts.append("\(kind.rawValue):\(feed.activityCounts[kind] ?? 0)")
        }
        parts.append("act:\(feed.activity.count):"
                     + "\(feed.activity.map(\.date).max()?.timeIntervalSince1970 ?? 0)")
        return parts.joined(separator: "|")
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
        hasLoadedPage = HostAllowlist.allows(url, HostAllowlist.instagram)
        if hasLoadedPage, ProcessInfo.processInfo.environment["GLINT_PROBE"] == "1", !hasProbed {
            hasProbed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.probeTaxonomy() }
        }
        // GLINT_PROBE_SEND=1 fires one real POST at a thread id that cannot
        // exist. Nothing can be delivered, and the reply separates a rejected
        // session from wrong parameters, which a dry run cannot do.
        if hasLoadedPage, ProcessInfo.processInfo.environment["GLINT_PROBE_SEND"] == "1", !hasProbedSend {
            hasProbedSend = true
            // Runs the real send path against the first thread in the inbox.
            // Pair it with GLINT_DRY_RUN=1 and nothing is posted: the request
            // is assembled, the page tokens are read, and the result says
            // whether they were found.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self else { return }
                guard let thread = self.feed.threads.first else {
                    NSLog("[Glint:sendprobe] no threads loaded yet")
                    return
                }
                Task {
                    let result = await self.send("glint probe", to: thread.id)
                    NSLog("[Glint:sendprobe] thread=%@ result=%@",
                          thread.id, String(describing: result))
                }
            }
        }
        // Give the SPA a moment to settle before the first read.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.poll() }
    }

    /// Watches the machine's own connectivity, so a poll that cannot possibly
    /// succeed says so instead of failing quietly.
    ///
    /// Without this a lost network looked exactly like everything being fine:
    /// the last good feed stayed on the dot, the failure went into
    /// `diagnostics`, and `diagnostics` is only visible with Settings open.
    /// The state is set from the path rather than inferred from failed polls,
    /// because those take three attempts and a backoff to accumulate.
    private func watchForNetwork() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkChanged(online: up) }
        }
        monitor.start(queue: DispatchQueue(label: "com.grey31415.Glint.network"))
    }

    private func networkChanged(online: Bool) {
        guard isOnline != online else { return }
        isOnline = online
        if Self.debugLogging { NSLog("[Glint:net] %@", online ? "online" : "offline") }
        if online {
            // Straight back to work rather than waiting out whatever backoff the
            // failures earned while there was no network to speak of.
            failures = 0
            if case .offline = state { state = .loading }
            diagnostics = "Network back, reconnecting…"
            refresh()
        } else {
            state = .offline
            diagnostics = "No network connection"
        }
    }

    /// A main-frame navigation to something that is not Instagram was refused.
    ///
    /// Clearing `hasLoadedPage` is the part that matters: it stops `poll()` and
    /// `send()`, so neither Glint's reading script nor a typed reply can run
    /// against a page that arrived from somewhere else. There is deliberately no
    /// reload here - if Instagram really is redirecting, retrying immediately
    /// would spin. The reload timer comes back around on its own.
    private func handleBlocked(_ url: URL) {
        hasLoadedPage = false
        if Self.debugLogging { NSLog("[Glint:blocked] %@", url.host ?? url.absoluteString) }
        diagnostics = "Blocked a page load from \(url.host ?? "an unknown host")"
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
        case .offline:
            return ("Try again", { [weak self] in self?.reload() })
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
                    self.diagnostics = "Signed out - session erased from this Mac"
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

/// Carries the realtime hook's one-word reports onto the main actor.
///
/// Kept separate from the source itself because `WKUserContentController`
/// retains its handlers, and an `InstagramSource` held by its own web view
/// would never be released.
private final class RealtimeBridge: NSObject, WKScriptMessageHandler {
    static let name = "glintRealtime"

    private let onSignal: @MainActor (String) -> Void

    init(onSignal: @escaping @MainActor (String) -> Void) {
        self.onSignal = onSignal
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        // Anything but a string means the page is posting on this name for its
        // own reasons, which is not something to act on.
        guard let signal = message.body as? String else { return }
        MainActor.assumeIsolated { onSignal(signal) }
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
