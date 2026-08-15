import Foundation
import Combine
import ServiceManagement
import SwiftUI

/// Where the cluster docks relative to the notch.
enum DockSide: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var label: String { self == .left ? "Left of notch" : "Right of notch" }
}

/// How WhatsApp counts are obtained.
enum WhatsAppMode: String, CaseIterable, Identifiable {
    case web        // hidden WhatsApp Web session
    case dockBadge  // read the badge off the desktop app's Dock tile
    var id: String { rawValue }
    var label: String { self == .web ? "WhatsApp Web (no app needed)" : "Desktop app Dock badge" }
}

/// UserDefaults-backed settings. Intentionally *not* actor-isolated: it is only
/// ever touched from the main thread, and staying non-isolated lets SwiftUI
/// `Binding`s read and write it without ceremony.
final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Two-way binding for any settable property, so Settings controls can be
    /// written as `Toggle("…", isOn: prefs.binding(\.showCountAtRest))`.
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

    // MARK: - Which sources are live

    var enabledSourceIDs: Set<String> {
        get {
            let raw = defaults.array(forKey: "enabledSources") as? [String]
            return Set(raw ?? [SourceKind.instagram.rawValue])
        }
        set { store("enabledSources", Array(newValue).sorted()) }
    }

    func isEnabled(_ kind: SourceKind) -> Bool { enabledSourceIDs.contains(kind.rawValue) }

    func setEnabled(_ kind: SourceKind, _ on: Bool) {
        var set = enabledSourceIDs
        if on { set.insert(kind.rawValue) } else { set.remove(kind.rawValue) }
        enabledSourceIDs = set
    }

    /// Display order of the dots, left to right. Unknown ids fall to the end.
    var sourceOrder: [String] {
        get { defaults.array(forKey: "sourceOrder") as? [String] ?? SourceKind.allCases.map(\.rawValue) }
        set { store("sourceOrder", newValue) }
    }

    // MARK: - Placement

    var side: DockSide {
        get { DockSide(rawValue: value("side", DockSide.left.rawValue)) ?? .left }
        set { store("side", newValue.rawValue) }
    }

    /// Nudge along the menu bar. Positive moves away from the notch.
    var horizontalOffset: Double {
        get { value("horizontalOffset", 8.0) }
        set { store("horizontalOffset", newValue) }
    }

    // MARK: - Look & feel

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

    var spacing: Double {
        get { value("spacing", 8.0) }
        set { store("spacing", min(max(newValue, 0), 32)) }
    }

    /// Show the numeral inside the dot even when the mouse is elsewhere.
    var showCountAtRest: Bool {
        get { value("showCountAtRest", true) }
        set { store("showCountAtRest", newValue) }
    }

    /// Slow opacity drift on dots with nothing to report. Costs a little battery.
    var ambientBreathing: Bool {
        get { value("ambientBreathing", false) }
        set { store("ambientBreathing", newValue) }
    }

    /// Hide dots entirely while their count is zero.
    var hideWhenEmpty: Bool {
        get { value("hideWhenEmpty", false) }
        set { store("hideWhenEmpty", newValue) }
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

    /// Seconds between Swift-driven polls of each source.
    var pollInterval: Double {
        get { value("pollInterval", 5.0) }
        set { store("pollInterval", min(max(newValue, 2), 120)) }
    }

    /// Minutes between full reloads of the hidden web sessions.
    var webReloadMinutes: Double {
        get { value("webReloadMinutes", 12.0) }
        set { store("webReloadMinutes", min(max(newValue, 2), 120)) }
    }

    // MARK: - Per-source knobs

    /// Ignore unread iMessages older than this, so a forgotten thread from 2019
    /// does not permanently pin the badge.
    var messagesLookbackDays: Double {
        get { value("messagesLookbackDays", 30.0) }
        set { store("messagesLookbackDays", min(max(newValue, 1), 3650)) }
    }

    var whatsappMode: WhatsAppMode {
        get { WhatsAppMode(rawValue: value("whatsappMode", WhatsAppMode.web.rawValue)) ?? .web }
        set { store("whatsappMode", newValue.rawValue) }
    }

    /// Optional user-supplied JS body that overrides the built-in extractor.
    /// Must be a function expression returning `{status, count, method}`.
    func customExtractor(for kind: SourceKind) -> String? {
        let s = defaults.string(forKey: "customExtractor.\(kind.rawValue)")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }

    func setCustomExtractor(_ js: String?, for kind: SourceKind) {
        store("customExtractor.\(kind.rawValue)", js ?? "")
    }

    // MARK: - Mark-as-read watermarks

    /// Per-source "I have seen these" watermark, keyed by source id.
    ///
    /// Written by the hub, which rebuilds its own snapshots straight afterwards,
    /// so this deliberately skips `objectWillChange` — publishing here would
    /// make every clamp tear down and rebuild the whole source set.
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
