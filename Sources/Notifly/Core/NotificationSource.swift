import AppKit
import Combine

/// A thing that can tell Notifly how many unread messages are waiting.
///
/// Adding a new service means writing one conformance and registering it in
/// `SourceKind` / `SourceFactory` — nothing in the UI or window layer changes.
@MainActor
protocol NotificationSource: AnyObject {
    var descriptor: SourceDescriptor { get }
    var state: SourceState { get }
    /// Emits on every state change, including the initial value.
    var statePublisher: AnyPublisher<SourceState, Never> { get }

    /// Begin polling. Must be safe to call twice.
    func start()
    /// Stop polling and release resources.
    func stop()
    /// Force an out-of-band poll (menu "Refresh Now").
    func refresh()

    /// Invoked when the user clicks the dot. Default opens the descriptor target.
    func activate()

    /// Non-nil when the source is blocked on something the user can fix,
    /// e.g. "Sign in to Instagram" or "Open Privacy Settings".
    var remedy: SourceRemedy? { get }

    /// One line for the Settings window explaining what the source last saw —
    /// including *how* it found the number, which is what makes a silently
    /// broken scraper distinguishable from a genuinely quiet inbox.
    var diagnostics: String { get }
}

struct SourceRemedy {
    let title: String
    let perform: @MainActor () -> Void
}

extension NotificationSource {
    var id: String { descriptor.id }

    func activate() {
        if let bundleID = descriptor.openBundleID,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            return
        }
        if let url = descriptor.openURL {
            NSWorkspace.shared.open(url)
        }
    }

    var remedy: SourceRemedy? { nil }

    var diagnostics: String { state.summary }
}

/// Small helper the concrete sources share: owns the `@Published` state and
/// exposes it as the protocol's publisher.
@MainActor
class BaseSource {
    @Published private(set) var currentState: SourceState = .idle

    var statePublisher: AnyPublisher<SourceState, Never> {
        $currentState.eraseToAnyPublisher()
    }

    func set(_ new: SourceState) {
        guard new != currentState else { return }
        currentState = new
    }
}
