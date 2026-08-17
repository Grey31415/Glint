import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: GlintModel
    @ObservedObject var prefs: Preferences

    @State private var tab: SettingsTab = .notifications
    @State private var tick = Date()
    private let heartbeat = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            // Bar and button are one centred row, so adding the button does not
            // shove the tabs off centre.
            HStack(spacing: 8) {
                GlassTabBar(selection: $tab)
                GlassCircleButton(symbol: "power", help: "Quit Glint") {
                    NSApp.terminate(nil)
                }
            }
            .padding(.top, SettingsMetrics.windowPadding)

            // About is short and fixed, so it sits in the space rather than
            // scrolling in it. Inside a ScrollView the content takes its
            // natural height and pins to the top, which left it riding high.
            if tab == .about {
                AboutPane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, SettingsMetrics.windowPadding)
                    .padding(.bottom, SettingsMetrics.windowPadding)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                        switch tab {
                        case .notifications: NotificationsPane(model: model, prefs: prefs, tick: tick)
                        case .appearance:    AppearancePane(prefs: prefs)
                        case .general:       GeneralPane(model: model, prefs: prefs)
                        case .about:         EmptyView()
                        }
                    }
                    .padding(.horizontal, SettingsMetrics.windowPadding)
                    .padding(.bottom, SettingsMetrics.windowPadding)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(width: 580, height: 560)
        .background(VibrantBackground().ignoresSafeArea())
        // Controls pick up the app's own colour rather than the system accent,
        // so a switch in here matches the dot outside.
        .tint(Accent.instagram.glow)
        .onReceive(heartbeat) { tick = $0 }
    }
}

// MARK: - Notifications

private struct NotificationsPane: View {
    @ObservedObject var model: GlintModel
    @ObservedObject var prefs: Preferences
    let tick: Date

    var body: some View {
        GlassSection {
            HStack(alignment: .top, spacing: 12) {
                StatusLight(state: model.state)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.state.summary).font(.system(size: 13, weight: .semibold))
                    Text(model.source.diagnostics)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let last = model.source.lastUpdate {
                        Text("Updated \(RelativeTime.phrase(for: last))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    if let remedy = model.source.remedy {
                        Button(remedy.title) { remedy.perform() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    } else {
                        Button("Sign in…") { model.source.presentLogin() }
                            .controlSize(.small)
                    }
                    Button("Refresh") { model.refresh() }.controlSize(.small)
                }
            }
        }

        GlassSection(title: "Count towards the dot") {
            Note("""
            Everything you switch on is added into the single number on the dot, \
            and listed separately in the menu.
            """)
            ForEach(ActivityKind.allCases) { kind in
                if kind != ActivityKind.allCases.first { Divider().opacity(0.4) }
                KindRow(kind: kind, model: model, prefs: prefs)
            }
        }

        Note("""
        Reactions are kept apart from messages on purpose. A heart on something you \
        sent is not the same as somebody writing to you. The dot stays grey until a \
        real message is waiting.
        """)
        .padding(.horizontal, 2)
    }
}

/// A coloured dot for the connection, the same vocabulary as the dot beside
/// the notch. Reading a status word is slower than reading a colour.
private struct StatusLight: View {
    let state: FeedState

    private var colour: Color {
        switch state {
        case .ready:     return Accent.instagram.glow
        case .loading:   return Palette.textLo
        case .needsAuth: return Palette.warning
        case .failed:    return Palette.warning
        }
    }

    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: 8, height: 8)
            .shadow(color: colour.opacity(0.6), radius: 3)
    }
}

private struct KindRow: View {
    let kind: ActivityKind
    @ObservedObject var model: GlintModel
    @ObservedObject var prefs: Preferences

