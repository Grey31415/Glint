import SwiftUI

/// Notifly renders on top of (and visually out of) the notch, which is black on
/// every machine regardless of appearance. So the palette is deliberately
/// dark-only — it is hardware-matching, not theme-following.
enum Palette {
    static let surface    = Color(red: 0.075, green: 0.076, blue: 0.094)
    static let hairline   = Color.white.opacity(0.14)
    static let idle       = Color(red: 0.40, green: 0.41, blue: 0.48)
    static let textLo     = Color(red: 0.62, green: 0.63, blue: 0.70)
    static let warning    = Color(red: 1.00, green: 0.74, blue: 0.33)
}

/// The colours a lit dot is made of.
///
/// `colors` are painted as soft blobs drifting behind the dot's mask, over a
/// `base` wash. More colours means a richer blend, so a brand with a five-stop
/// gradient can keep all five.
struct Accent: Equatable {
    let colors: [Color]
    /// Fills the whole tile behind the blobs, so there is never a bare patch.
    let base: Color
    /// Outer bloom.
    let glow: Color

    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }

    /// The full Instagram gradient, not just the pink end of it.
    static let instagram = Accent(
        colors: [hex(0xFEDA75),   // yellow
                 hex(0xFA7E1E),   // orange
                 hex(0xD62976),   // magenta
                 hex(0x962FBF),   // purple
                 hex(0x4F5BD5)],  // blue
        base: hex(0xB4287E),
        glow: hex(0xD62976))

    /// Shades of green, deep forest through to light mint.
    ///
    /// Ordered dark-to-light on purpose. Later blobs sit on top, and the
    /// Instagram palette gets away with any order because its colours share a
    /// luminance; these do not, so leading with the dark greens would leave the
    /// tile looking like a black hole.
    static let whatsapp = Accent(
        colors: [hex(0x0A6E3C),
                 hex(0x12A150),
                 hex(0x8BF7B4),
                 hex(0x3DE07A),
                 hex(0x25D366)],
        base: hex(0x16A757),
        glow: hex(0x25D366))

    static let imessage = Accent(
        colors: [hex(0x2E5BFF),
                 hex(0x5B3BFF),
                 hex(0x8FDCFF),
                 hex(0x35B4FF),
                 hex(0x0A84FF)],
        base: hex(0x1470E8),
        glow: hex(0x2E8BFF))

    static let generic = Accent(
        colors: [hex(0xC7CCFF), hex(0x8A94FF), hex(0x5B63E8), hex(0x3F46B8)],
        base: hex(0x5A62DE),
        glow: hex(0x8A94FF))
}

/// Shared spring vocabulary. One place to retune the whole feel.
enum Motion {
    /// Per-dot magnification tracking the cursor.
    static let magnify = Animation.interpolatingSpring(stiffness: 420, damping: 30)
    /// Count changes and dots appearing/disappearing.
    static let pop = Animation.spring(response: 0.42, dampingFraction: 0.58)
}
