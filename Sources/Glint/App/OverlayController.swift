import AppKit
import Combine
import SwiftUI

/// Layout facts the overlay view needs, in panel-local coordinates.
struct OverlayLayout: Equatable {
    var panelSize: CGSize = .zero
    var menuBarHeight: CGFloat = 24
    var dotSize: CGFloat = 15
    var side: DockSide = .left
    /// Centre of the dot.
    var dotCenterX: CGFloat = 0
    /// The notch-side edge the surface is anchored on. Fixed: it does not move
    /// with magnification, so the morph has nothing to slide against.
    var anchorX: CGFloat = 0
}

/// Owns the floating panel: positions it beside (or inside) the notch, tracks
/// the cursor, and decides when the dot is revealed and the card is open.
@MainActor
final class OverlayController: ObservableObject {
    @Published private(set) var layout = OverlayLayout()
    @Published private(set) var progress: CGFloat = 0     // cursor proximity, 0…1
    @Published private(set) var scale: CGFloat = 1
    @Published private(set) var isRevealed = false        // hidden mode only
    @Published private(set) var isCardOpen = false
    /// Geometry captured the moment the menu opened.
    ///
    /// The feed refreshes on a timer, and rows arriving or leaving would
    /// otherwise resize the menu under the cursor while it is being read. The
    /// menu holds the shape it opened at until it closes; content that outgrows
    /// it scrolls instead of pushing the edges around.
    @Published private(set) var frozenOpen: CGRect?

    let model: GlintModel
    let preferences: Preferences
    let tracker = MouseTracker()

    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    /// Slack around the surface inside the panel.
    ///
    /// Has to clear the drop shadow, not just the glow: SwiftUI's shadow blur
    /// reaches roughly 1.5x its radius, and at 16pt the menu's shadow was being
    /// cut off square by the panel bounds — a hard vertical edge down its left
    /// side.
    private let edgeMargin: CGFloat = 40
    /// Vertical room reserved for the card.
    private let cardMaxHeight: CGFloat = 460

    private var panel: OverlayPanel?
    private var bag = Set<AnyCancellable>()
    private var geometry: NotchGeometry?
    private var parkWork: DispatchWorkItem?
    /// Measured height of the menu contents; the morph interpolates towards it.
    private(set) var measuredCardHeight: CGFloat = 0

    init(model: GlintModel, preferences: Preferences) {
        self.model = model
        self.preferences = preferences
    }

    // MARK: - Lifecycle

    func start() {
        buildPanelIfNeeded()
        tracker.start()

        model.$summaries
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &bag)