    private var summary: KindSummary? {
        model.summaries.first { $0.kind == kind }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(get: { prefs.isEnabled(kind) },
                                     set: { prefs.setEnabled(kind, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)

            Image(systemName: kind.symbol)
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(prefs.isEnabled(kind) ? Accent.instagram.glow : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).font(.system(size: 12.5))
                Text(kind.explanation).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let summary, prefs.isEnabled(kind) {
                Text("\(summary.count)")
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(summary.count > 0 ? .primary : .secondary)
                if summary.count > 0 {
                    Button("Mark read") { model.markRead(kind) }.controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        GlassSection(title: "Placement") {
            Toggle("Hidden mode", isOn: prefs.binding(\.hiddenMode))
            Note("""
            Parks the dot inside the notch, where the display has no pixels. It is \
            genuinely invisible. Move the cursor into the notch and it slides out.
            """)
            Divider().opacity(0.4)
            Picker("Position", selection: prefs.binding(\.side)) {
                ForEach(DockSide.allCases) { Text($0.label).tag($0) }
            }
            SettingSlider(title: "Distance from notch",
                          value: prefs.binding(\.horizontalOffset),
                          range: 0...80, unit: "pt")
        }

        GlassSection(title: "Dot") {
            SettingSlider(title: "Size", value: prefs.binding(\.dotSize),
                          range: 8...22, unit: "pt")
            Toggle("Show the number without hovering", isOn: prefs.binding(\.showCountAtRest))
            Toggle("Hide the dot while nothing is waiting", isOn: prefs.binding(\.hideWhenEmpty))
            Divider().opacity(0.4)
            SettingSlider(title: "Hover sensitivity",
                          value: prefs.binding(\.hoverSensitivity),
                          range: 0...90, unit: "pt", zeroLabel: "Touch")
            Note("""
            How close the cursor has to come before the menu opens. Larger reacts from \
            further away. At the lowest setting the cursor has to land on the dot itself.
            """)
        }

        GlassSection(title: "Menu") {
            Toggle("Show details on hover", isOn: prefs.binding(\.showHoverCard))
            Toggle("Include message previews", isOn: prefs.binding(\.showMessagePreviews))
            Note("Previews show the last line of each conversation. Turn them off to see only who wrote.")
        }

        GlassSection(title: "Motion") {
            Toggle("Animations", isOn: prefs.binding(\.animations))
            Note("""
            The colour drifting inside the dot, the menu unfolding, the glow. \
            Off means everything lands at once and nothing moves on its own.
            """)
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var model: GlintModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        GlassSection {
            Toggle("Launch at login", isOn: prefs.binding(\.launchAtLogin))
            Toggle("Play a sound when something new arrives", isOn: prefs.binding(\.playSoundOnNew))
        }

        GlassSection(title: "Polling") {
            SettingSlider(title: "Check every", value: prefs.binding(\.pollInterval),
                          range: 5...120, unit: "s")
            SettingSlider(title: "Reload session every", value: prefs.binding(\.webReloadMinutes),
                          range: 5...60, unit: "m")
        }

        GlassSection(title: "Privacy") {
            LabeledContent("Password") { Text("Never seen by Glint").foregroundStyle(.secondary) }
            LabeledContent("Session stored in") {
                Text("~/Library/WebKit").foregroundStyle(.secondary).textSelection(.enabled)
            }
            LabeledContent("Talks to") {
                Text("instagram.com only").foregroundStyle(.secondary)
            }
            Note("""
            You sign in on Instagram's own page, in the standard macOS web view. Your \
            password goes to Instagram and never through Glint. What is kept is the \
            session cookie, and macOS keeps it, the same way it keeps Safari's. Glint \
            has no account and no server. The only thing it ever sends is a reply you \
            typed yourself. No analytics. No telemetry.
            """)
            HStack {
                Button("Show what Glint is connected to") {
                    NSWorkspace.shared.open(URL(string: "https://www.instagram.com/accounts/access_tool/")!)
                }
                .controlSize(.small)
                Button("Sign out and erase session") { model.source.signOut() }
                    .controlSize(.small)
            }
        }

        GlassSection {
            Button("Quit Glint") { NSApp.terminate(nil) }
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (s?, b?): return "Version \(s) (\(b))"
        case let (s?, nil): return "Version \(s)"
        default: return "Development build"
        }
    }

    /// No card here. Everything else in Settings is a control that benefits
    /// from being grouped, and this is a signature: a box around it just draws
    /// a border round the middle of the window.
    var body: some View {
            VStack(spacing: 0) {
                // Spacers rather than fixed padding, so it stays centred
                // whatever the window height is.
                Spacer(minLength: 0)

                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                    .padding(.bottom, 12)

                Text("Glint")
                    .font(.system(size: 26, weight: .semibold))
                Text("a quieter way to keep up.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)

                // The accent, stated once, where it is decoration rather than
                // information.
                Capsule()
                    .fill(LinearGradient(colors: Accent.instagram.colors,
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 130, height: 3)
                    .padding(.vertical, 16)

                Text(version)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Made in Germany by Greyson Wiesenack")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.top, 8)
                Link("github.com/Grey31415/Glint",
                     destination: URL(string: "https://github.com/Grey31415/Glint")!)
                    .font(.system(size: 12))
                    .padding(.top, 6)
                Text("MIT licensed")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
    }
}
