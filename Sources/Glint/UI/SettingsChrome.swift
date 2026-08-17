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
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
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

    var body: some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(readout)
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    private var readout: String {
        if let zeroLabel, value.wrappedValue.rounded() == 0 { return zeroLabel }
        return String(format: "%.\(decimals)f\(unit)", value.wrappedValue)
    }
}

/// The four panes, and the glass bar that picks between them.
enum SettingsTab: String, CaseIterable, Identifiable {
    case notifications, appearance, general, about

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
        .padding(3)
        .liquidGlass(shape: shape, tint: .clear, enabled: true)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.rim.opacity(0.16), lineWidth: 0.6))
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
            .foregroundStyle(selected ? Accent.instagram.glow : Color.secondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background {
                if selected {
                    shape.fill(Accent.instagram.glow.opacity(0.14))
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
