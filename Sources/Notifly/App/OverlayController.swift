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
    /// Where the hover card's notch-side edge sits.
    var cardEdgeX: CGFloat = 0
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

    let model: NotiflyModel
    let preferences: Preferences
    let tracker = MouseTracker()

    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    /// Slack around the dot so its glow is never clipped.
    private let edgeMargin: CGFloat = 16
    /// Vertical room reserved for the card.
    private let cardMaxHeight: CGFloat = 460

    private var panel: OverlayPanel?
    private var bag = Set<AnyCancellable>()
    private var geometry: NotchGeometry?
    private var cardHeight: CGFloat = 0

    init(model: NotiflyModel, preferences: Preferences) {
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

        // The card hangs off the dot, not off the notch, so it stays attached
        // to the thing it belongs to — including while the dot is sliding out
        // in hidden mode.
        let cardOverhang: CGFloat = 14
        layout = OverlayLayout(panelSize: frame.size,
                               menuBarHeight: geo.menuBarHeight,
                               dotSize: dot,
                               side: preferences.side,
                               dotCenterX: dotCenterX,
                               cardEdgeX: preferences.side == .left
                                   ? dotCenterX + cardOverhang
                                   : dotCenterX - cardOverhang)

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
            let cardRight = panel.frame.minX + layout.cardEdgeX
            let cardRect = CGRect(x: preferences.side == .left ? cardRight - HoverCardView.width : cardRight,
                                  y: panel.frame.maxY - geo.menuBarHeight - cardMaxHeight,
                                  width: HoverCardView.width,
                                  height: cardMaxHeight)
            rect = rect.union(cardRect).insetBy(dx: -12, dy: -12)
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

        // Hidden mode: the notch is the reveal trigger. Stay revealed while the
        // cursor is still somewhere on the dot or the card.
        if preferences.hiddenMode {
            let reveal = inNotch || ((isRevealed || isCardOpen) && live)
            if reveal != isRevealed {
                withAnimation(Motion.reveal) { isRevealed = reveal }
                // Moving the dot changes every measurement above, so restart
                // rather than acting on stale numbers.
                reposition()
                return
            }
        } else if isRevealed {
            isRevealed = false
        }

        // Proximity magnification.
        let visible = !preferences.hiddenMode || isRevealed
        let newProgress: CGFloat = (visible && inStrip)
            ? DotGeometry.falloff(distance: distance, radius: CGFloat(preferences.influenceRadius))
            : 0
        if abs(newProgress - progress) > 0.001 {
            progress = newProgress
            scale = 1 + (CGFloat(preferences.maxScale) - 1) * newProgress
        }

        // Open on the dot, stay open anywhere on the card, close the instant
        // the cursor is on neither. There is no timer here: the dot's hover
        // region and the card's top edge overlap, so the pointer never crosses
        // dead space on its way between them.
        let overDot = visible && inStrip && distance < max(22, layout.dotSize * scale)
        let shouldOpen = preferences.showHoverCard && isDotVisible && (overDot || live)
        if shouldOpen != isCardOpen {
            withAnimation(Motion.card) { isCardOpen = shouldOpen }
            updateInterestRect()
        }

        updateMouseEvents(point: point, overDot: overDot)
    }

    /// The card's measured height, reported by the view. Using the real height
    /// rather than the reserved maximum is what lets the card close the moment
    /// the cursor drops below it.
    func setCardHeight(_ height: CGFloat) {
        guard abs(height - cardHeight) > 0.5 else { return }
        cardHeight = height
    }

    /// True while the cursor is anywhere in the currently live region — the dot
    /// plus, when open, the card. Gives the pointer somewhere to travel.
    private func withinLiveRegion(_ point: CGPoint?) -> Bool {
        guard let point, let panel, let geo = geometry else { return false }
        // The dot's band spans the full menu bar strip so the pointer can move
        // straight down into the card without crossing dead space.
        var region = CGRect(x: panel.frame.minX + layout.dotCenterX - 44,
                            y: panel.frame.maxY - geo.menuBarHeight,
                            width: 88,
                            height: geo.menuBarHeight)
        if preferences.hiddenMode {
            region = region.union(geo.notchRect.insetBy(dx: -6, dy: -6))
        }
        if isCardOpen {
            let edge = panel.frame.minX + layout.cardEdgeX
            let height = cardHeight > 0 ? cardHeight : 120
            region = region.union(CGRect(
                x: preferences.side == .left ? edge - HoverCardView.width : edge,
                y: panel.frame.maxY - geo.menuBarHeight - height,
                width: HoverCardView.width,
                height: height))
        }
        // A few points of slack absorbs sub-pixel jitter at the edges without
        // making the card linger anywhere it is not actually under the cursor.
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
