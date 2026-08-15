import AppKit
import SQLite3

/// Unread iMessage/SMS count, read straight from the local Messages database.
///
/// Requires Full Disk Access — that is macOS protecting `~/Library/Messages`,
/// not something the app can work around, so the dot reports it as a fixable
/// state rather than as an error.
@MainActor
final class MessagesSource: BaseSource, NotificationSource {
    private let preferences: Preferences
    private var timer: Timer?
    private var running = false
    private var inFlight = false

    @Published private(set) var diagnostics: String = "Not started"
    private(set) var unreadChats: Int = 0

    private let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages/chat.db")

    init(preferences: Preferences) {
        self.preferences = preferences
        super.init()
    }

    let descriptor = SourceDescriptor(
        id: SourceKind.imessage.rawValue,
        name: "iMessage",
        glyph: .symbol("message.fill"),
        accent: .imessage,
        openURL: URL(string: "imessage://"),
        openBundleID: "com.apple.MobileSMS")

    var state: SourceState { currentState }

    var remedy: SourceRemedy? {
        guard case .needsPermission = currentState else { return nil }
        return SourceRemedy(title: "Open Full Disk Access settings") {
            PrivacySettings.open(.fullDiskAccess)
        }
    }

    func start() {
        guard !running else { return }
        running = true
        set(.loading)
        poll()
        let timer = Timer(timeInterval: max(preferences.pollInterval, 3), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        set(.idle)
    }

    func refresh() { poll() }

    private func poll() {
        guard running, !inFlight else { return }
        inFlight = true

        let url = databaseURL
        // Messages stores timestamps against a 2001-01-01 epoch.
        let lookback = preferences.messagesLookbackDays * 86_400
        let cutoff = Int64(Date().timeIntervalSince1970 - lookback - 978_307_200)

        Task.detached(priority: .utility) {
            let result = MessagesReader.read(at: url, sinceAppleSeconds: cutoff)
            await MainActor.run { self.apply(result) }
        }
    }

    private func apply(_ result: MessagesReadResult) {
        inFlight = false
        switch result {
        case .ok(let messages, let chats):
            unreadChats = chats
            set(.ok(count: messages))
            diagnostics = chats > 0
                ? "\(messages) unread in \(chats) conversation\(chats == 1 ? "" : "s")"
                : "No unread messages"
        case .noPermission:
            set(.needsPermission("Full Disk Access"))
            diagnostics = "Can't read ~/Library/Messages/chat.db"
        case .missing:
            set(.failed("No Messages database"))
            diagnostics = "chat.db not found — has Messages ever been used?"
        case .error(let message):
            set(.failed(message))
            diagnostics = "SQLite: \(message)"
        }
    }
}

enum MessagesReadResult: Sendable {
    case ok(messages: Int, chats: Int)
    case noPermission
    case missing
    case error(String)
}

/// Off-main SQLite reader. Deliberately read-only: Notifly never writes to the
/// Messages database.
enum MessagesReader {
    /// Counts unread inbound messages newer than `sinceAppleSeconds`.
    ///
    /// The date column switched from seconds to nanoseconds years ago; the CASE
    /// handles a database that predates that.
    private static let query = """
    SELECT COUNT(*), COUNT(DISTINCT cmj.chat_id)
    FROM message AS m
    LEFT JOIN chat_message_join AS cmj ON cmj.message_id = m.ROWID
    WHERE m.is_from_me = 0
      AND m.is_read = 0
      AND m.item_type = 0
      AND (CASE WHEN m.date > 1000000000000 THEN m.date / 1000000000 ELSE m.date END) > ?
    """

    static func read(at url: URL, sinceAppleSeconds cutoff: Int64) -> MessagesReadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            // Without Full Disk Access the whole directory is invisible, which
            // looks exactly like the file being absent. Permission is by far
            // the likelier explanation on a Mac that has Messages installed.
            return fm.fileExists(atPath: url.deletingLastPathComponent().path) ? .missing : .noPermission
        }
        guard fm.isReadableFile(atPath: url.path) else { return .noPermission }

        // First choice: a normal read-only open, which honours the write-ahead
        // log and therefore sees messages that arrived seconds ago.
        if let db = open(url: url, immutable: false) {
            defer { sqlite3_close(db) }
            return run(db, cutoff: cutoff)
        }
        // Fallback for setups where the WAL index cannot be attached read-only.
        // `immutable` skips the WAL, so the count can lag by a few minutes.
        if let db = open(url: url, immutable: true) {
            defer { sqlite3_close(db) }
            return run(db, cutoff: cutoff)
        }
        return .noPermission
    }

    private static func open(url: URL, immutable: Bool) -> OpaquePointer? {
        let encoded = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        let uri = "file://\(encoded)?mode=ro" + (immutable ? "&immutable=1" : "")
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        return db
    }

    private static func run(_ db: OpaquePointer, cutoff: Int64) -> MessagesReadResult {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            return .error(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, cutoff)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return .ok(messages: Int(sqlite3_column_int(statement, 0)),
                       chats: Int(sqlite3_column_int(statement, 1)))
        case SQLITE_DONE:
            return .ok(messages: 0, chats: 0)
        default:
            let message = String(cString: sqlite3_errmsg(db))
            return message.localizedCaseInsensitiveContains("authorization")
                ? .noPermission
                : .error(message)
        }
    }
}

/// Deep links into the Privacy & Security panes.
enum PrivacySettings {
    enum Pane: String {
        case fullDiskAccess = "Privacy_AllFiles"
        case accessibility = "Privacy_Accessibility"
    }

    static func open(_ pane: Pane) {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane.rawValue)",
            "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }
}
