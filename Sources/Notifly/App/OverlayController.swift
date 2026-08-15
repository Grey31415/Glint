import AppKit
import Combine
import SwiftUI

/// Static-per-frame layout facts the cluster view needs. Kept in one value so a
/// single `@Published` change re-lays the whole overlay coherently.
struct OverlayLayout: Equatable {
    var panelSize: CGSize = .zero
    var menuBarHeight: CGFloat = 24
    var dotSize: CGFloat = 15
    var topPadding: CGFloat = 4
    var side: DockSide = .left
    /// x, in panel-local coordinates, of the edge the cluster docks against.
    var anchorX: CGFloat = 0
}

/// Owns the floating panel: positions it beside the notch, runs the same
/// magnification layout the view renders so hit-testing can never disagree with
/// what is on screen, and flips click-through on and off accordingly.
@MainActor
final class OverlayController: ObservableObject {
    @Published private(set) var placements: [MagnifiedPlacement] = []
    @Published private(set) var layout = OverlayLayout()

    let hub: NotificationHub
    let preferences: Preferences
    let tracker = MouseTracker()

    /// Wired up by the app delegate so the right-click menu can reach it
    /// without the view layer knowing about the delegate.
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    /// Slack around the cluster so the outer glow is never clipped by the panel.
    private let edgeMargin: CGFloat = 16

    private var panel: OverlayPanel?
    private var bag = Set<AnyCancellable>()
    private var restPlacements: [MagnifiedPlacement] = []

    init(hub: NotificationHub, preferences: Preferences) {
        self.hub = hub
        self.preferences = preferences
    }

    // MARK: - Lifecycle

    func start() {
        buildPanelIfNeeded()
        tracker.start()

        hub.$snapshots
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &bag)

