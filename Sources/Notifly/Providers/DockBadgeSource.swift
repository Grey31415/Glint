import AppKit
import ApplicationServices

/// Which Dock tile to read, and how to present it.
struct DockRecipe {
    let descriptor: SourceDescriptor
    /// Dock tiles are titled with the app's localised name, so match a list.
    let tileTitles: [String]
}

extension DockRecipe {
    static let whatsappDock = DockRecipe(
        descriptor: SourceDescriptor(
            id: SourceKind.whatsapp.rawValue,
            name: "WhatsApp",
            glyph: .whatsapp,
            accent: .whatsapp,
            openURL: URL(string: "https://web.whatsapp.com/"),
            // Reads the desktop app's badge, but still opens the browser on
            // click, to match the web-backed mode.
            openBundleID: nil),
        tileTitles: ["WhatsApp"])
}

/// Reads the red badge off an app's Dock tile via the accessibility API.
///
/// Generic on purpose: any app that badges its Dock icon — Mail, Slack, Discord,
/// Telegram — can be added with nothing but a new `DockRecipe`. The trade-off is
/// that the app has to be running and kept in the Dock.
@MainActor
final class DockBadgeSource: BaseSource, NotificationSource {
    let recipe: DockRecipe
    private let preferences: Preferences
    private var timer: Timer?
    private var running = false

    @Published private(set) var diagnostics: String = "Not started"

    init(recipe: DockRecipe, preferences: Preferences) {
        self.recipe = recipe
        self.preferences = preferences
        super.init()
    }

    var descriptor: SourceDescriptor { recipe.descriptor }
    var state: SourceState { currentState }

    var remedy: SourceRemedy? {
        guard case .needsPermission = currentState else { return nil }
        return SourceRemedy(title: "Open Accessibility settings") {
            DockBadgeReader.promptForTrust()
            PrivacySettings.open(.accessibility)
        }
    }

    func start() {
        guard !running else { return }
        running = true
        set(.loading)
        poll()
        let timer = Timer(timeInterval: max(preferences.pollInterval, 2), repeats: true) { [weak self] _ in
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
        guard running else { return }
        guard DockBadgeReader.isTrusted else {
            set(.needsPermission("Accessibility"))
            diagnostics = "Notifly needs Accessibility access to read Dock badges"
            return
        }
        switch DockBadgeReader.badge(matchingTitles: recipe.tileTitles) {
        case .some(let count):
            set(.ok(count: count))
            diagnostics = "Dock badge: \(count)"
        case .none:
            set(.failed("\(descriptor.name) isn't in the Dock"))
            diagnostics = "No Dock tile titled \(recipe.tileTitles.joined(separator: " / "))"
        }
    }
}

enum DockBadgeReader {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Returns the badge number (0 when the tile has no badge), or nil when no
    /// matching tile is in the Dock at all.
    static func badge(matchingTitles titles: [String]) -> Int? {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }

        let app = AXUIElementCreateApplication(dock.processIdentifier)
        guard let lists = value(of: app, kAXChildrenAttribute) as? [AXUIElement] else { return nil }

        for list in lists {
            guard let role = value(of: list, kAXRoleAttribute) as? String,
                  role == kAXListRole as String,
                  let tiles = value(of: list, kAXChildrenAttribute) as? [AXUIElement] else { continue }

            for tile in tiles {
                guard let title = value(of: tile, kAXTitleAttribute) as? String,
                      titles.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame })
                else { continue }

                // No status label means the tile is present but unbadged.
                guard let label = value(of: tile, "AXStatusLabel") as? String else { return 0 }
                return Int(label.filter(\.isNumber)) ?? 0
            }
        }
        return nil
    }

    private static func value(of element: AXUIElement, _ attribute: String) -> Any? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else {
            return nil
        }
        return result
    }
}
