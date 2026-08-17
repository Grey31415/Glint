import AppKit
import Carbon.HIToolbox

/// One system-wide key combination.
///
/// Carbon, in 2026, on purpose. `RegisterEventHotKey` is the only way to claim a
/// key combination system-wide that needs neither an entitlement nor Accessibility
/// permission: `NSEvent.addGlobalMonitorForEvents` needs the latter, which for an
/// ad-hoc signed app means a permission dialog that cannot be granted convincingly.
/// The API is old and it is not deprecated.
@MainActor
final class Hotkey {
    /// Fired on the main thread when the combination is pressed.
    var onPress: (() -> Void)?

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// Distinguishes our hot key from anyone else's in the same handler.
    private static let signature = OSType(0x474C4E54)  // 'GLNT'
    private static var live: Hotkey?

    /// Default is Option-G: unclaimed by macOS, and no application is likely to
    /// mind, unlike anything involving Command. Nonisolated so they can be
    /// default arguments, which are evaluated at the call site.
    nonisolated static let defaultKeyCode = UInt32(kVK_ANSI_G)
    nonisolated static let defaultModifiers = UInt32(optionKey)

    func register(keyCode: UInt32 = Hotkey.defaultKeyCode,
                  modifiers: UInt32 = Hotkey.defaultModifiers) {
        unregister()
        Self.live = self

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == Hotkey.signature else { return noErr }
            // The handler is called on the main thread by the event loop that
            // owns it, so this is a statement of fact rather than a hop.
            MainActor.assumeIsolated { Hotkey.live?.onPress?() }
            return noErr
        }, 1, &spec, nil, &handler)

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            // Somebody else already owns the combination. Not fatal and not
            // worth a dialog, but silence here is how a dead shortcut becomes a
            // bug report.
            NSLog("[Glint] hotkey unavailable (status %d)", status)
            ref = nil
        }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        if Self.live === self { Self.live = nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
