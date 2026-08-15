import AppKit
import Combine

/// Reports the cursor position in screen coordinates.
///
/// Deliberately a poll rather than an `NSEvent` monitor: the overlay spends most
/// of its life with `ignoresMouseEvents = true` so that the menu bar underneath
/// stays clickable, and a window that ignores events also stops receiving
/// mouse-moved events. Sampling `NSEvent.mouseLocation` sidesteps that entirely
/// and needs no Accessibility permission.
///
/// The poll runs slowly until the cursor enters `interestRect`, then speeds up
/// to display rate so magnification tracks the cursor smoothly.
@MainActor
final class MouseTracker: ObservableObject {
    /// nil while the cursor is outside `interestRect`.
    @Published private(set) var location: CGPoint?

    /// Region worth watching closely. Set by the overlay controller.
    var interestRect: CGRect = .zero

    private var timer: Timer?
    private var running = false
    private var isFast = false

    private let slowInterval: TimeInterval = 1.0 / 8.0
    private let fastInterval: TimeInterval = 1.0 / 100.0

    func start() {
        guard !running else { return }
        running = true
        schedule(fast: false)
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        location = nil
    }

    private func schedule(fast: Bool) {
        timer?.invalidate()
        isFast = fast
        let t = Timer(timeInterval: fast ? fastInterval : slowInterval,
                      repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        // .common so the poll survives menu tracking and window drags.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sample() {
        guard running else { return }
        let point = NSEvent.mouseLocation
        let inside = interestRect.contains(point)

        if inside {
            location = point
            if !isFast { schedule(fast: true) }
        } else {
            if location != nil { location = nil }
            if isFast { schedule(fast: false) }
        }
    }
}
