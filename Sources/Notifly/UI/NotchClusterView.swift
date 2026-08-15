import SwiftUI

/// The overlay's root view: a backdrop that slides out of the notch plus one
/// magnified dot per source.
struct NotchClusterView: View {
    @EnvironmentObject private var controller: OverlayController
    @EnvironmentObject private var hub: NotificationHub
    @EnvironmentObject private var prefs: Preferences

    private var layout: OverlayLayout { controller.layout }
    private var hover: CGFloat { controller.hoverAmount }

    private var visible: [SourceSnapshot] {
        guard prefs.hideWhenEmpty else { return hub.snapshots }
        return hub.snapshots.filter { $0.displayCount > 0 || $0.state.isBlocked || $0.state == .loading }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            dots
        }
        .frame(width: layout.panelSize.width,
               height: layout.panelSize.height,
               alignment: .topLeading)
        .animation(Motion.magnify, value: controller.placements)
        .animation(Motion.pop, value: hub.snapshots)
        .contextMenu { menu }
        .ignoresSafeArea()
    }

    // MARK: - Dots

    private var dots: some View {
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

    private func bottomY(for snapshot: SourceSnapshot, placement: MagnifiedPlacement) -> CGFloat {
        let restH = DotMetrics.restHeight(for: snapshot,
                                          height: layout.dotSize,
                                          showCount: prefs.showCountAtRest)
        let h = DotMetrics.renderHeight(rest: restH,
                                        full: layout.dotSize,
                                        progress: placement.progress,
                                        scale: placement.scale)
        return DotMetrics.topY(menuBarHeight: layout.menuBarHeight, restHeight: restH) + h
    }

    // MARK: - Backdrop

    /// Square at the top, rounded at the bottom — so it reads as the notch
    /// itself extending downwards rather than as a floating window.
    @ViewBuilder
    private var backdrop: some View {
        if hover > 0.001, let bounds = clusterBounds {
            let pad: CGFloat = 10
            let width = bounds.upperBound - bounds.lowerBound + pad * 2
            let depth = max(layout.menuBarHeight, backdropDepth + 9)

            UnevenRoundedRectangle(topLeadingRadius: 0,
                                   bottomLeadingRadius: 15,
                                   bottomTrailingRadius: 15,
                                   topTrailingRadius: 0,
                                   style: .continuous)
                .fill(Palette.notch)
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 0,
                                           bottomLeadingRadius: 15,
                                           bottomTrailingRadius: 15,
                                           topTrailingRadius: 0,
                                           style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                .frame(width: width, height: depth)
                .position(x: (bounds.lowerBound + bounds.upperBound) / 2, y: depth / 2)
                .opacity(Double(min(1, hover * 1.5)))
                .animation(Motion.curtain, value: depth)
                .allowsHitTesting(false)
        }
    }

    private var clusterBounds: ClosedRange<CGFloat>? {
        let ids = Set(visible.map(\.id))
        return controller.placements.filter { ids.contains($0.id) }.horizontalBounds
    }

    private var backdropDepth: CGFloat {
        var deepest: CGFloat = 0
        for snapshot in visible {
            guard let placement = controller.placements.first(where: { $0.id == snapshot.id }) else { continue }
            deepest = max(deepest, bottomY(for: snapshot, placement: placement))
        }
        return deepest
    }

    // MARK: - Right-click menu

    @ViewBuilder
    private var menu: some View {
        ForEach(hub.snapshots) { snapshot in
            Text("\(snapshot.descriptor.name) — \(snapshot.state.summary)")
        }
        Divider()
        Button("Refresh Now") { controller.refreshAll() }
        Button("Settings…") { controller.onOpenSettings?() }
        Divider()
        Button("Quit Notifly") { controller.onQuit?() }
    }
}
