import Foundation

/// Everything the UI needs to know about one notification source at a point in time.
enum SourceState: Equatable {
    /// Configured but not polling yet.
    case idle
    /// Polling, no trustworthy value yet (first page load, first db read...).
    case loading
    /// A real, current unread count.
    case ok(count: Int)
    /// Logged out — the user has to sign in before we can read anything.
    case needsAuth
    /// macOS is withholding something (Full Disk Access, Accessibility...).
    case needsPermission(String)
    /// Transient failure; the message is surfaced in Settings, not on the dot.
    case failed(String)

    var count: Int? {
        if case .ok(let c) = self { return c }
        return nil
    }

    /// True when the dot should light up and demand attention.
    var isAttention: Bool { (count ?? 0) > 0 }

    /// True when the dot should render its "something is wrong" treatment.
    var isBlocked: Bool {
        switch self {
        case .needsAuth, .needsPermission: return true
        default: return false
        }
    }

    var isSettled: Bool {
        switch self {
        case .idle, .loading: return false
        default: return true
        }
    }

    /// Short human-readable line for Settings and the status menu.
    var summary: String {
        switch self {
        case .idle: return "Off"
        case .loading: return "Connecting…"
        case .ok(let c): return c == 0 ? "No unread" : (c == 1 ? "1 unread" : "\(c) unread")
        case .needsAuth: return "Sign in required"
        case .needsPermission(let what): return "Needs \(what)"
        case .failed(let why): return "Error — \(why)"
        }
    }
}

/// Static identity of a source: what it is called, how it looks, where clicking it goes.
struct SourceDescriptor: Equatable {
    let id: String
    let name: String
    let glyph: Glyph
    let accent: Accent
    /// Opened when the dot is clicked.
    let openURL: URL?
    /// Preferred over `openURL` when this app is actually installed.
    let openBundleID: String?
}

/// A value snapshot the SwiftUI layer renders. Keeping the view value-driven
/// makes diffing (and therefore the animations) behave.
struct SourceSnapshot: Identifiable, Equatable {
    let descriptor: SourceDescriptor
    let state: SourceState
    var id: String { descriptor.id }

    var displayCount: Int { state.count ?? 0 }

    /// "3", "42", "99+" — capped so the capsule never has to grow unbounded.
    var countText: String {
        let c = displayCount
        return c > 99 ? "99+" : String(c)
    }
}