        preferences.objectWillChange
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &bag)

        tracker.$location
            .sink { [weak self] point in self?.updatePlacements(mouse: point) }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &bag)

        // Spaces changes can drop a panel out of view on some setups.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.panel?.orderFrontRegardless() }
            .store(in: &bag)

        reposition()
    }

    func stop() {
        tracker.stop()
        bag.removeAll()
        panel?.orderOut(nil)
        panel = nil
    }

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        let p = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 72))
        let root = NotchClusterView()
            .environmentObject(self)
            .environmentObject(hub)
            .environmentObject(preferences)
        let host = FirstMouseHostingView(rootView: AnyView(root))
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        p.orderFrontRegardless()
        panel = p
    }

    // MARK: - Geometry

    /// Recompute the panel's frame from the current notch, preferences and the
    /// widths the visible sources need.
    func reposition() {
        guard let panel else { return }
        let snapshots = hub.snapshots

        // Nothing to show, or nowhere to show it (all displays asleep).
        guard !snapshots.isEmpty, let geo = NotchGeometry.current() else {
            panel.setFrame(.init(x: -10_000, y: -10_000, width: 1, height: 1), display: false)
            placements = []
            restPlacements = []
            tracker.interestRect = .zero
            panel.ignoresMouseEvents = true
            return
        }

        let dot = CGFloat(preferences.dotSize)
        let maxScale = CGFloat(preferences.maxScale)
        let spacing = CGFloat(preferences.spacing)
        let topPadding = max(2, (geo.menuBarHeight - dot) / 2)

        let items = snapshots.map {
            DotMetrics.item(for: $0, height: dot, showCount: preferences.showCountAtRest)
        }

        // Widest the cluster can ever get: every capsule open and magnified.
        let widestContent = items.reduce(CGFloat(0)) { $0 + $1.activeWidth * maxScale + spacing }
        let panelWidth = max(220, ceil(widestContent + edgeMargin * 2 + 24))
        let panelHeight = ceil(topPadding + dot * maxScale + 22)

        let anchorScreenX = geo.anchorX(side: preferences.side,
                                        offset: CGFloat(preferences.horizontalOffset))
        let originX: CGFloat = preferences.side == .left
            ? anchorScreenX + edgeMargin - panelWidth
            : anchorScreenX - edgeMargin
        let frame = NSRect(x: originX,
                           y: geo.topY - panelHeight,
                           width: panelWidth,
                           height: panelHeight)
        panel.setFrame(frame, display: true)

        layout = OverlayLayout(panelSize: frame.size,
                               menuBarHeight: geo.menuBarHeight,
                               dotSize: dot,
                               topPadding: topPadding,
                               side: preferences.side,
                               anchorX: preferences.side == .left ? panelWidth - edgeMargin : edgeMargin)

        // Rest layout drives the interest region. Deriving it from the *resting*
        // cluster keeps the region stable — a region that shrank as the cluster
        // collapsed would make the cursor oscillate in and out of it.
        restPlacements = magnifier.layout(items, anchor: anchor, mouseX: nil, hoverAmount: 0)
        updateInterestRect()
        updatePlacements(mouse: tracker.location)
    }

    private var magnifier: DockMagnifier {
        DockMagnifier(maxScale: CGFloat(preferences.maxScale),
                      influence: CGFloat(preferences.influenceRadius),
                      spacing: CGFloat(preferences.spacing))
    }

    private var anchor: DockMagnifier.Anchor {
        layout.side == .left ? .trailing(layout.anchorX) : .leading(layout.anchorX)
    }

    private func updateInterestRect() {
        guard let panel, let bounds = restPlacements.horizontalBounds else {
            tracker.interestRect = .zero
            return
        }
        let pad = CGFloat(preferences.influenceRadius) + 24
        let minX = panel.frame.minX + bounds.lowerBound - pad
        let maxX = panel.frame.minX + bounds.upperBound + pad
        // Reach a little below the panel so approach from the content area
        // starts the magnification before the cursor arrives.
        tracker.interestRect = CGRect(x: minX,
                                      y: panel.frame.minY - 40,
                                      width: maxX - minX,
                                      height: panel.frame.height + 40)
    }

    private func updatePlacements(mouse: CGPoint?) {
        guard let panel, !hub.snapshots.isEmpty else { return }
        let dot = layout.dotSize
        let items = hub.snapshots.map {
            DotMetrics.item(for: $0, height: dot, showCount: preferences.showCountAtRest)
        }
        let localX = mouse.map { $0.x - panel.frame.minX }
        let next = magnifier.layout(items,
                                    anchor: anchor,
                                    mouseX: localX,
                                    hoverAmount: mouse == nil ? 0 : 1)
        if next != placements { placements = next }

        // Accept clicks only while the cursor is actually over a dot, so the
        // menu bar and whatever is underneath stay fully usable otherwise.
        // This reuses the view's own geometry helpers, so the clickable region
        // is by construction the region that is drawn.
        var interactive = false
        if let mouse {
            let byID = Dictionary(uniqueKeysWithValues: hub.snapshots.map { ($0.id, $0) })
            for p in next {
                guard let snapshot = byID[p.id] else { continue }
                let restH = DotMetrics.restHeight(for: snapshot, height: dot,
                                                  showCount: preferences.showCountAtRest)
                let h = DotMetrics.renderHeight(rest: restH, full: dot,
                                                progress: p.progress, scale: p.scale)
                let topLocal = DotMetrics.topY(menuBarHeight: layout.menuBarHeight, restHeight: restH)
                let rect = CGRect(x: panel.frame.minX + p.minX,
                                  y: panel.frame.maxY - topLocal - h,
                                  width: p.width,
                                  height: h).insetBy(dx: -3, dy: -3)
                if rect.contains(mouse) { interactive = true; break }
            }
        }
        if panel.ignoresMouseEvents == interactive {
            panel.ignoresMouseEvents = !interactive
        }
    }

    /// How magnified the cluster currently is, 0…1. Drives the backdrop.
    var hoverAmount: CGFloat { placements.map(\.progress).max() ?? 0 }

    // MARK: - Actions

    func handleClick(_ id: String) {
        guard let source = hub.source(for: id) else { return }
        if let remedy = source.remedy {
            remedy.perform()
        } else {
            source.activate()
        }
    }

    func refreshAll() { hub.refreshAll() }
}
