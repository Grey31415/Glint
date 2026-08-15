import AppKit
import Combine

/// The services Notifly knows how to read. Add a case here, teach
/// `SourceFactory` to build it, and it shows up in Settings automatically.
enum SourceKind: String, CaseIterable, Identifiable {
    case instagram
    case whatsapp
    case imessage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .instagram: return "Instagram"
        case .whatsapp:  return "WhatsApp"
        case .imessage:  return "iMessage"
        }
    }

    /// One line explaining how the count is obtained, shown in Settings.
    var mechanism: String {
        switch self {
        case .instagram: return "Signed-in instagram.com session, read in the background."
        case .whatsapp:  return "WhatsApp Web session, or the desktop app's Dock badge."
        case .imessage:  return "Local Messages database — needs Full Disk Access."
        }
    }
}

@MainActor
enum SourceFactory {
    static func make(_ kind: SourceKind, preferences: Preferences) -> any NotificationSource {
        switch kind {
        case .instagram:
            return WebSource(recipe: .instagram, preferences: preferences)
        case .whatsapp:
            switch preferences.whatsappMode {
            case .web:       return WebSource(recipe: .whatsapp, preferences: preferences)
            case .dockBadge: return DockBadgeSource(recipe: .whatsappDock, preferences: preferences)
            }
        case .imessage:
            return MessagesSource(preferences: preferences)
        }
    }
}

/// Owns the live sources, keeps them in sync with preferences, and republishes
/// their states as a single ordered array of value snapshots.
@MainActor
final class NotificationHub: ObservableObject {
    @Published private(set) var snapshots: [SourceSnapshot] = []
    /// Bumped whenever any count goes *up*, so the UI can fire an arrival effect.
    @Published private(set) var lastArrival: (id: String, at: Date)?

    private var sources: [String: any NotificationSource] = [:]
    private var order: [String] = []
    private var subs: [String: AnyCancellable] = [:]
    private var previousCounts: [String: Int] = [:]
    private var prefsSub: AnyCancellable?
    private let preferences: Preferences
    private var started = false

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func start() {
        guard !started else { return }
        started = true
        reconcile()
        // Preferences drive which sources exist; rebuild lazily on change.
        prefsSub = preferences.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reconcile() }
    }

    func stop() {
        sources.values.forEach { $0.stop() }
        sources.removeAll()
        subs.removeAll()
        order.removeAll()
        snapshots = []
        started = false
        prefsSub = nil
    }

    func refreshAll() {
        sources.values.forEach { $0.refresh() }
    }

    func source(for id: String) -> (any NotificationSource)? { sources[id] }

    /// Total across every enabled source — used by the status item.
    var totalUnread: Int {
        snapshots.reduce(0) { $0 + $1.displayCount }
    }

    // MARK: - Wiring

    /// Bring the live source set in line with what preferences ask for.
    private func reconcile() {
        let wanted = SourceKind.allCases.filter { preferences.isEnabled($0) }
        let wantedIDs = Set(wanted.map(\.rawValue))

        for (id, source) in sources where !wantedIDs.contains(id) {
            source.stop()
            sources[id] = nil
            subs[id] = nil
            previousCounts[id] = nil
        }

        for kind in wanted where sources[kind.rawValue] == nil {
            let source = SourceFactory.make(kind, preferences: preferences)
            sources[kind.rawValue] = source
            subs[kind.rawValue] = source.statePublisher
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.rebuildSnapshots() }
            source.start()
        }

        let ranking = preferences.sourceOrder
        order = wanted
            .map(\.rawValue)
            .sorted { a, b in
                let ia = ranking.firstIndex(of: a) ?? .max
                let ib = ranking.firstIndex(of: b) ?? .max
                return ia == ib ? a < b : ia < ib
            }

        rebuildSnapshots()
    }

    private func rebuildSnapshots() {
        let next: [SourceSnapshot] = order.compactMap { id in
            guard let source = sources[id] else { return nil }
            return SourceSnapshot(descriptor: source.descriptor, state: source.state)
        }
        guard next != snapshots else { return }

        for snap in next {
            let now = snap.displayCount
            let before = previousCounts[snap.id]
            previousCounts[snap.id] = now
            if let before, now > before {
                lastArrival = (snap.id, Date())
                if preferences.playSoundOnNew { NSSound(named: "Tink")?.play() }
            }
        }

        snapshots = next
    }
}
