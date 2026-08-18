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
    /// When each thread was last answered from here, kept beyond the linger so
    /// a conversation cannot come back just because Instagram has not noticed.
    @Published private(set) var answered: [String: Date] = [:]
    /// Unsent messages, by thread. Published because the copy of the card that
    /// measures the menu renders them too, and it can only report the right
    /// height if it lays out the same number of lines as the real field.
    @Published private(set) var drafts: [String: String] = [:]

    let source: InstagramSource
    let preferences: Preferences

    private var bag = Set<AnyCancellable>()
    private var previousTotal = 0
    private var lingerTimer: Timer?
    private var draftTimer: Timer?

    init(preferences: Preferences) {
        self.preferences = preferences
        self.source = InstagramSource(preferences: preferences)
        self.drafts = preferences.keepDrafts ? preferences.drafts : [:]
    }

    /// What was typed into a thread's reply field and not sent.
    func draft(for threadID: String) -> String { drafts[threadID] ?? "" }

    /// Remembers a draft, and eventually writes it down.
    ///
    /// Memory first and disk on a delay: this runs on every keystroke, and
    /// `UserDefaults` is not where per-keystroke writes belong. The delay is
    /// short enough that anything worth keeping has landed before the menu is
    /// closed and forgotten about.
    func setDraft(_ text: String, for threadID: String) {
        guard preferences.keepDrafts else { return }
        if text.isEmpty { drafts.removeValue(forKey: threadID) }
        else { drafts[threadID] = text }
        draftTimer?.invalidate()
        draftTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.persistDrafts() }
        }
    }

    private func persistDrafts() {
        preferences.drafts = drafts
    }

    /// Drops every draft, for the setting being switched off.
    func clearDrafts() {
        drafts = [:]
        preferences.drafts = [:]
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

    /// How long a thread you have answered stays on the card. The reasoning is
    /// on `Preferences.replyLinger`, which owns the number.
    var replyLinger: TimeInterval { preferences.replyLinger * 60 }

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
        case .messages:  return countedThreads.filter { $0.isUnread && $0.bucket == .messages }.count
        case .reactions: return countedThreads.filter { $0.isUnread && $0.bucket == .reactions }.count
        default:         return feed.count(for: kind)
        }
    }

    /// True once you have answered a thread and nothing has arrived since.
    ///
    /// Instagram keeps calling the thread unread until the next poll catches
    /// up - replying is not reading - so answering has to be remembered here or
    /// a conversation you have dealt with goes on counting. The date comparison
    /// is what brings the row back the moment they write again.
    private func isAnswered(_ thread: DirectThread) -> Bool {
        guard let when = answered[thread.id] else { return false }
        return thread.date <= when
    }

    /// Threads that still count towards the dot. Answering drops one out
    /// immediately, whatever the card is still showing.
    private var countedThreads: [DirectThread] {
        visibleThreads.filter { !isAnswered($0) }
    }

    /// Threads the card should list: ones still waiting on you, plus ones you
    /// have just answered and whose linger has not run out. Anything read is
    /// gone, so the card stays a to-do list rather than turning into a second
    /// inbox.
    func cardThreads(limit: Int = 8) -> [DirectThread] {
        let now = Date()
        return Array(visibleThreads
            .filter { thread in
                if let when = answered[thread.id], thread.date <= when {
                    return now.timeIntervalSince(when) < replyLinger
                }
                return thread.needsAttention
            }
            .prefix(limit))
    }

    /// One correspondent's worth of what is waiting: their conversation, if
    /// there is one, and whatever they have done to your posts.
    ///
    /// The card used to list conversations and then, under a rule, a tally per
    /// kind - so somebody who had written to you *and* liked two of your photos
    /// appeared twice, in two different vocabularies. A person is the unit the
    /// eye groups by anyway.
    struct CardEntry: Identifiable, Equatable {
        /// The thread id where there is a thread, so a row keeps its identity
        /// across polls and the reply field stays open on it.
        let id: String
        let name: String
        let thread: DirectThread?
        let activity: [ActivityItem]
        let date: Date

        /// Kinds present in `activity`, longest-first by count, for the icon on
        /// a row that has no conversation to lead with.
        var kinds: [ActivityKind] {
            let tally = Dictionary(grouping: activity, by: \.kind).mapValues(\.count)
            return tally.sorted { ($0.value, $0.key.rawValue) > ($1.value, $1.key.rawValue) }.map(\.key)
        }

        /// "2 likes, 1 comment".
        var activityLine: String {
            ActivityKind.allCases.compactMap { kind in
                let n = activity.filter { $0.kind == kind }.count
                guard n > 0 else { return nil }
                let noun = kind.shortNoun(count: n)
                return "\(n) \(noun)"
            }.joined(separator: ", ")
        }
    }

    /// The card's rows: a conversation and its author's activity as one thing.
    ///
    /// Threads keep the top of the list and their existing order - they are the
    /// things that actually want an answer - and people who have only been busy
    /// in your notifications follow, newest first.
    func cardEntries(limit: Int = 8) -> [CardEntry] {
        var pool = attributableActivity()
        var entries: [CardEntry] = []

        // With messages and reactions both switched off there are no
        // conversations to lead a row with, so everyone falls through to being
        // named by their activity alone.
        let threads = (preferences.isEnabled(.messages) || preferences.isEnabled(.reactions))
            ? cardThreads(limit: limit) : []

        for thread in threads {
            // Only a one-to-one thread has a single author to match against.
            // A group's title is several usernames joined, and matching it
            // against one of them would file everyone's likes under the group.
            let key = thread.isGroup ? nil : thread.title.lowercased()
            let mine = key.flatMap { pool.removeValue(forKey: $0) } ?? []
            entries.append(CardEntry(id: thread.id,
                                     name: thread.title,
                                     thread: thread,
                                     activity: mine,
                                     date: thread.date))
        }

        let strangers = pool.values
            .compactMap { items -> CardEntry? in
                guard let newest = items.max(by: { $0.date < $1.date }) else { return nil }
                return CardEntry(id: "actor:" + newest.actorKey,
                                 name: newest.actor,
                                 thread: nil,
                                 activity: items,
                                 date: newest.date)
            }
            .sorted { $0.date > $1.date }

        return entries + strangers.prefix(limit)
    }

    /// Activity that can be placed against a person, keyed by whichever name a
    /// thread title would match.
    ///
    /// Budgeted per kind by what the watermark leaves visible, newest first, so
    /// marking likes read removes rows rather than leaving the card disagreeing
    /// with the dot. Items Instagram gave no actor for are left out here and
    /// counted in `unattributedActivity` instead.
    private func attributableActivity() -> [String: [ActivityItem]] {
        var pool: [String: [ActivityItem]] = [:]
        for summary in summaries where !summary.kind.isDirect && summary.count > 0 {
            for item in visibleActivity(for: summary.kind, budget: summary.count) where !item.actor.isEmpty {
                pool[item.actor.lowercased(), default: []].append(item)
            }
        }
        return pool.mapValues { $0.sorted { $0.date > $1.date } }
    }

    /// The newest `budget` unseen items of a kind that name who did them.
    private func visibleActivity(for kind: ActivityKind, budget: Int) -> [ActivityItem] {
        Array(feed.items(for: kind)
            .filter { $0.isNew && !$0.actor.isEmpty }
            .sorted { $0.date > $1.date }
            .prefix(budget))
    }

    /// What is left of each bucket once the rows above have claimed what they
    /// can name. Instagram sometimes reports a count with no stories behind it -
    /// see the aggregate fallback in the injected script - and that number has
    /// to stay visible or the dot and the card stop agreeing.
    func unattributedActivity() -> [KindSummary] {
        summaries.compactMap { summary in
            guard !summary.kind.isDirect, summary.count > 0 else { return nil }
            let named = visibleActivity(for: summary.kind, budget: summary.count).count
            let left = summary.count - named
            guard left > 0 else { return nil }
            return KindSummary(kind: summary.kind, count: left, rawCount: summary.rawCount)
        }
    }

    /// What you sent into this thread, oldest first.
    func replies(to threadID: String) -> [SentReply] {
        sentReplies[threadID] ?? []
    }

    /// Wakes up when the oldest answer on the card is due to leave.
    ///
    /// Pruning happens on rebuild, and rebuilds are driven by the poll, so
    /// without this a two-minute linger would end at whatever moment the next
    /// poll happened to fall.
    private func scheduleLingerExpiry() {
        lingerTimer?.invalidate()
        guard let oldest = sentReplies.values.flatMap({ $0 }).map(\.date).min() else { return }
        let due = oldest.addingTimeInterval(replyLinger).timeIntervalSinceNow
        lingerTimer = Timer.scheduledTimer(withTimeInterval: max(due, 0.2), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.rebuild()
                self?.scheduleLingerExpiry()
            }
        }
    }

    /// Drops answers old enough that the thread should have gone quiet again,
    /// and forgets threads answered long enough ago that the poll has certainly
    /// caught up with them.
    private func pruneSentReplies() {
        let stale = Date().addingTimeInterval(-6 * 60 * 60)
        let live = answered.filter { $0.value > stale }
        if live.count != answered.count { answered = live }
        guard !sentReplies.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-replyLinger)
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
            let now = Date()
            sentReplies[thread.id, default: []].append(SentReply(text: text, date: now))
            answered[thread.id] = now
            drafts.removeValue(forKey: thread.id)
            persistDrafts()
            // Rebuilding here rather than waiting for the next poll is what
            // makes a linger of zero mean *now*, and what keeps any other
            // setting honest to within a second instead of to within a poll.
            rebuild()
            scheduleLingerExpiry()
        }
        return result
    }
}
