import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: NotiflyModel
    @ObservedObject var prefs: Preferences

    @State private var tick = Date()
    private let heartbeat = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            NotificationsTab(model: model, prefs: prefs, tick: tick)
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
            AppearanceTab(prefs: prefs)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            GeneralTab(prefs: prefs)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(18)
        .frame(width: 580, height: 540)
        .onReceive(heartbeat) { tick = $0 }
    }
}

// MARK: - Notifications

private struct NotificationsTab: View {
    @ObservedObject var model: NotiflyModel
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
                Reactions are kept apart from messages on purpose. A heart on something \
                you already sent is not the same as somebody writing to you, and the dot \
                stays grey unless there is a real message waiting.
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
                        Text("Updated \(RelativeTime.string(for: last)) ago")
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
    @ObservedObject var model: NotiflyModel
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
                Parks the dot inside the notch — a part of the display with no pixels — \
                so it is genuinely invisible. Move the cursor into the notch and it slides \
                out. For when you would rather not know.
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
                Toggle("Ambient breathing when quiet", isOn: prefs.binding(\.ambientBreathing))
                slider("Maximum scale", prefs.binding(\.maxScale), 1...3, "×", decimals: 2)
                slider("Cursor influence", prefs.binding(\.influenceRadius), 20...200, "pt")
            }

            Section("Hover card") {
                Toggle("Show details on hover", isOn: prefs.binding(\.showHoverCard))
                Toggle("Include message previews", isOn: prefs.binding(\.showMessagePreviews))
                Text("Previews show the last line of each conversation. Turn them off if you would rather only see who wrote.")
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
                        decimals: Int = 0) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(String(format: "%.\(decimals)f\(unit)", value.wrappedValue))
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var prefs: Preferences

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

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
                Text("""
                Notifly reads your own signed-in instagram.com session, in the background, \
                on this machine. The same requests the website makes for itself. Nothing is \
                sent anywhere else and nothing is stored beyond what WebKit keeps for the \
                session.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Notifly", value: version)
                Button("Quit Notifly") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
    }
}