        preferences.objectWillChange
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &bag)

        tracker.$location
            .sink { [weak self] point in self?.cursorMoved(to: point) }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &bag)

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
        let p = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80))
        let root = OverlayRootView()
            .environmentObject(self)
            .environmentObject(model)
            .environmentObject(preferences)
        let host = FirstMouseHostingView(rootView: AnyView(root))
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        p.orderFrontRegardless()
        panel = p
    }

    // MARK: - Geometry

    /// Whether the dot should be drawn at all right now.
    var isDotVisible: Bool {
        if preferences.hideWhenEmpty && model.total == 0 && model.state == .ready { return false }
        return true
    }

    func reposition() {
        guard let panel else { return }
        guard let geo = NotchGeometry.current() else {
            panel.setFrame(.init(x: -10_000, y: -10_000, width: 1, height: 1), display: false)
            return
        }
        geometry = geo

        let dot = CGFloat(preferences.dotSize)
        let maxScale = CGFloat(preferences.maxScale)

        // Anchor: the notch-side edge the dot docks against, in screen space.
        let revealedAnchor = geo.anchorX(side: preferences.side,
                                         offset: CGFloat(preferences.horizontalOffset))
        // Parked: centred in the notch, a region of the display with no pixels.
        let hiddenAnchor = geo.notchRect.midX
        let anchorScreenX = (preferences.hiddenMode && !isRevealed) ? hiddenAnchor : revealedAnchor

        // The panel has to span everything that can be drawn: the dot parked
        // inside the notch, the dot revealed beside it, and the card hanging
        // below — which extends *away* from the notch and is far wider than
        // the dot, so it sets the outer edge.
        let cardWidth = preferences.showHoverCard ? HoverCardView.width : 0
        let dotHalf = DotGeometry.capsuleWidth(digits: 4, height: dot) * maxScale / 2 + edgeMargin
        let minX: CGFloat
        let maxX: CGFloat
        switch preferences.side {
        case .left:
            minX = revealedAnchor - max(cardWidth, dotHalf * 2) - edgeMargin
            maxX = max(revealedAnchor + edgeMargin, hiddenAnchor + dotHalf)
        case .right:
            minX = min(revealedAnchor - edgeMargin, hiddenAnchor - dotHalf)
            maxX = revealedAnchor + max(cardWidth, dotHalf * 2) + edgeMargin
        }

        let panelHeight = ceil(geo.menuBarHeight + cardMaxHeight)
        let frame = NSRect(x: floor(minX),
                           y: geo.topY - panelHeight,
                           width: ceil(maxX - minX),
                           height: panelHeight)
        panel.setFrame(frame, display: true)

        // Dot centre in panel-local coordinates.
        let restW = DotGeometry.restWidth(countText: DotGeometry.countText(model.total),
                                          count: model.total,
                                          height: dot,
                                          showCount: preferences.showCountAtRest)
        let localAnchor = anchorScreenX - frame.minX
        let dotCenterX = preferences.side == .left ? localAnchor - restW / 2 : localAnchor + restW / 2

        layout = OverlayLayout(panelSize: frame.size,
                               menuBarHeight: geo.menuBarHeight,
                               dotSize: dot,
                               side: preferences.side,
                               dotCenterX: dotCenterX,
                               anchorX: localAnchor)

        updateInterestRect()
        cursorMoved(to: tracker.location)
    }

    private func updateInterestRect() {
        guard let panel, let geo = geometry else { return }
        // In hidden mode the trigger is the notch itself; otherwise it is the
        // region around the dot.
        let influence = CGFloat(preferences.influenceRadius)
        let triggerMinX: CGFloat
        let triggerMaxX: CGFloat
        if preferences.hiddenMode && !isRevealed {
            triggerMinX = geo.notchRect.minX - 8
            triggerMaxX = geo.notchRect.maxX + 8
        } else {
            let dotScreenX = panel.frame.minX + layout.dotCenterX
            triggerMinX = min(dotScreenX - influence - 24, geo.notchRect.minX - 8)
            triggerMaxX = max(dotScreenX + influence + 24, geo.notchRect.maxX + 8)
        }

        // While the card is open the whole card counts, so moving the cursor
        // into it does not dismiss the thing you are reaching for.
        var rect = CGRect(x: triggerMinX,
                          y: panel.frame.maxY - geo.menuBarHeight - 40,
                          width: triggerMaxX - triggerMinX,
                          height: geo.menuBarHeight + 40)
        if isCardOpen {
            // Track the surface at full size, so the cursor is still being
            // sampled anywhere over the open menu.
            let open = frozenOpen ?? currentOpenRect()
            let openScreen = CGRect(x: panel.frame.minX + open.minX,
                                    y: panel.frame.maxY - open.maxY,
                                    width: open.width,
                                    height: open.height)
            rect = rect.union(openScreen).insetBy(dx: -12, dy: -12)
        }
        tracker.interestRect = rect
    }

    // MARK: - Cursor

    private func cursorMoved(to point: CGPoint?) {
        guard let panel, let geo = geometry else { return }

        let inNotch = point.map { geo.notchRect.insetBy(dx: -6, dy: -6).contains($0) } ?? false
        let dotScreenX = panel.frame.minX + layout.dotCenterX
        let distance = point.map { abs($0.x - dotScreenX) } ?? .greatestFiniteMagnitude
        let inStrip = point.map { $0.y > panel.frame.maxY - geo.menuBarHeight - 24 } ?? false
        let live = withinLiveRegion(point)

        // Proximity magnification.
        let visible = !preferences.hiddenMode || isRevealed
        let newProgress: CGFloat = (visible && inStrip)
            ? DotGeometry.falloff(distance: distance, radius: CGFloat(preferences.influenceRadius))
            : 0
        if abs(newProgress - progress) > 0.001 {
            progress = newProgress
            scale = 1 + (CGFloat(preferences.maxScale) - 1) * newProgress
        }

        // Open on the dot, stay open anywhere on the surface, close the instant
        // the cursor is on neither. There is no timer here: the dot's hover
        // region and the menu's top edge overlap, so the pointer never crosses
        // dead space on its way between them.
        //
        // Opening requires the *dot* specifically, not merely the live region.
        // In hidden mode the live region includes the notch, and opening from
        // there would unfold the menu while it was still parked behind the
        // camera housing — which is what made it appear half-eaten by the notch.
        let overDot = visible && inStrip && distance < max(22, layout.dotSize * scale)
        let shouldOpen = preferences.showHoverCard && isDotVisible
            && (overDot || (isCardOpen && live))
        if shouldOpen != isCardOpen {
            frozenOpen = shouldOpen ? currentOpenRect() : nil
            withAnimation(Motion.card) { isCardOpen = shouldOpen }
            updateInterestRect()
        }

        // Hidden mode reveal, handled *after* the menu.
        //
        // The dot must not travel back under the notch while the menu is still
        // on screen, so the reveal is held for as long as the menu is open and
        // parking is deferred past the closing animation. The menu itself still
        // dismisses immediately; only the dot's journey home waits.
        if preferences.hiddenMode {
            let wantReveal = inNotch || isCardOpen || (isRevealed && live)
            if wantReveal != isRevealed {
                if wantReveal {
                    parkWork?.cancel()
                    parkWork = nil
                    withAnimation(Motion.reveal) { isRevealed = true }
                    reposition()
                } else {
                    schedulePark()
                }
            }
        } else if isRevealed {
            isRevealed = false
            reposition()
        }

        updateMouseEvents(point: point, overDot: overDot)

        if Self.traceMorph {
            let c = closedRect
            let o = frozenOpen ?? currentOpenRect()
            NSLog("[Glint:morph] open=%@ anchor=%.1f prog=%.2f scale=%.2f closed=(%.1f,%.1f,%.1f,%.1f) openR=(%.1f,%.1f,%.1f,%.1f) frozen=%@",
                  isCardOpen ? "Y" : "n", layout.anchorX, progress, scale,
                  c.minX, c.minY, c.width, c.height,
                  o.minX, o.minY, o.width, o.height,
                  frozenOpen == nil ? "nil" : "set")
        }
    }

    static let traceMorph = ProcessInfo.processInfo.environment["GLINT_TRACE_MORPH"] == "1"

    /// The menu's measured height, reported by the view. Using the real height
    /// rather than a reserved maximum is what lets the surface close the moment
    /// the cursor drops past its actual bottom edge.
    func setCardHeight(_ height: CGFloat) {
        guard abs(height - measuredCardHeight) > 0.5 else { return }
        measuredCardHeight = height
    }

    /// The dot as currently drawn, in panel-local coordinates. Same maths the
    /// view uses, so what is clickable is exactly what is on screen.
    private var closedRect: CGRect {
        MorphMetrics.closedRect(anchorX: layout.anchorX,
                                side: layout.side,
                                menuBarHeight: layout.menuBarHeight,
                                dotSize: layout.dotSize,
                                count: model.total,
                                showCount: preferences.showCountAtRest,
                                progress: progress,
                                scale: scale)
    }

    /// Slides the dot back behind the notch once the menu has finished closing.
    private func schedulePark() {
        parkWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.preferences.hiddenMode, self.isRevealed else { return }
            guard !self.isCardOpen, !self.withinLiveRegion(self.tracker.location) else { return }
            withAnimation(Motion.reveal) { self.isRevealed = false }
            self.reposition()
        }
        parkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
    }

    /// The menu rectangle as it would be right now, before freezing.
    private func currentOpenRect() -> CGRect {
        MorphMetrics.openRect(anchorX: layout.anchorX,
                              side: preferences.side,
                              closed: closedRect,
                              cardWidth: HoverCardView.width,
                              cardHeight: measuredCardHeight > 0 ? measuredCardHeight : 200)
    }

    /// True while the cursor is anywhere in the currently live region.
    ///
    /// Two parts: a forgiving band around the dot — the resting dot is only a
    /// few points wide and would otherwise be an unfair target — and, once
    /// open, the surface itself. The surface grows *out of* the dot, so the
    /// pointer never has to cross dead space to reach the menu.
    private func withinLiveRegion(_ point: CGPoint?) -> Bool {
        guard let point, let panel, let geo = geometry else { return false }
        let toScreen = { (r: CGRect) -> CGRect in
            CGRect(x: panel.frame.minX + r.minX,
                   y: panel.frame.maxY - r.maxY,
                   width: r.width,
                   height: r.height)
        }

        var region = CGRect(x: panel.frame.minX + layout.dotCenterX - 44,
                            y: panel.frame.maxY - geo.menuBarHeight,
                            width: 88,
                            height: geo.menuBarHeight)
        if preferences.hiddenMode {
            region = region.union(geo.notchRect.insetBy(dx: -6, dy: -6))
        }
        if isCardOpen {
            region = region.union(toScreen(frozenOpen ?? currentOpenRect()))
        }
        // A few points of slack absorbs sub-pixel jitter at the edges without
        // making the menu linger anywhere it is not actually under the cursor.
        return region.insetBy(dx: -4, dy: -4).contains(point)
    }

    /// Accept clicks only where something is actually drawn, so the menu bar
    /// underneath stays fully usable the rest of the time.
    private func updateMouseEvents(point: CGPoint?, overDot: Bool) {
        guard let panel else { return }
        let interactive = (overDot || (isCardOpen && withinLiveRegion(point))) && isDotVisible
        if panel.ignoresMouseEvents == interactive {
            panel.ignoresMouseEvents = !interactive
        }
    }

    // MARK: - Actions

    func dotTapped() {
        if NSEvent.modifierFlags.contains(.option) {
            model.markAllRead()
            return
        }
        if let remedy = model.source.remedy {
            remedy.perform()
        } else {
            model.openInbox()
        }
    }
}
