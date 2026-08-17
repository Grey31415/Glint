import AppKit
import Combine

/// One bucket as the UI should show it: what it is, how many are waiting, and
/// how many the read-watermark is currently hiding.
struct KindSummary: Identifiable, Equatable {
    let kind: ActivityKind
    /// After the read-watermark.
    let count: Int
    /// Before it.
    let rawCount: Int
    var suppressed: Int { max(0, rawCount - count) }
    var id: String { kind.rawValue }
}

/// Something you sent from the menu, kept locally.
///
/// Instagram echoes a reply back on the next poll, but only as the preview line
/// of a thread that has by then stopped waiting on you - which is to say the row
/// disappears and takes the evidence with it. Our own copy is what lets the
/// answer sit under the message it answers, long enough to read.
struct SentReply: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let date: Date
}

/// Sits between the Instagram session and the UI: applies the user's category
/// toggles and read-watermarks, and publishes the numbers the dot and the hover
/// card render.
@MainActor
final class GlintModel: ObservableObject {
    @Published private(set) var summaries: [KindSummary] = []
    @Published private(set) var total: Int = 0
    @Published private(set) var arrivalTick: Int = 0
    /// Replies sent from the menu this session, by thread.
    @Published private(set) var sentReplies: [String: [SentReply]] = [:]

    let source: InstagramSource
    let preferences: Preferences

    private var bag = Set<AnyCancellable>()
    private var previousTotal = 0

    init(preferences: Preferences) {
        self.preferences = preferences
        self.source = InstagramSource(preferences: preferences)
    }

    /// The sound something new makes. Named in one place so the arrival and the
    /// Test button in Settings cannot end up playing different things.
    static func arrivalSound() { NSSound(named: Preferences.alertSoundName)?.play() }

    func start() {
        source.$feed
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &bag)

