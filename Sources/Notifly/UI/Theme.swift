import SwiftUI

/// Notifly renders on top of (and visually out of) the notch, which is black on
/// every machine regardless of appearance. So the palette is deliberately
/// dark-only — it is hardware-matching, not theme-following.
enum Palette {
    static let notch      = Color(red: 0.043, green: 0.043, blue: 0.055)
    static let surface    = Color(red: 0.075, green: 0.076, blue: 0.094)
    static let hairline   = Color.white.opacity(0.10)
    static let idle       = Color(red: 0.40, green: 0.41, blue: 0.48)
    static let textHi     = Color(red: 0.97, green: 0.97, blue: 0.99)
    static let textLo     = Color(red: 0.62, green: 0.63, blue: 0.70)
    static let warning    = Color(red: 1.00, green: 0.74, blue: 0.33)
}

/// A three-stop accent. Rendered as a slowly rotating conic gradient when the
/// source has something to report, which is what gives the dot its life.
struct Accent: Equatable {
    let start: Color
    let mid: Color
    let end: Color

    var stops: [Color] { [start, mid, end, start] }

    /// Colour used for the outer bloom.
    var glow: Color { mid }

    /// Flat fill for small elements where a gradient would just look muddy.
    var flat: Color { mid }

    static let instagram = Accent(
        start: Color(red: 1.00, green: 0.48, blue: 0.27),   // #FF7A45
        mid:   Color(red: 0.95, green: 0.20, blue: 0.50),   // #F2337F
        end:   Color(red: 0.48, green: 0.29, blue: 1.00)    // #7B4BFF
    )

    static let whatsapp = Accent(
        start: Color(red: 0.24, green: 0.88, blue: 0.48),   // #3DE07A
        mid:   Color(red: 0.09, green: 0.76, blue: 0.39),   // #16C264
        end:   Color(red: 0.04, green: 0.62, blue: 0.39)    // #0A9E64
    )

    static let imessage = Accent(
        start: Color(red: 0.35, green: 0.78, blue: 1.00),   // #5AC8FF
        mid:   Color(red: 0.18, green: 0.55, blue: 1.00),   // #2E8BFF
        end:   Color(red: 0.29, green: 0.36, blue: 1.00)    // #4B5BFF
    )

    static let generic = Accent(
        start: Color(red: 0.73, green: 0.75, blue: 1.00),
        mid:   Color(red: 0.54, green: 0.58, blue: 1.00),
        end:   Color(red: 0.42, green: 0.46, blue: 0.94)
    )
}

/// Shared spring vocabulary. One place to retune the whole feel.
enum Motion {
    /// Hover enter/exit of the whole cluster.
    static let hover = Animation.spring(response: 0.32, dampingFraction: 0.72)
    /// Per-dot magnification tracking the cursor.
    static let magnify = Animation.interpolatingSpring(stiffness: 420, damping: 30)
    /// Count changes and dots appearing/disappearing.
    static let pop = Animation.spring(response: 0.42, dampingFraction: 0.58)
    /// Backdrop sliding out of the notch.
    static let curtain = Animation.spring(response: 0.36, dampingFraction: 0.80)
}
