import SwiftUI

/// Carries the menu's measured height back to the overlay controller.
struct CardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Carries the width the menu's names need.
struct CardWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Root of the floating panel. There is only ever one surface here: the dot,
/// which stretches into the menu and back.
struct OverlayRootView: View {
    @EnvironmentObject private var controller: OverlayController
    @EnvironmentObject private var model: GlintModel
    @EnvironmentObject private var prefs: Preferences

    @State private var glowPhase: CGFloat = 0

    private var layout: OverlayLayout { controller.layout }

    /// True when at least one waiting item is an actual message rather than a
    /// reaction or a like. Drives whether the surface burns full colour.
    private var hasSubstance: Bool {
        model.summaries.contains { $0.count > 0 && ($0.kind == .messages || $0.kind == .comments) }
    }

    private var accent: Accent { hasSubstance ? .instagram : .quiet }
    private var openAmount: CGFloat { controller.isCardOpen ? 1 : 0 }

    /// The glow only breathes when something is waiting and the user wants
    /// animation. Otherwise it holds still.
    private var pulses: Bool { model.total > 0 && prefs.animations }

    private var closedRect: CGRect {
        // While the menu is open the dot endpoint is held at rest size. The
        // morph and the magnification run on different springs, and letting
        // both drive the same rectangle is what made the surface wobble.
        MorphMetrics.closedRect(anchorX: layout.anchorX,
                                side: layout.side,
                                menuBarHeight: layout.menuBarHeight,
                                dotSize: layout.dotSize,
                                count: model.total,
                                showCount: prefs.showCountAtRest,
                                progress: controller.isCardOpen ? 0 : controller.progress,
                                scale: controller.isCardOpen ? 1 : controller.scale)
    }

    private var openRect: CGRect {
        // Held steady for as long as the menu is open.
        if let frozen = controller.frozenOpen { return frozen }
        return MorphMetrics.openRect(anchorX: layout.anchorX,
                              side: layout.side,
                              closed: closedRect,
                              cardWidth: controller.cardWidth,
                              cardHeight: controller.measuredCardHeight)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            measuringCopy

            if controller.isDotVisible {
                MorphingSurface(closed: closedRect,
                                open: openRect,
                                t: openAmount,
                                side: layout.side,
                                accent: accent,
                                isLit: model.total > 0,
                                glowPhase: glowPhase,
                                animated: prefs.animations) {
                    DotContentView(count: model.total,
                                   state: model.state,
                                   dotSize: layout.dotSize,
                                   progress: controller.progress,
                                   scale: controller.scale,
                                   showCountAtRest: prefs.showCountAtRest,
                                   arrivalTick: model.arrivalTick,
                                   accentGlow: accent.glow,
                                   animated: prefs.animations)
                } menuContent: {
                    HoverCardView(model: model,
                                  prefs: prefs,
                                  onOpenSettings: { controller.onOpenSettings?() },
                                  composing: controller.composingThreadID,
                                  onCompose: { controller.setComposing($0) },
                                  width: controller.cardWidth)
                }
                .onTapGesture { if !controller.isCardOpen { controller.dotTapped() } }
                .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
        .frame(width: layout.panelSize.width,
               height: layout.panelSize.height,
               alignment: .topLeading)
        .animation(Motion.morph, value: openAmount)
        .animation(Motion.magnify, value: controller.scale)
        .animation(Motion.reveal, value: layout.dotCenterX)
        .animation(Motion.pop, value: model.total)
        .onChange(of: pulses, initial: true) { _, on in
            if on {
                withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) {
                    glowPhase = 1
                }
            } else {
                // A lit dot keeps a steady glow with animation off. It is the
                // breathing that goes, not the light.
                withAnimation(Motion.enabled ? .easeOut(duration: 0.3) : nil) {
                    glowPhase = model.total > 0 ? 0.5 : 0
                }
            }
        }
        .onPreferenceChange(CardHeightKey.self) { height in
            MainActor.assumeIsolated { controller.setCardHeight(height) }
        }
        .onPreferenceChange(CardWidthKey.self) { width in
            MainActor.assumeIsolated { controller.setCardWidth(width) }
        }
        .contextMenu { menu }
        .ignoresSafeArea()
    }

    /// The surface has to know how tall the menu *will* be before it opens, or
    /// the first morph would have nothing to interpolate towards. An invisible
    /// copy is laid out continuously and reports its height.
    private var measuringCopy: some View {
        ZStack(alignment: .topLeading) {
            // Draws the reply field too, or the surface would never make room
            // for it.
            HoverCardView(model: model, prefs: prefs, onOpenSettings: {},
                          composing: controller.composingThreadID,
                          measuring: .height, width: controller.cardWidth)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: CardHeightKey.self, value: proxy.size.height)
                    }
                )

            // Height and width are measured separately. Every row is one line,
            // so height does not depend on width and neither feeds the other.
            HoverCardView(model: model, prefs: prefs, onOpenSettings: {}, measuring: .width)
                .fixedSize(horizontal: true, vertical: true)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: CardWidthKey.self, value: proxy.size.width)
                    }
                )
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var menu: some View {
        Text("Instagram · \(model.state.summary)")
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
        Button("Quit Glint") { controller.onQuit?() }
    }
}
