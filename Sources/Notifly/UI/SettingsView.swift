import SwiftUI

struct SettingsView: View {
    @ObservedObject var hub: NotificationHub
    @ObservedObject var prefs: Preferences

    /// Sources publish diagnostics outside the state machine, so nudge the view
    /// on a slow heartbeat rather than wiring up another publisher chain.
    @State private var tick = Date()
    private let heartbeat = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            SourcesTab(hub: hub, prefs: prefs, tick: tick)
                .tabItem { Label("Sources", systemImage: "dot.radiowaves.left.and.right") }
            AppearanceTab(prefs: prefs)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            GeneralTab(prefs: prefs)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(18)
        .frame(width: 580, height: 500)
        .onReceive(heartbeat) { tick = $0 }
    }
}

// MARK: - Sources

private struct SourcesTab: View {
    @ObservedObject var hub: NotificationHub
    @ObservedObject var prefs: Preferences
    let tick: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(SourceKind.allCases) { kind in
                    SourceRow(kind: kind, hub: hub, prefs: prefs, tick: tick)
                    if kind != SourceKind.allCases.last { Divider() }
                }

                Text("""
                Instagram and WhatsApp have no public unread-count API. Notifly keeps a \
                signed-in session for each loaded in the background and reads the same number \
                the browser tab shows you — nothing is sent anywhere else.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            }
            .padding(.trailing, 4)
        }
    }
}

private struct SourceRow: View {
    let kind: SourceKind
    @ObservedObject var hub: NotificationHub
    @ObservedObject var prefs: Preferences
    let tick: Date

    @State private var showExtractor = false
    @State private var draftExtractor = ""

    private var source: (any NotificationSource)? { hub.source(for: kind.rawValue) }
    private var snapshot: SourceSnapshot? { hub.snapshots.first { $0.id == kind.rawValue } }
    private var enabled: Bool { prefs.isEnabled(kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Toggle("", isOn: Binding(get: { prefs.isEnabled(kind) },
                                         set: { prefs.setEnabled(kind, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName).font(.headline)
                    Text(kind.mechanism).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if enabled, let source {
                    StatusPill(state: source.state)
                }
            }

            if enabled, let source {
                Text(source.diagnostics)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    if let remedy = source.remedy {
                        Button(remedy.title) { remedy.perform() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    if let web = source as? WebSource, source.remedy == nil {
                        Button("Sign in…") { web.presentLogin() }
                            .controlSize(.small)
                    }
                    Button("Refresh") { source.refresh() }
                        .controlSize(.small)
                    if let snapshot, snapshot.displayCount > 0 {
                        Button("Mark as read") { hub.markRead(kind.rawValue) }
                            .controlSize(.small)
                    }
                    if let snapshot, snapshot.suppressed > 0 {
                        Button("Unhide \(snapshot.suppressed)") { hub.clearReadMarks() }
                            .controlSize(.small)
                    }
                }
            }

            options
        }
    }

    @ViewBuilder
    private var options: some View {
        switch kind {
        case .whatsapp:
            if enabled {
                Picker("Read from", selection: prefs.binding(\.whatsappMode)) {
                    ForEach(WhatsAppMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .font(.caption)
                extractorEditor
            }
        case .imessage:
            if enabled {
                HStack {
                    Text("Ignore unread older than").font(.caption)
                    Stepper(value: prefs.binding(\.messagesLookbackDays), in: 1...3650, step: 1) {
                        Text("\(Int(prefs.messagesLookbackDays)) days").font(.caption).monospacedDigit()
                    }
                    .labelsHidden()
                    Text("\(Int(prefs.messagesLookbackDays)) days").font(.caption).monospacedDigit()
                }
            }
        case .instagram:
            if enabled { extractorEditor }
        }
    }

    /// Escape hatch: when a site changes its markup, the fix is a few lines of
    /// JavaScript here rather than a new build.
    @ViewBuilder
    private var extractorEditor: some View {
        if kind == .instagram || (kind == .whatsapp && prefs.whatsappMode == .web) {
            DisclosureGroup("Custom extractor (advanced)", isExpanded: $showExtractor) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A JavaScript function expression returning { status, count, method }. Leave empty to use the built-in one.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $draftExtractor)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 110)
                        .border(Color.secondary.opacity(0.3))
                    HStack {
                        Button("Save") {
                            prefs.setCustomExtractor(draftExtractor, for: kind)
                            hub.source(for: kind.rawValue)?.refresh()
                        }
                        .controlSize(.small)
                        Button("Reset to built-in") {
                            draftExtractor = ""
                            prefs.setCustomExtractor(nil, for: kind)
                            hub.source(for: kind.rawValue)?.refresh()
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
            .onAppear { draftExtractor = prefs.customExtractor(for: kind) ?? "" }
        }
    }
}

private struct StatusPill: View {
    let state: SourceState

    var body: some View {
        Text(state.summary)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
            .fixedSize()
    }

    private var tint: Color {
        switch state {
        case .ok(let c): return c > 0 ? .accentColor : .secondary
        case .needsAuth, .needsPermission: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Picker("Position", selection: prefs.binding(\.side)) {
                    ForEach(DockSide.allCases) { Text($0.label).tag($0) }
                }
                slider("Distance from notch", prefs.binding(\.horizontalOffset), 0...80, "pt")
            }

            Section("Dots") {
                slider("Size", prefs.binding(\.dotSize), 8...22, "pt")
                slider("Gap", prefs.binding(\.spacing), 0...24, "pt")
                Toggle("Show the number without hovering", isOn: prefs.binding(\.showCountAtRest))
                Toggle("Hide a dot while it has nothing to report", isOn: prefs.binding(\.hideWhenEmpty))
                Toggle("Ambient breathing on quiet dots", isOn: prefs.binding(\.ambientBreathing))
            }

            Section("Magnification") {
                slider("Maximum scale", prefs.binding(\.maxScale), 1...3, "×", decimals: 2)
                slider("Cursor influence", prefs.binding(\.influenceRadius), 20...200, "pt")
                Text("How far away the cursor starts lifting a dot, and how large it gets directly underneath — the same two numbers the Dock exposes.")
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
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? "dev"
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
                    Slider(value: prefs.binding(\.pollInterval), in: 2...60)
                    Text("\(Int(prefs.pollInterval))s")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Reload web sessions every")
                    Slider(value: prefs.binding(\.webReloadMinutes), in: 2...60)
                    Text("\(Int(prefs.webReloadMinutes))m")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                Text("Faster polling reacts sooner and costs a little more battery. The background pages also push changes the moment they happen, so this is mostly a safety net.")
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
