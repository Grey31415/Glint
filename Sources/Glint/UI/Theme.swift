import SwiftUI

/// Glint renders on and around the notch, which is black on every machine
/// regardless of appearance. The palette is deliberately dark-only — it is
/// hardware-matching, not theme-following.
enum Palette {
    static let card       = Color(red: 0.055, green: 0.056, blue: 0.070)
    static let cardRaised = Color(red: 0.098, green: 0.100, blue: 0.122)
    static let surface    = Color(red: 0.075, green: 0.076, blue: 0.094)
    static let hairline   = Color.white.opacity(0.12)
    static let idle       = Color(red: 0.40, green: 0.41, blue: 0.48)
    static let textHi     = Color(red: 0.97, green: 0.97, blue: 0.99)
    static let textMid    = Color(red: 0.74, green: 0.75, blue: 0.81)
    static let textLo     = Color(red: 0.55, green: 0.56, blue: 0.63)
    static let warning    = Color(red: 1.00, green: 0.74, blue: 0.33)
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

    /// Used when everything waiting is noise — reactions, likes — and nothing
    /// actually needs a reply. Same shapes, drained of urgency.
    static let quiet = Accent(
        colors: [hex(0x9AA0B5), hex(0x7C8394), hex(0x6C7386), hex(0x5A6072), hex(0x8A90A2)],
        base: hex(0x6A7182),
        glow: hex(0x8A90A2))
}

/// Shared spring vocabulary. One place to retune the whole feel.
enum Motion {
    static let magnify = Animation.interpolatingSpring(stiffness: 420, damping: 30)
    static let pop = Animation.spring(response: 0.42, dampingFraction: 0.58)
    /// Dot sliding out from behind the notch in hidden mode.
    static let reveal = Animation.spring(response: 0.40, dampingFraction: 0.78)
    /// Hover card opening and closing.
    static let card = Animation.spring(response: 0.34, dampingFraction: 0.82)
    /// The dot stretching into the menu. Slightly slower and better damped than
    /// a normal pop, because the eye is following a shape change rather than a
    /// thing appearing — overshoot here reads as wobble.
    static let morph = Animation.spring(response: 0.38, dampingFraction: 0.86)
}

