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

/// Sits between the Instagram session and the UI: applies the user's category
/// toggles and read-watermarks, and publishes the numbers the dot and the hover
/// card render.
@MainActor
final class GlintModel: ObservableObject {
    @Published private(set) var summaries: [KindSummary] = []
    @Published private(set) var total: Int = 0
    @Published private(set) var arrivalTick: Int = 0

    let source: InstagramSource
    let preferences: Preferences

    private var bag = Set<AnyCancellable>()
    private var previousTotal = 0

    init(preferences: Preferences) {
        self.preferences = preferences
        self.source = InstagramSource(preferences: preferences)
    }

    func start() {
        source.$feed
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
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

    /// Threads the card should list: only ones still waiting on you. Anything
    /// read or already answered is gone, so the card stays a to-do list rather
    /// than turning into a second inbox.
    func cardThreads(limit: Int = 8) -> [DirectThread] {
        Array(feed.threads.filter(\.needsAttention).prefix(limit))
    }

    /// Buckets the user asked to be told about, in a stable display order.
    var enabledKinds: Set<ActivityKind> { preferences.enabledKinds }

    // MARK: - Rebuild

    private func rebuild() {
        let enabled = preferences.enabledKinds
        var baselines = preferences.readBaselines
        var baselinesChanged = false

        var next: [KindSummary] = []
        for kind in ActivityKind.allCases where enabled.contains(kind) {
            let raw = feed.count(for: kind)
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
            if preferences.playSoundOnNew { NSSound(named: "Tink")?.play() }
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
        let raw = feed.count(for: kind)
        guard raw > 0 else { return }
        var baselines = preferences.readBaselines
        baselines[kind.rawValue] = raw
        preferences.readBaselines = baselines
        rebuild()
    }

    func markAllRead() {
        var baselines = preferences.readBaselines
        for kind in ActivityKind.allCases {
            let raw = feed.count(for: kind)
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
        await source.send(text, to: thread.id)
    }
}
