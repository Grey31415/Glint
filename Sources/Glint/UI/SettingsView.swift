import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: GlintModel
    @ObservedObject var prefs: Preferences

    @State private var tick = Date()
    private let heartbeat = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            NotificationsTab(model: model, prefs: prefs, tick: tick)
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
            AppearanceTab(prefs: prefs)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            GeneralTab(model: model, prefs: prefs)
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(18)
        .frame(width: 580, height: 540)
        .onReceive(heartbeat) { tick = $0 }
    }
}

// MARK: - Notifications

private struct NotificationsTab: View {
    @ObservedObject var model: GlintModel
    @ObservedObject var prefs: Preferences
    let tick: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                connection

                Text("Count towards the dot")
                    .font(.headline)

                Text("""
                Everything you switch on is added into the single number on the dot, \
                and listed separately in the hover card.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(ActivityKind.allCases) { kind in
                    KindRow(kind: kind, model: model, prefs: prefs)
                }

                Text("""
                Reactions are kept apart from messages on purpose. A heart on something you \
                sent is not the same as somebody writing to you. The dot stays grey until a \
                real message is waiting.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
            .padding(.trailing, 4)
        }
    }

    private var connection: some View {
        GroupBox {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.state.summary).font(.subheadline).bold()
                    Text(model.source.diagnostics)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let last = model.source.lastUpdate {
                        Text("Updated \(RelativeTime.phrase(for: last))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
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
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { prefs.isEnabled(kind) },
                                     set: { prefs.setEnabled(kind, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)

            Image(systemName: kind.symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).font(.body)
                Text(kind.explanation).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let summary, prefs.isEnabled(kind) {
                Text("\(summary.count)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(summary.count > 0 ? .primary : .secondary)
                if summary.count > 0 {
                    Button("Mark read") { model.markRead(kind) }.controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Hidden mode", isOn: prefs.binding(\.hiddenMode))
                Text("""
                Parks the dot inside the notch, where the display has no pixels. It is \
                genuinely invisible. Move the cursor into the notch and it slides out.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Picker("Position", selection: prefs.binding(\.side)) {
                    ForEach(DockSide.allCases) { Text($0.label).tag($0) }
                }
                slider("Distance from notch", prefs.binding(\.horizontalOffset), 0...80, "pt")
            }

            Section("Dot") {
                slider("Size", prefs.binding(\.dotSize), 8...22, "pt")
                Toggle("Show the number without hovering", isOn: prefs.binding(\.showCountAtRest))
                Toggle("Hide the dot while nothing is waiting", isOn: prefs.binding(\.hideWhenEmpty))
                Toggle("Animations", isOn: prefs.binding(\.animations))
                Text("""
                The colour drifting inside the dot, the menu unfolding, the glow. \
                Off means everything lands at once and nothing moves on its own.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                slider("Hover sensitivity", prefs.binding(\.hoverSensitivity), 0...90, "pt",
                       zeroLabel: "Touch")
                Text("""
                How close the cursor has to come before the menu opens. Larger reacts from \
                further away. At the lowest setting the cursor has to land on the dot itself.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hover card") {
                Toggle("Show details on hover", isOn: prefs.binding(\.showHoverCard))
                Toggle("Include message previews", isOn: prefs.binding(\.showMessagePreviews))
                Text("Previews show the last line of each conversation. Turn them off to see only who wrote.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String,
                        _ value: Binding<Double>,
                        _ range: ClosedRange<Double>,
                        _ unit: String,
                        decimals: Int = 0,
                        zeroLabel: String? = nil) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(readout(value.wrappedValue, unit: unit, decimals: decimals, zeroLabel: zeroLabel))
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    /// "0pt" says nothing about what zero does. Where a slider's bottom end is
    /// a distinct behaviour rather than less of the same, it gets named.
    private func readout(_ value: Double,
                         unit: String,
                         decimals: Int,
                         zeroLabel: String?) -> String {
        if let zeroLabel, value.rounded() == 0 { return zeroLabel }
        return String(format: "%.\(decimals)f\(unit)", value)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var model: GlintModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: prefs.binding(\.launchAtLogin))
                Toggle("Show menu bar item", isOn: prefs.binding(\.showStatusItem))
                Toggle("Play a sound when something new arrives", isOn: prefs.binding(\.playSoundOnNew))
            }

            Section("Polling") {
                HStack {
                    Text("Check every")
                    Slider(value: prefs.binding(\.pollInterval), in: 5...120)
                    Text("\(Int(prefs.pollInterval))s")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Reload session every")
                    Slider(value: prefs.binding(\.webReloadMinutes), in: 5...60)
                    Text("\(Int(prefs.webReloadMinutes))m")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Privacy") {
                LabeledContent("Password") { Text("Never seen by Glint").foregroundStyle(.secondary) }
                LabeledContent("Session stored in") {
                    Text("~/Library/WebKit").foregroundStyle(.secondary).textSelection(.enabled)
                }
                LabeledContent("Talks to") {
                    Text("instagram.com only").foregroundStyle(.secondary)
                }
                Text("""
                You sign in on Instagram's own page, in the standard macOS web view. Your \
                password goes to Instagram and never through Glint. What is kept is the \
                session cookie, and macOS keeps it, the same way it keeps Safari's. Glint \
                has no account and no server. It makes the same two requests the website \
                makes for itself and reads the numbers out. No analytics. No telemetry.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Button("Show what Glint is connected to") {
                        NSWorkspace.shared.open(URL(string: "https://www.instagram.com/accounts/access_tool/")!)
                    }
                    .controlSize(.small)
                    Button("Sign out and erase session") { model.source.signOut() }
                        .controlSize(.small)
                }
            }

            Section {
                Button("Quit Glint") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
    }
}


// MARK: - About

private struct AboutTab: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (s?, b?): return "Version \(s) (\(b))"
        case let (s?, nil): return "Version \(s)"
        default: return "Development build"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .padding(.bottom, 14)

            Text("Glint")
                .font(.system(size: 30, weight: .semibold))
            Text(version)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)

            Text("a quieter way to keep up.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 12)

            Divider()
                .frame(width: 180)
                .padding(.vertical, 16)

            Text("Made in Germany by Greyson Wiesenack")
                .font(.system(size: 13, weight: .medium))

            Link("github.com/Grey31415/Glint",
                 destination: URL(string: "https://github.com/Grey31415/Glint")!)
                .font(.system(size: 12))
                .padding(.top, 8)

            Text("MIT licensed")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
