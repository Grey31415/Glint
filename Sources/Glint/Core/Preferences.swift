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

/// What every tunable starts at.
///
/// Stated once, so the getter that supplies a missing value and the reset button
/// that offers to restore it cannot disagree about what the default is.
enum Defaults {
    static let dotSize = 15.0
    static let horizontalOffset = 10.0
    static let hoverSensitivity = 22.0
    static let dotGlassiness = 0.0
    static let pollInterval = 15.0
    static let webReloadMinutes = 20.0
    static let quietTint = 0x8A90A2
    static let alertSound = "Tink"
}

/// The alert sounds this Mac actually has.
///
/// A directory listing rather than a list typed out here, because the set is not
/// fixed: a machine can carry its own in `~/Library/Sounds`, and a name that has
/// been typed out but is missing plays nothing at all, silently.
enum AlertSounds {
    static let names: [String] = {
        let folders = ["/System/Library/Sounds",
                       NSHomeDirectory() + "/Library/Sounds"]
        var found = Set<String>()
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for file in files {
                let name = (file as NSString).deletingPathExtension
                if NSSound(named: name) != nil { found.insert(name) }
            }
        }
        // Never hand back an empty menu: the default has to be selectable even
        // on a system where the folder cannot be read.
        return found.isEmpty ? [Defaults.alertSound] : found.sorted()
    }()
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
        get { value("horizontalOffset", Defaults.horizontalOffset) }
        set { store("horizontalOffset", newValue) }
    }

    /// Park the dot inside the notch - a region of the display with no pixels -
    /// so it is genuinely invisible until the cursor arrives there.
    var hiddenMode: Bool {
        get { value("hiddenMode", false) }
        set { store("hiddenMode", newValue) }
    }

    // MARK: - Look

    var dotSize: Double {
        get { value("dotSize", Defaults.dotSize) }
        set { store("dotSize", min(max(newValue, 8), 22)) }
    }

    /// How much of the resting dot is glass rather than paint, as a percentage.
    ///
    /// At 0 the dot is its colour, opaque, which is what it has always been. At
    /// 100 it is the same shape in glass: the notch shows through it and only
    /// the rim and a wash of the colour are left. Stored as a percentage because
    /// that is what the slider says.
    var dotGlassiness: Double {
        get { value("dotGlassiness", Defaults.dotGlassiness) }
        set { store("dotGlassiness", min(max(newValue, 0), 100)) }
    }

    /// The app's accent, or nil while it is still Instagram's own gradient.
    ///
    /// A sentinel rather than an absent key, so "put it back" is a value the
    /// picker can write like any other. Static because `Accent.current` is read
    /// from a dozen views that have no other reason to hold a `Preferences`,
    /// which is the bargain `animationsEnabled` already makes.
    static let accentKey = "accentTint"

    static var customAccent: Color? {
        guard let stored = UserDefaults.standard.object(forKey: accentKey) as? Int,
              stored >= 0 else { return nil }
        return Color(rgb: stored)
    }

    /// What the picker shows: the chosen colour, or the gradient's own pink
    /// standing in for "not chosen".
    var accentTint: Color {
        get { Self.customAccent ?? Accent.instagram.glow }
        set { store(Self.accentKey, newValue.rgb) }
    }

    var hasCustomAccent: Bool { Self.customAccent != nil }

    /// Back to the gradient. Not the same as picking its pink by hand: five
    /// colours drift inside a lit dot, and one of them is not five.
    func resetAccent() { store(Self.accentKey, -1) }

    /// The colour of a dot with nothing waiting on it.
    ///
    /// Only the quiet state is yours to choose. A dot that is actually waiting
    /// on you keeps Instagram's own gradient, because that is the thing it is
    /// telling you about - the colour is information, not decoration.
    var quietTint: Color {
        get { Color(rgb: value("quietTint", Defaults.quietTint)) }
        set { store("quietTint", newValue.rgb) }
    }

    /// How close the cursor must come to the dot before the menu unfolds,
    /// in points.
    ///
    /// This replaced two sliders - maximum magnification and cursor influence -
    /// that the morph made redundant: the dot is only briefly visible at rest
    /// before it becomes the menu, so tuning how much it grew first had almost
    /// no observable effect. Magnification is now a fixed, subtle constant.
    var hoverSensitivity: Double {
        get { value("hoverSensitivity", Defaults.hoverSensitivity) }
        set { store("hoverSensitivity", min(max(newValue, 0), 90)) }
    }

    var showCountAtRest: Bool {
        get { value("showCountAtRest", true) }
        set { store("showCountAtRest", newValue) }
    }

    /// Read by `Motion` without an instance, so a static is the simplest thing
    /// that works. Same key and same default as `animations`.
    static let animationsKey = "animations"

    static var animationsEnabled: Bool {
        UserDefaults.standard.object(forKey: animationsKey) as? Bool ?? true
    }

    /// Every animation in the app. Off means state changes land instantly and
    /// the colour inside the dot stops drifting.
    var animations: Bool {
        get { Self.animationsEnabled }
        set { store(Self.animationsKey, newValue) }
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

    /// Let the dot's colour spread into the open menu as a bloom.
    ///
    /// Off does not drain the dot: the same fill is what makes a dot a dot. It
    /// stops the colour growing into the glass, so the menu is plain glass with
    /// the colour leaving alongside the dot it belongs to.
    var menuGlow: Bool {
        get { value("menuGlow", true) }
        set { store("menuGlow", newValue) }
    }

    /// Whether the system-wide shortcut is claimed.
    ///
    /// On by default. The dot is a 9pt target that only answers to hover, so
    /// without this there is no way to reach the menu at all except by finding
    /// it with the pointer.
    var hotkeyEnabled: Bool {
        get { value("hotkeyEnabled", true) }
        set { store("hotkeyEnabled", newValue) }
    }

    /// Leave muted conversations out of the count entirely.
    ///
    /// Muting a thread on Instagram is already the answer to "do not interrupt
    /// me about this". Counting it anyway makes the dot argue with a decision
    /// the user has made.
    var ignoreMuted: Bool {
        get { value("ignoreMuted", true) }
        set { store("ignoreMuted", newValue) }
    }

    /// Leave group chats out of the count.
    ///
    /// Off by default: a group message is still somebody writing to you. It is
    /// here because for some people a busy group is the only thing that ever
    /// lights the dot, which makes the dot useless.
    var ignoreGroups: Bool {
        get { value("ignoreGroups", false) }
        set { store("ignoreGroups", newValue) }
    }

    /// A way into the inbox from the menu, for when nothing in the list is what
    /// you were after.
    var showInboxButton: Bool {
        get { value("showInboxButton", true) }
        set { store("showInboxButton", newValue) }
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

    /// Which of the system's alert sounds an arrival makes.
    ///
    /// Static as well, for the same reason as `animationsEnabled`: the sound is
    /// played from a static, so that the arrival and the Test button in Settings
    /// cannot end up playing different things.
    static let alertSoundKey = "alertSound"

    static var alertSoundName: String {
        UserDefaults.standard.string(forKey: alertSoundKey) ?? Defaults.alertSound
    }

    var alertSound: String {
        get { Self.alertSoundName }
        set { store(Self.alertSoundKey, newValue) }
    }

    // MARK: - Polling

    var pollInterval: Double {
        get { value("pollInterval", Defaults.pollInterval) }
        set { store("pollInterval", min(max(newValue, 5), 300)) }
    }

    var webReloadMinutes: Double {
        get { value("webReloadMinutes", Defaults.webReloadMinutes) }
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
                NSLog("[Glint] login item toggle failed: \(error.localizedDescription)")
            }
        }
    }
}
