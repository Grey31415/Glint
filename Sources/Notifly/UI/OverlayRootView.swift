import SwiftUI

/// Carries the hover card's measured height back to the overlay controller.
struct CardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Root of the floating panel: the dot, and the card that drops out of the
/// notch beneath it.
struct OverlayRootView: View {
    @EnvironmentObject private var controller: OverlayController
    @EnvironmentObject private var model: NotiflyModel
    @EnvironmentObject private var prefs: Preferences

    private var layout: OverlayLayout { controller.layout }

    /// True when at least one waiting item is an actual message rather than a
    /// reaction or a like. Drives whether the dot burns full colour.
    private var hasSubstance: Bool {
        model.summaries.contains { $0.count > 0 && ($0.kind == .messages || $0.kind == .comments) }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if controller.isCardOpen {
                HoverCardView(model: model,
                              prefs: prefs,
                              onOpenSettings: { controller.onOpenSettings?() })
                    // Offset rather than `.position`, so the card keeps its own
                    // intrinsic height instead of needing one guessed for it.
                    .fixedSize(horizontal: false, vertical: true)
                    // Report the real height so the controller knows exactly
                    // where the card stops and can close it the instant the
                    // cursor drops past its bottom edge.
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: CardHeightKey.self, value: proxy.size.height)
                        }
                    )
                    .offset(x: cardLeadingX, y: layout.menuBarHeight)
                    // Grows out of the dot itself: the scale anchor is the
                    // dot's own x within the card, so it unfolds from there
                    // rather than fading in like a separate window.
                    .transition(.scale(scale: 0.06, anchor: cardAnchor)
                        .combined(with: .opacity))
            }

            if controller.isDotVisible {
                NotchDotView(count: model.total,
                             hasSubstance: hasSubstance,
                             state: model.state,
                             dotSize: layout.dotSize,
                             menuBarHeight: layout.menuBarHeight,
                             progress: controller.progress,
                             scale: controller.scale,
                             showCountAtRest: prefs.showCountAtRest,
                             ambientBreathing: prefs.ambientBreathing,
                             arrivalTick: model.arrivalTick)
                    .position(x: layout.dotCenterX, y: dotCenterY)
                    .onTapGesture { controller.dotTapped() }
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
        .frame(width: layout.panelSize.width,
               height: layout.panelSize.height,
               alignment: .topLeading)
        .onPreferenceChange(CardHeightKey.self) { height in
            MainActor.assumeIsolated { controller.setCardHeight(height) }
        }
        .animation(Motion.magnify, value: controller.scale)
        .animation(Motion.reveal, value: layout.dotCenterX)
        .animation(Motion.pop, value: model.total)
        .contextMenu { menu }
        .ignoresSafeArea()
    }

    /// The dot hangs from a fixed line, so it sits centred in the menu bar at
    /// rest and grows *downwards* out of the notch when magnified.
    private var dotCenterY: CGFloat {
        let restH = DotGeometry.restHeight(count: model.total,
                                           height: layout.dotSize,
                                           showCount: prefs.showCountAtRest)
        let h = DotGeometry.renderHeight(rest: restH,
                                         full: layout.dotSize,
                                         progress: controller.progress,
                                         scale: controller.scale)
        return DotGeometry.topY(menuBarHeight: layout.menuBarHeight, restHeight: restH) + h / 2
    }

    /// The card's dot-side edge is pinned; it grows away from the dot.
    private var cardLeadingX: CGFloat {
        layout.side == .left ? layout.cardEdgeX - HoverCardView.width : layout.cardEdgeX
    }

    /// Where the dot sits along the card's top edge, as a unit point — the
    /// origin the card scales out of.
    private var cardAnchor: UnitPoint {
        let x = (layout.dotCenterX - cardLeadingX) / HoverCardView.width
        return UnitPoint(x: min(max(x, 0), 1), y: 0)
    }

    @ViewBuilder
    private var menu: some View {
        Text("Instagram — \(model.state.summary)")
        if model.total > 0 {
            Button("Mark All as Read") { model.markAllRead() }
        }
        if model.totalSuppressed > 0 {
            Button("Undo Mark as Read (\(model.totalSuppressed) hidden)") { model.clearReadMarks() }
        }
        Divider()
        Button("Open Instagram") { model.openInbox() }
        Button("Refresh Now") { model.refresh() }
        Button("Settings…") { controller.onOpenSettings?() }
        Divider()
        Button("Quit Notifly") { controller.onQuit?() }
    }
}
