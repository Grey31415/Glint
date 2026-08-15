import SwiftUI

/// The overlay's root view: one magnified dot per source, and nothing else.
/// The tiles float directly over the menu bar — no panel, no backdrop.
struct NotchClusterView: View {
    @EnvironmentObject private var controller: OverlayController
    @EnvironmentObject private var hub: NotificationHub
    @EnvironmentObject private var prefs: Preferences

    private var layout: OverlayLayout { controller.layout }

    private var visible: [SourceSnapshot] {
        hub.snapshots.filter { $0.isVisible(hideWhenEmpty: prefs.hideWhenEmpty) }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(visible) { snapshot in
                if let placement = controller.placements.first(where: { $0.id == snapshot.id }) {
                    SourceDotView(snapshot: snapshot,
                                  placement: placement,
                                  layout: layout,
                                  showCountAtRest: prefs.showCountAtRest,
                                  ambientBreathing: prefs.ambientBreathing,
                                  onTap: { controller.handleClick(snapshot.id) })
                        .position(x: placement.centerX,
                                  y: centerY(for: snapshot, placement: placement))
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }
        }
        .frame(width: layout.panelSize.width,
               height: layout.panelSize.height,
               alignment: .topLeading)
        .animation(Motion.magnify, value: controller.placements)
        .animation(Motion.pop, value: hub.snapshots)
        .contextMenu { menu }
        .ignoresSafeArea()
    }

    /// Dots hang from a fixed line so they sit centred in the menu bar at rest
    /// and grow *downwards* out of the notch when magnified — the same trick the
    /// Dock uses, rotated a quarter turn.
    private func centerY(for snapshot: SourceSnapshot, placement: MagnifiedPlacement) -> CGFloat {
        let restH = DotMetrics.restHeight(for: snapshot,
                                          height: layout.dotSize,
                                          showCount: prefs.showCountAtRest)
        let h = DotMetrics.renderHeight(rest: restH,
                                        full: layout.dotSize,
                                        progress: placement.progress,
                                        scale: placement.scale)
        return DotMetrics.topY(menuBarHeight: layout.menuBarHeight, restHeight: restH) + h / 2
    }

    // MARK: - Right-click menu

    @ViewBuilder
    private var menu: some View {
        ForEach(hub.snapshots) { snapshot in
            Text("\(snapshot.descriptor.name) — \(snapshot.menuSummary)")
        }
        Divider()
        ForEach(hub.snapshots.filter { $0.displayCount > 0 }) { snapshot in
            Button("Mark \(snapshot.descriptor.name) as Read") { hub.markRead(snapshot.id) }
        }
        if hub.totalUnread > 0 {
            Button("Mark All as Read") { hub.markAllRead() }
        }
        if hub.totalSuppressed > 0 {
            Button("Undo Mark as Read (\(hub.totalSuppressed) hidden)") { hub.clearReadMarks() }
        }
        Divider()
        Button("Refresh Now") { controller.refreshAll() }
        Button("Settings…") { controller.onOpenSettings?() }
        Divider()
        Button("Quit Notifly") { controller.onQuit?() }
    }
}
