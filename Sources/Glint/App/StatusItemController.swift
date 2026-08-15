import AppKit
import Combine

/// Optional menu bar item. The dot is the real interface, but a status item
/// guarantees there is always a way to reach Settings and Quit — which matters
/// most in hidden mode, where the dot is invisible by design.
@MainActor
final class StatusItemController {
    private let model: GlintModel
    private let preferences: Preferences
    private let onOpenSettings: () -> Void

    private var item: NSStatusItem?
    private var bag = Set<AnyCancellable>()

    init(model: GlintModel, preferences: Preferences, onOpenSettings: @escaping () -> Void) {
        self.model = model
        self.preferences = preferences
        self.onOpenSettings = onOpenSettings
    }

    func start() {
        model.$summaries
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

    /// True when nothing is drawn beside the notch — hidden mode, or the dot
    /// suppressed while empty.
    private var dotIsInvisible: Bool {
        if preferences.hiddenMode { return true }
        return preferences.hideWhenEmpty && model.total == 0
    }

    private func sync() {
        // The status item can be switched off, but not into a corner: with no
        // dot on screen and no menu bar item there would be no way left to
        // reach Settings or Quit.
        guard preferences.showStatusItem || dotIsInvisible else { return teardown() }

        let item = self.item ?? {
            let new = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            new.button?.image = NSImage(systemSymbolName: "smallcircle.filled.circle",
                                        accessibilityDescription: "Glint")
            new.button?.imagePosition = .imageLeading
            self.item = new
            return new
        }()

        item.button?.title = model.total > 0 ? " \(model.total)" : ""
        item.menu = buildMenu()
    }

    private func teardown() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let status = NSMenuItem(title: "Instagram — \(model.state.summary)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let waiting = model.summaries.filter { $0.count > 0 }
        if waiting.isEmpty {
            let none = NSMenuItem(title: "Nothing waiting", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for summary in waiting {
                let entry = NSMenuItem(title: "\(summary.count) \(summary.kind.title.lowercased())",
                                       action: #selector(MenuTarget.openKind(_:)),
                                       keyEquivalent: "")
                entry.target = target
                entry.representedObject = summary.kind.rawValue
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            menu.addItem(targeted("Mark All as Read", #selector(MenuTarget.markAllRead)))
        }
        if model.totalSuppressed > 0 {
            menu.addItem(targeted("Undo Mark as Read (\(model.totalSuppressed) hidden)",
                                  #selector(MenuTarget.undoMarkRead)))
        }

        menu.addItem(.separator())
        menu.addItem(targeted("Open Instagram", #selector(MenuTarget.openInbox)))
        menu.addItem(targeted("Refresh Now", #selector(MenuTarget.refresh)))
        menu.addItem(targeted("Settings…", #selector(MenuTarget.openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(targeted("Quit Glint", #selector(MenuTarget.quit), key: "q"))
        return menu
    }

    private func targeted(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    private lazy var target: MenuTarget = {
        MenuTarget(openKind: { [weak self] raw in
                       guard let kind = ActivityKind(rawValue: raw) else { return }
                       self?.model.open(kind)
                   },
                   markAllRead: { [weak self] in self?.model.markAllRead() },
                   undoMarkRead: { [weak self] in self?.model.clearReadMarks() },
                   openInbox: { [weak self] in self?.model.openInbox() },
                   refresh: { [weak self] in self?.model.refresh() },
                   openSettings: { [weak self] in self?.onOpenSettings() })
    }()
}

private final class MenuTarget: NSObject {
    private let openKindHandler: @MainActor (String) -> Void
    private let markAllReadHandler: @MainActor () -> Void
    private let undoMarkReadHandler: @MainActor () -> Void
    private let openInboxHandler: @MainActor () -> Void
    private let refreshHandler: @MainActor () -> Void
    private let openSettingsHandler: @MainActor () -> Void

    init(openKind: @escaping @MainActor (String) -> Void,
         markAllRead: @escaping @MainActor () -> Void,
         undoMarkRead: @escaping @MainActor () -> Void,
         openInbox: @escaping @MainActor () -> Void,
         refresh: @escaping @MainActor () -> Void,
         openSettings: @escaping @MainActor () -> Void) {
        self.openKindHandler = openKind
        self.markAllReadHandler = markAllRead
        self.undoMarkReadHandler = undoMarkRead
        self.openInboxHandler = openInbox
        self.refreshHandler = refresh
        self.openSettingsHandler = openSettings
    }

    @objc func openKind(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        MainActor.assumeIsolated { openKindHandler(raw) }
    }

    @objc func markAllRead() { MainActor.assumeIsolated { markAllReadHandler() } }
    @objc func undoMarkRead() { MainActor.assumeIsolated { undoMarkReadHandler() } }
    @objc func openInbox() { MainActor.assumeIsolated { openInboxHandler() } }
    @objc func refresh() { MainActor.assumeIsolated { refreshHandler() } }
    @objc func openSettings() { MainActor.assumeIsolated { openSettingsHandler() } }
    @objc func quit() { NSApp.terminate(nil) }
}
