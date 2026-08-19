import AppKit
import SwiftUI

/// Glint draws on two different grounds, and only one of them is fixed.
///
/// The dot sits on the notch, which is black on every machine - so the dot's
/// own colour is hardware-matching and never changes. The menu it stretches
/// into is glass, and glass takes its tone from the system appearance: light in
/// light mode, dark in dark mode. A dark-only palette therefore put near-white
/// text on near-white glass. Every neutral below is a pair, resolved by AppKit
/// at draw time, so the views can go on naming one colour.
enum Palette {
    static let card       = adaptive(dark: .srgb(0.055, 0.056, 0.070),
                                     light: .srgb(0.97, 0.97, 0.98))
    static let cardRaised = adaptive(dark: .srgb(0.098, 0.100, 0.122),
                                     light: .srgb(1.00, 1.00, 1.00))
    static let surface    = adaptive(dark: .srgb(0.075, 0.076, 0.094),
                                     light: .srgb(0.93, 0.93, 0.95))
    static let hairline   = adaptive(dark: .srgb(1, 1, 1, 0.12),
                                     light: .srgb(0, 0, 0, 0.14))
    static let idle       = adaptive(dark: .srgb(0.40, 0.41, 0.48),
                                     light: .srgb(0.58, 0.59, 0.65))
    static let textHi     = adaptive(dark: .srgb(0.97, 0.97, 0.99),
                                     light: .srgb(0.05, 0.05, 0.07))
    static let textMid    = adaptive(dark: .srgb(0.74, 0.75, 0.81),
                                     light: .srgb(0.24, 0.25, 0.30))
    static let textLo     = adaptive(dark: .srgb(0.55, 0.56, 0.63),
                                     light: .srgb(0.40, 0.41, 0.47))
    /// Amber reads on black but washes out on white, so light mode gets the
    /// same hue taken down to something that holds against glass.
    static let warning    = adaptive(dark: .srgb(1.00, 0.74, 0.33),
                                     light: .srgb(0.72, 0.45, 0.02))

    /// The wash under the row your cursor is on. Lifting a light surface with
    /// white does nothing, so light mode presses it down with black instead.
    static let rowHover   = adaptive(dark: .srgb(1, 1, 1, 0.10),
                                     light: .srgb(0, 0, 0, 0.07))

    /// Darkens glass, in dark mode only.
    ///
    /// Glass takes its weight from what is behind it, and behind the dot is the
    /// notch: black, on every machine, in both appearances. In light mode that
    /// contrast is what makes a glassy dot read as an object. In dark mode the
    /// glass lightens the black it sits on, so the dot came out *paler* than its
    /// surroundings - a bright pill on a dark bar, which is the opposite of what
    /// turning the glass up asks for.
    static let glassScrim = adaptive(dark: .srgb(0, 0, 0, 0.48),
                                     light: .srgb(0, 0, 0, 0))

    /// The surface's own edge. Call sites vary its opacity along the border, so
    /// this carries the tone and lets that multiply into it.
    static let rim        = adaptive(dark: .srgb(1, 1, 1, 1.00),
                                     light: .srgb(0, 0, 0, 0.55))
}

/// One colour that knows both appearances. `bestMatch` rather than a plain
/// name check, so the high-contrast and vibrant variants land on the right side.
private func adaptive(dark: NSColor, light: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

private extension NSColor {
    static func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

/// The colours a lit dot is made of: soft blobs drifting over a `base` wash.
struct Accent: Equatable {
    let colors: [Color]
    let base: Color
    let glow: Color

    static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }

    /// The full Instagram gradient, not just the pink end of it.
    static let instagram = Accent(
        colors: [hex(0xFEDA75), hex(0xFA7E1E), hex(0xD62976), hex(0x962FBF), hex(0x4F5BD5)],
        base: hex(0xB4287E),
        glow: hex(0xD62976))

    /// Used when everything waiting is noise - reactions, likes - and nothing
    /// actually needs a reply. Same shapes, drained of urgency.
    static let quiet = Accent(
        colors: [hex(0x9AA0B5), hex(0x7C8394), hex(0x6C7386), hex(0x5A6072), hex(0x8A90A2)],
        base: hex(0x6A7182),
        glow: hex(0x8A90A2))

    /// What the app is painted in: the dot, the menu, and every control in
    /// Settings, so they can never disagree.
    ///
    /// One name rather than `.instagram` spelled out at each of the nineteen
    /// places that ask, which is also where a colour setting would hook in if
    /// one ever comes back.
    static var current: Accent { .instagram }
}

/// Shared spring vocabulary. One place to retune the whole feel.
/// Every spring is optional. With animations switched off they all go nil and
/// SwiftUI applies the change on the spot.
enum Motion {
    static var enabled: Bool { Preferences.animationsEnabled }

    static var magnify: Animation? { gated(.interpolatingSpring(stiffness: 420, damping: 30)) }
    static var pop: Animation? { gated(.spring(response: 0.42, dampingFraction: 0.58)) }
    /// Dot sliding out from behind the notch in hidden mode.
    static var reveal: Animation? { gated(.spring(response: 0.40, dampingFraction: 0.78)) }
    /// Hover card opening and closing.
    static var card: Animation? { gated(.spring(response: 0.34, dampingFraction: 0.82)) }
    /// The dot stretching into the menu. Slightly slower and better damped than
    /// a normal pop, because the eye is following a shape change rather than a
    /// thing appearing - overshoot here reads as wobble.
    static var morph: Animation? { gated(.spring(response: 0.38, dampingFraction: 0.86)) }

    private static func gated(_ animation: Animation) -> Animation? {
        enabled ? animation : nil
    }
}

