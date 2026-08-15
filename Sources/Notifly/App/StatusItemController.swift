import AppKit
import Combine

/// Optional menu bar item. The dots are the real interface, but a status item
/// guarantees there is always a way to reach Settings and Quit — including on a
/// display where the overlay ends up somewhere unexpected.
@MainActor
final class StatusItemController {
    private let hub: NotificationHub
    private let preferences: Preferences
    private let onOpenSettings: () -> Void
    private let onRefresh: () -> Void

    private var item: NSStatusItem?
    private var bag = Set<AnyCancellable>()

    init(hub: NotificationHub,
         preferences: Preferences,
         onOpenSettings: @escaping () -> Void,
         onRefresh: @escaping () -> Void) {
        self.hub = hub
        self.preferences = preferences
        self.onOpenSettings = onOpenSettings
        self.onRefresh = onRefresh
    }

    func start() {
        hub.$snapshots
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &bag)

        preferences.objectWillChange
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &bag)

        sync()
    }

    func stop() {
        bag.removeAll()
        teardown()
    }

    /// True when the cluster is currently drawing nothing at all — every source
    /// off, or all of them quiet with "hide when empty" on.
    private var clusterIsEmpty: Bool {
        !hub.snapshots.contains { $0.isVisible(hideWhenEmpty: preferences.hideWhenEmpty) }
    }

    private func sync() {
        // The status item can be switched off, but not into a corner: with no
        // dots on screen and no menu bar item there would be no way left to
        // reach Settings or Quit, so it comes back until a dot does.
        guard preferences.showStatusItem || clusterIsEmpty else { return teardown() }

        let item = self.item ?? {
            let new = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            new.button?.image = NSImage(systemSymbolName: "smallcircle.filled.circle",
                                        accessibilityDescription: "Notifly")
            new.button?.imagePosition = .imageLeading
            self.item = new
            return new
        }()

        let total = hub.totalUnread
        item.button?.title = total > 0 ? " \(total)" : ""
        item.menu = buildMenu()
    }

    private func teardown() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        if hub.snapshots.isEmpty {
            let empty = NSMenuItem(title: "No sources enabled", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for snapshot in hub.snapshots {
                let entry = NSMenuItem(title: "\(snapshot.descriptor.name) — \(snapshot.menuSummary)",
                                       action: #selector(MenuTarget.openSource(_:)),
                                       keyEquivalent: "")
                entry.target = target
                entry.representedObject = snapshot.id
                menu.addItem(entry)
            }
        }

        let unread = hub.snapshots.filter { $0.displayCount > 0 }
        if !unread.isEmpty {
            menu.addItem(.separator())
            for snapshot in unread {
                let entry = NSMenuItem(title: "Mark \(snapshot.descriptor.name) as Read",
                                       action: #selector(MenuTarget.markRead(_:)),
                                       keyEquivalent: "")
                entry.target = target
                entry.representedObject = snapshot.id
                menu.addItem(entry)
            }
            menu.addItem(withTargetedTitle: "Mark All as Read",
                         action: #selector(MenuTarget.markAllRead),
                         target: target)
        }
        if hub.totalSuppressed > 0 {
            menu.addItem(withTargetedTitle: "Undo Mark as Read (\(hub.totalSuppressed) hidden)",
                         action: #selector(MenuTarget.undoMarkRead),
                         target: target)
        }

        menu.addItem(.separator())
        menu.addItem(withTargetedTitle: "Refresh Now",
                     action: #selector(MenuTarget.refresh),
                     target: target)
        menu.addItem(withTargetedTitle: "Settings…",
                     action: #selector(MenuTarget.openSettings),
                     target: target,
                     keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTargetedTitle: "Quit Notifly",
                     action: #selector(MenuTarget.quit),
                     target: target,
                     keyEquivalent: "q")
        return menu
    }

    /// `NSMenuItem` needs an `@objc` target; keeping it in a tiny helper avoids
    /// dragging Objective-C requirements into the controller itself.
    private lazy var target: MenuTarget = {
        MenuTarget(openSource: { [weak self] id in
                       guard let source = self?.hub.source(for: id) else { return }
                       if let remedy = source.remedy { remedy.perform() } else { source.activate() }
                   },
                   markRead: { [weak self] id in self?.hub.markRead(id) },
                   markAllRead: { [weak self] in self?.hub.markAllRead() },
                   undoMarkRead: { [weak self] in self?.hub.clearReadMarks() },
                   refresh: { [weak self] in self?.onRefresh() },
                   openSettings: { [weak self] in self?.onOpenSettings() })
    }()
}

private final class MenuTarget: NSObject {
    private let openSourceHandler: @MainActor (String) -> Void
    private let markReadHandler: @MainActor (String) -> Void
    private let markAllReadHandler: @MainActor () -> Void
    private let undoMarkReadHandler: @MainActor () -> Void
    private let refreshHandler: @MainActor () -> Void
    private let openSettingsHandler: @MainActor () -> Void

    init(openSource: @escaping @MainActor (String) -> Void,
         markRead: @escaping @MainActor (String) -> Void,
         markAllRead: @escaping @MainActor () -> Void,
         undoMarkRead: @escaping @MainActor () -> Void,
         refresh: @escaping @MainActor () -> Void,
         openSettings: @escaping @MainActor () -> Void) {
        self.openSourceHandler = openSource
        self.markReadHandler = markRead
        self.markAllReadHandler = markAllRead
        self.undoMarkReadHandler = undoMarkRead
        self.refreshHandler = refresh
        self.openSettingsHandler = openSettings
    }

    @objc func openSource(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        MainActor.assumeIsolated { openSourceHandler(id) }
    }

    @objc func markRead(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        MainActor.assumeIsolated { markReadHandler(id) }
    }

    @objc func markAllRead() { MainActor.assumeIsolated { markAllReadHandler() } }
    @objc func undoMarkRead() { MainActor.assumeIsolated { undoMarkReadHandler() } }
    @objc func refresh() { MainActor.assumeIsolated { refreshHandler() } }
    @objc func openSettings() { MainActor.assumeIsolated { openSettingsHandler() } }
    @objc func quit() { NSApp.terminate(nil) }
}

private extension NSMenu {
    func addItem(withTargetedTitle title: String,
                 action: Selector,
                 target: AnyObject,
                 keyEquivalent: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        addItem(item)
    }
}
