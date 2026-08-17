import SwiftUI

/// The pieces the Settings window is built from.
///
/// Settings used to speak three layout languages at once: a ScrollView of
/// GroupBoxes, two grouped Forms, and a bare centred stack. Each looked like a
/// different app, and none of them looked like the dot. Everything now sits in
/// the same glass card the overlay uses, so the window and the thing it
/// configures are visibly one object.
enum SettingsMetrics {
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 14
    static let cardSpacing: CGFloat = 14
    static let windowPadding: CGFloat = 18
    /// Height of the tab bar and of the round button beside it. Both derive
    /// from this rather than being eyeballed, so they cannot drift apart.
    static let barHeight: CGFloat = 34
    /// Slack the bar puts around its buttons.
    static let barInset: CGFloat = 3
}

/// Vibrancy for the window behind the cards.
///
/// Glass needs something to be glass against. On a flat grey background the
/// cards read as plain boxes, which is what the old grouped Form already did.
struct VibrantBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// One group of settings, drawn as a single glass card with its title above it.
struct GlassSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { SectionLabel(title) }
            VStack(alignment: .leading, spacing: 11) {
                content()
            }
            .padding(SettingsMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass(shape: shape, tint: .clear, enabled: true)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.rim.opacity(0.16), lineWidth: 0.6))
        }
    }
}

/// The heading above a card. Its own type because not every group is a card -
/// the notification grid is a set of them - and two headings drawn from two
/// copies of the same font call is how they drift apart.
struct SectionLabel: View {
    private let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }
}

/// Explanatory text under a control. Small, quiet, never a wall.
struct Note: View {
    private let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Puts one setting back where it started.
///
/// Keeps its width when there is nothing to undo, rather than appearing and
/// disappearing: a control that shifts the row it lives in every time a slider
/// crosses its default is worse than one that is simply dim.
struct ResetButton: View {
    let changed: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? Color.primary : .secondary)
                .frame(width: 18, height: 16)
                .background(Capsule().fill(hovering ? Palette.rowHover : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Back to the default")
        .opacity(changed ? 1 : 0)
        .disabled(!changed)
        .onHover { hovering = $0 }
    }
}

/// A labelled slider with its value on the right.
struct SettingSlider: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var unit: String = ""
    var decimals: Int = 0
    /// Names the bottom of the range where zero is a distinct behaviour rather
    /// than less of the same. "0pt" says nothing about what zero does.
    var zeroLabel: String?
    /// The value the reset button restores. Compared with a tolerance, because
    /// a slider hands back a continuous number and landing exactly on 15.0 by
    /// dragging is not something to ask of anyone.
    var standard: Double?

    private var changed: Bool {
        guard let standard else { return false }
        return abs(value.wrappedValue - standard) > 0.001
    }

    var body: some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(readout)
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
                .foregroundStyle(.secondary)
            if let standard {
                ResetButton(changed: changed) { value.wrappedValue = standard }
            }
        }
    }

    private var readout: String {
        if let zeroLabel, value.wrappedValue.rounded() == 0 { return zeroLabel }
        return String(format: "%.\(decimals)f\(unit)", value.wrappedValue)
    }
}

/// A colour well with the same reset affordance as a slider.
///
/// `changed` is passed in rather than derived by comparing colours, because one
/// of these has a default that is not a colour at all: the accent's is a
/// five-colour gradient, and picking its pink by hand is not the same as never
/// having chosen.
struct SettingColour: View {
    let title: String
    let value: Binding<Color>
    let changed: Bool
    let reset: () -> Void

    var body: some View {
        HStack {
            ColorPicker(title, selection: value, supportsOpacity: false)
            Spacer(minLength: 0)
            ResetButton(changed: changed, action: reset)
        }
    }
}

/// The four panes, and the glass bar that picks between them.
enum SettingsTab: String, CaseIterable, Identifiable {
    /// General first: it carries the connection, which is the one thing you open
    /// Settings to check when something is wrong.
    case general, notifications, appearance, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notifications: return "Notifications"
        case .appearance:    return "Appearance"
        case .general:       return "General"
        case .about:         return "About"
        }
    }

    var symbol: String {
        switch self {
        case .notifications: return "bell.badge"
        case .appearance:    return "paintbrush"
        case .general:       return "gearshape"
        case .about:         return "info.circle"
        }
    }
}

/// Replaces the stock tab strip. The selected pane gets a tinted glass pill in
/// the app's own accent, so the window is recognisably Glint rather than a
/// default macOS window that happens to belong to it.
struct GlassTabBar: View {
    @Binding var selection: SettingsTab

    private var shape: Capsule { Capsule(style: .continuous) }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                TabButton(tab: tab,
                          selected: selection == tab) {
                    withAnimation(Motion.card) { selection = tab }
                }
            }
        }
        .padding(SettingsMetrics.barInset)
        .liquidGlass(shape: shape, tint: .clear, enabled: true)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.rim.opacity(0.16), lineWidth: 0.6))
    }
}

/// The round button beside the tab bar. Same glass, same height, so the two
/// read as one row rather than a bar with something stuck next to it.
struct GlassCircleButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Palette.warning : Color.secondary)
                .frame(width: SettingsMetrics.barHeight, height: SettingsMetrics.barHeight)
                .background {
                    if hovering { Circle().fill(Palette.rowHover) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .liquidGlass(shape: Circle(), tint: .clear, enabled: true)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Palette.rim.opacity(0.16), lineWidth: 0.6))
    }
}

private struct TabButton: View {
    let tab: SettingsTab
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    private var shape: Capsule { Capsule(style: .continuous) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12, weight: .medium))
                Text(tab.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? Accent.current.glow : Color.secondary)
            .padding(.horizontal, 13)
            .frame(height: SettingsMetrics.barHeight - SettingsMetrics.barInset * 2)
            .background {
                if selected {
                    shape.fill(Accent.current.glow.opacity(0.14))
                } else if hovering {
                    shape.fill(Palette.rowHover)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