        // `state` and `lastUpdate` read straight through to the source, so a
        // change in either has to be announced here or nothing observing this
        // model repaints. Signing out moves the state without touching the
        // feed, which left the menu showing, and measuring, the wrong contents.
        source.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)

        preferences.objectWillChange
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &bag)

        source.start()
        rebuild()
    }

    func stop() {
        bag.removeAll()
        source.stop()
    }

    var state: FeedState { source.state }
    var feed: InstagramFeed { source.feed }

    /// How long a thread you have answered stays on the card.
    ///
    /// Long enough that the answer is still there when you glance back, short
    /// enough that the card does not silt up with finished conversations.
    static let replyLinger: TimeInterval = 5 * 60

    /// Threads the user has not asked to be left alone about.
    ///
    /// Muted and group are read straight off the inbox and were, until now,
    /// parsed and thrown away. Filtering here rather than when the feed is built
    /// means switching either setting takes effect on the spot, without waiting
    /// for the next poll.
    private var visibleThreads: [DirectThread] {
        feed.threads.filter { thread in
            if preferences.ignoreMuted, thread.isMuted { return false }
            if preferences.ignoreGroups, thread.isGroup { return false }
            return true
        }
    }

    /// What a bucket holds before the read-watermark, with the thread filters
    /// already applied. The activity kinds have no threads to filter, so they
    /// read straight through.
    func rawCount(for kind: ActivityKind) -> Int {
        switch kind {
        case .messages:  return visibleThreads.filter { $0.isUnread && $0.bucket == .messages }.count
        case .reactions: return visibleThreads.filter { $0.isUnread && $0.bucket == .reactions }.count
        default:         return feed.count(for: kind)
        }
    }

    /// Threads the card should list: ones still waiting on you, plus ones you
    /// have just answered. Anything read is gone, so the card stays a to-do list
    /// rather than turning into a second inbox.
    func cardThreads(limit: Int = 8) -> [DirectThread] {
        Array(visibleThreads
            .filter { $0.needsAttention || sentReplies[$0.id] != nil }
            .prefix(limit))
    }

    /// What you sent into this thread, oldest first.
    func replies(to threadID: String) -> [SentReply] {
        sentReplies[threadID] ?? []
    }

    /// Drops answers old enough that the thread should have gone quiet again.
    private func pruneSentReplies() {
        guard !sentReplies.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-Self.replyLinger)
        let kept = sentReplies.compactMapValues { replies -> [SentReply]? in
            let live = replies.filter { $0.date > cutoff }
            return live.isEmpty ? nil : live
        }
        if kept != sentReplies { sentReplies = kept }
    }

    /// Buckets the user asked to be told about, in a stable display order.
    var enabledKinds: Set<ActivityKind> { preferences.enabledKinds }

    // MARK: - Rebuild

    private func rebuild() {
        pruneSentReplies()
        let enabled = preferences.enabledKinds
        var baselines = preferences.readBaselines
        var baselinesChanged = false

        var next: [KindSummary] = []
        for kind in ActivityKind.allCases where enabled.contains(kind) {
            let raw = rawCount(for: kind)
            // The watermark can never exceed the real count, so reading things
            // on Instagram itself releases it instead of muting it forever.
            let stored = baselines[kind.rawValue] ?? 0
            let baseline = min(stored, raw)
            if baseline == 0 {
                if baselines.removeValue(forKey: kind.rawValue) != nil { baselinesChanged = true }
            } else if stored != baseline {
                baselines[kind.rawValue] = baseline
                baselinesChanged = true
            }
            next.append(KindSummary(kind: kind, count: raw - baseline, rawCount: raw))
        }
        if baselinesChanged { preferences.readBaselines = baselines }

        let newTotal = next.reduce(0) { $0 + $1.count }
        if newTotal > previousTotal {
            arrivalTick &+= 1
            if preferences.playSoundOnNew { Self.arrivalSound() }
        }
        previousTotal = newTotal

        if next != summaries { summaries = next }
        if newTotal != total { total = newTotal }

        if InstagramSource.debugLogging {
            let rows = cardThreads()
            NSLog("[Glint:card] total=%d rows=%d %@", newTotal, rows.count,
                  rows.map { "\($0.title)/\($0.kind.rawValue)\($0.isUnread ? "*" : "")" }
                      .joined(separator: ", "))
        }
    }

    // MARK: - Mark as read

    /// Instagram will not let anything be marked read from outside without
    /// opening the conversation, so this is a local watermark: remember what
    /// the count was and show only what arrives after.
    func markRead(_ kind: ActivityKind) {
        let raw = rawCount(for: kind)
        guard raw > 0 else { return }
        var baselines = preferences.readBaselines
        baselines[kind.rawValue] = raw
        preferences.readBaselines = baselines
        rebuild()
    }

    func markAllRead() {
        var baselines = preferences.readBaselines
        for kind in ActivityKind.allCases {
            let raw = rawCount(for: kind)
            if raw > 0 { baselines[kind.rawValue] = raw }
        }
        preferences.readBaselines = baselines
        rebuild()
    }

    func clearReadMarks() {
        guard !preferences.readBaselines.isEmpty else { return }
        preferences.readBaselines = [:]
        rebuild()
    }

    var totalSuppressed: Int { summaries.reduce(0) { $0 + $1.suppressed } }

    // MARK: - Actions

    func openInbox() {
        NSWorkspace.shared.open(InstagramSource.trackingURL)
    }

    func open(_ thread: DirectThread) {
        guard let url = thread.url else { return openInbox() }
        NSWorkspace.shared.open(url)
    }

    func open(_ kind: ActivityKind) {
        switch kind {
        case .messages, .reactions, .requests: openInbox()
        default: NSWorkspace.shared.open(InstagramSource.activityURL)
        }
    }

    func refresh() { source.refresh() }

    /// Replies in an existing thread. The one thing Glint writes.
    func send(_ text: String, to thread: DirectThread) async -> SendResult {
        let result = await source.send(text, to: thread.id)
        // Only a real send is remembered. A dry run that left an answer on the
        // card would be claiming something that never left the machine.
        if case .sent = result {
            sentReplies[thread.id, default: []].append(SentReply(text: text, date: Date()))
        }
        return result
    }
}
