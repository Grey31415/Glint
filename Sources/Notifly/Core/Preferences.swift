import Foundation
import Combine
import ServiceManagement
import SwiftUI

/// Where the dot docks relative to the notch.
enum DockSide: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var label: String { self == .left ? "Left of notch" : "Right of notch" }
}

/// UserDefaults-backed settings. Intentionally *not* actor-isolated: it is only
/// ever touched from the main thread, and staying non-isolated lets SwiftUI
/// `Binding`s read and write it without ceremony.
final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Two-way binding for any settable property, so Settings controls can be
    /// written as `Toggle("…", isOn: prefs.binding(\.hiddenMode))`.
    func binding<T>(_ keyPath: ReferenceWritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { self[keyPath: keyPath] },
                set: { self[keyPath: keyPath] = $0 })
    }

    private func value<T>(_ key: String, _ fallback: T) -> T {
        defaults.object(forKey: key) as? T ?? fallback
    }

    private func store<T>(_ key: String, _ newValue: T) {
        objectWillChange.send()
        defaults.set(newValue, forKey: key)
    }

    // MARK: - What counts

    /// Which buckets are counted into the dot and shown in the card.
    var enabledKinds: Set<ActivityKind> {
        get {
            guard let raw = defaults.array(forKey: "enabledKinds") as? [String] else {
                return Set(ActivityKind.allCases.filter(\.defaultEnabled))
            }
            return Set(raw.compactMap(ActivityKind.init(rawValue:)))
        }
        set { store("enabledKinds", newValue.map(\.rawValue).sorted()) }
    }

    func isEnabled(_ kind: ActivityKind) -> Bool { enabledKinds.contains(kind) }

    func setEnabled(_ kind: ActivityKind, _ on: Bool) {
        var set = enabledKinds
        if on { set.insert(kind) } else { set.remove(kind) }
        enabledKinds = set
    }

    // MARK: - Placement

    var side: DockSide {
        get { DockSide(rawValue: value("side", DockSide.left.rawValue)) ?? .left }
        set { store("side", newValue.rawValue) }
    }

    /// Nudge along the menu bar. Positive moves away from the notch.
    var horizontalOffset: Double {
        get { value("horizontalOffset", 10.0) }
        set { store("horizontalOffset", newValue) }
    }

    /// Park the dot inside the notch — a region of the display with no pixels —
    /// so it is genuinely invisible until the cursor arrives there.
    var hiddenMode: Bool {
        get { value("hiddenMode", false) }
        set { store("hiddenMode", newValue) }
    }

    // MARK: - Look

    var dotSize: Double {
        get { value("dotSize", 15.0) }
        set { store("dotSize", min(max(newValue, 8), 22)) }
    }

    var maxScale: Double {
        get { value("maxScale", 2.1) }
        set { store("maxScale", min(max(newValue, 1.0), 3.0)) }
    }

    var influenceRadius: Double {
        get { value("influenceRadius", 84.0) }
        set { store("influenceRadius", min(max(newValue, 20), 240)) }
    }

    var showCountAtRest: Bool {
        get { value("showCountAtRest", true) }
        set { store("showCountAtRest", newValue) }
    }

    var ambientBreathing: Bool {
        get { value("ambientBreathing", false) }
        set { store("ambientBreathing", newValue) }
    }

    /// Hide the dot entirely while nothing is waiting.
    var hideWhenEmpty: Bool {
        get { value("hideWhenEmpty", false) }
        set { store("hideWhenEmpty", newValue) }
    }

    /// Show the detail card on hover. Off means the dot is just a number.
    var showHoverCard: Bool {
        get { value("showHoverCard", true) }
        set { store("showHoverCard", newValue) }
    }

    /// Include the last message text in the card, not just who wrote.
    var showMessagePreviews: Bool {
        get { value("showMessagePreviews", true) }
        set { store("showMessagePreviews", newValue) }
    }

    var playSoundOnNew: Bool {
        get { value("playSoundOnNew", false) }
        set { store("playSoundOnNew", newValue) }
    }

    var showStatusItem: Bool {
        get { value("showStatusItem", true) }
        set { store("showStatusItem", newValue) }
    }

    // MARK: - Polling

    var pollInterval: Double {
        get { value("pollInterval", 15.0) }
        set { store("pollInterval", min(max(newValue, 5), 300)) }
    }

    var webReloadMinutes: Double {
        get { value("webReloadMinutes", 20.0) }
        set { store("webReloadMinutes", min(max(newValue, 2), 120)) }
    }

    // MARK: - Mark-as-read watermarks

    /// Per-bucket "I have seen these" watermark, keyed by `ActivityKind`.
    ///
    /// Written by the model, which rebuilds straight afterwards, so this
    /// deliberately skips `objectWillChange`.
    var readBaselines: [String: Int] {
        get { defaults.dictionary(forKey: "readBaselines") as? [String: Int] ?? [:] }
        set { defaults.set(newValue, forKey: "readBaselines") }
    }

    // MARK: - Login item

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                } else {
                    if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                }
            } catch {
                NSLog("[Notifly] login item toggle failed: \(error.localizedDescription)")
            }
        }
    }
}
