import AppKit

// Top-level code already runs on the main thread; `assumeIsolated` states that
// to the compiler rather than hopping and losing the delegate reference.
// The delegate is held in a global because `NSApplication.delegate` is weak.
private let appDelegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.delegate = appDelegate
    // No Dock icon and no app menu — Glint is only ever the dots beside the
    // notch plus an optional status item.
    application.setActivationPolicy(.accessory)
    application.run()
}
