import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: GlintModel
    @ObservedObject var prefs: Preferences

    @State private var tab: SettingsTab = .general
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
                        case .notifications: NotificationsPane(model: model, prefs: prefs)
                        case .composing:     ComposingPane(model: model, prefs: prefs)
                        case .appearance:    AppearancePane(prefs: prefs)
                        case .general:       GeneralPane(model: model, prefs: prefs, tick: tick)
                        case .about:         EmptyView()
                        }
                    }
                    .padding(.horizontal, SettingsMetrics.windowPadding)
                    .padding(.bottom, SettingsMetrics.windowPadding)
                }
                .scrollIndicators(.never)
            }
        }
        // Wide enough for the tab bar to sit at its natural size. Five tabs
        // measure 543pt, and with the quit button and the gap that row wants
        // 585 - more than the 580 the window used to be, so the bar was being
        // squeezed. 660 leaves it room and leaves room for a sixth tab.
        .frame(width: SettingsMetrics.windowWidth, height: 560)
        .background(VibrantBackground().ignoresSafeArea())
        // Controls pick up the app's own colour rather than the system accent,
        // so a switch in here matches the dot outside.
        .tint(Accent.current.glow)
        .onReceive(heartbeat) { tick = $0 }
    }
}

// MARK: - Notifications

private struct NotificationsPane: View {
    @ObservedObject var model: GlintModel
    @ObservedObject var prefs: Preferences

    /// Four columns at the window's width. Adaptive rather than a fixed count so
    /// the grid still lays out if the window ever changes size, and a tighter
    /// gutter than the cards use, because a square this small next to 14pt of
    /// air reads as a gap with tiles in it.
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Count towards the dot")
            Note("""
            Everything you switch on is added into the single number on the dot, \
            and listed separately in the menu. Click a tile to switch it.
            """)
            .padding(.leading, 2)
        }

        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(ActivityKind.allCases) { kind in
                KindTile(kind: kind, model: model, prefs: prefs)
            }
        }

        GlassSection(title: "Conversations") {
            Toggle("Ignore muted conversations", isOn: prefs.binding(\.ignoreMuted))
            Toggle("Ignore group chats", isOn: prefs.binding(\.ignoreGroups))
            if model.totalSuppressed > 0 {
                Divider().opacity(0.4)
                HStack {
                    Text("\(model.totalSuppressed) marked read and hidden")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Show again") { model.clearReadMarks() }.controlSize(.small)
                }
            }
        }
    }
}

/// A coloured dot for the connection, the same vocabulary as the dot beside
/// the notch. Reading a status word is slower than reading a colour.
private struct StatusLight: View {
    let state: FeedState

    private var colour: Color {
        switch state {
        case .ready:     return Accent.current.glow
        case .loading:   return Palette.textLo
        case .needsAuth: return Palette.warning
        case .offline:   return Palette.textLo
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

/// One notification type, as a tile you press.
///
/// This replaced a list of seven rows, each with a switch on the left and a
/// count on the right. That reads as a form to be worked through, and the state
/// of a small toggle is something you have to inspect one row at a time. Here on
/// and off are a colour, so which kinds are live is legible from across the
/// window without reading a single word.
///
/// The whole tile is the control. There is no switch inside it - a button inside
/// a button does not behave on macOS, and a tile that is a target everywhere
/// except one corner is worse than one that is a target nowhere.
private struct KindTile: View {
    let kind: ActivityKind
    @ObservedObject var model: GlintModel
    @ObservedObject var prefs: Preferences

    @State private var hovering = false

    private var on: Bool { prefs.isEnabled(kind) }
    private var count: Int { model.summaries.first { $0.kind == kind }?.count ?? 0 }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
    }

    /// Hover is a stronger wash of whatever the tile already is, rather than a
    /// layer on top: another fill over the glass muddies it, and the lit state
    /// has to stay clearly lit while the cursor is on it.
    private var tint: Color {
        if on { return Accent.current.glow.opacity(hovering ? 0.26 : 0.16) }
        return hovering ? Palette.rowHover : .clear
    }

    var body: some View {
        Button {
            withAnimation(Motion.card) { prefs.setEnabled(kind, !on) }
        } label: {
            // A square reads top to bottom: what it is, then its name, then what
            // it means. The mark and the count share the top line so the two
            // things you scan for are never pushed around by the wording.
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(on ? Accent.current.glow : Color.secondary)
                    Spacer(minLength: 0)
                    if on, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Accent.current.glow))
                    }
                }
                Spacer(minLength: 2)
                Text(kind.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(on ? Color.primary : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(kind.explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .aspectRatio(1, contentMode: .fit)
            .liquidGlass(shape: shape, tint: tint, enabled: true)
            .clipShape(shape)
            .overlay(shape.strokeBorder(on ? Accent.current.glow.opacity(0.45)
                                           : Palette.rim.opacity(0.16),
                                        lineWidth: on ? 1 : 0.6))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(on ? "Counted. Click to stop counting these."
                 : "Not counted. Click to start counting these.")
    }
}

// MARK: - Composing

/// Everything about answering from the menu: which key sends, what happens to
/// what you have not sent, and how much of a conversation the menu shows.
private struct ComposingPane: View {
    @ObservedObject var model: GlintModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        GlassSection(title: "Sending") {
            Picker("Return key", selection: prefs.binding(\.sendOnReturn)) {
                Text("Sends the message").tag(true)
                Text("Starts a new line").tag(false)
            }
            .pickerStyle(.radioGroup)
            Note(prefs.sendOnReturn
                 ? "Shift-Return starts a new line."
                 : "Command-Return or Shift-Return sends.")
        }

        GlassSection(title: "Drafts") {
            Toggle("Keep what you have not sent", isOn: prefs.binding(\.keepDrafts))
            Note("""
            The menu closes when the cursor leaves it, which is easy to do halfway \
            through a sentence. A kept draft is restored when you open the reply field \
            again, and the pen on that conversation is marked until it is sent.
            """)
            if !model.drafts.isEmpty {
                Divider().opacity(0.4)
                HStack {
                    Text("\(model.drafts.count) unsent \(model.drafts.count == 1 ? "draft" : "drafts")")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Discard") { model.clearDrafts() }.controlSize(.small)
                }
            }
        }
        .onChange(of: prefs.keepDrafts) { _, keep in
            // Switching it off has to take the kept drafts with it, or the
            // setting says "stop keeping these" and quietly keeps them.
            if !keep { model.clearDrafts() }
        }

        GlassSection(title: "Messages") {
            Toggle("Include message previews", isOn: prefs.binding(\.showMessagePreviews))
            Toggle("Show photos and reels", isOn: prefs.binding(\.showMediaThumbnails))
            Note("""
            Thumbnails come from Instagram's own image servers, which is one more host \
            than the rest of the app touches. Nothing is written to disk.
            """)
            Divider().opacity(0.4)
            SettingSlider(title: "Keep after replying",
                          value: prefs.binding(\.replyLinger),
                          range: 0...30, unit: " min", decimals: 0,
                          zeroLabel: "Off",
                          standard: Defaults.replyLinger)
            Note("""
            How long a conversation you have answered stays on the menu, with your \
            reply under it. At Off it goes as soon as the send is confirmed - a send \
            that fails keeps it either way.
            """)
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        // Both colours in one place, because the question being answered is the
        // same one: what colour is the dot, waiting or not.
        GlassSection(title: "Colours") {
            SettingColour(title: "Accent colour",
                          value: prefs.binding(\.accentTint),
                          changed: prefs.hasCustomAccent,
                          reset: { prefs.resetAccent() })
            SettingColour(title: "Nothing waiting",
                          value: prefs.binding(\.quietTint),
                          changed: prefs.quietTint.rgb != Defaults.quietTint,
                          reset: { prefs.quietTint = Color(rgb: Defaults.quietTint) })
            Note("""
            The accent is the dot with something waiting on it, and everything in here \
            that is not grey. Reset puts back Instagram's own gradient, which is five \
            colours drifting rather than one.
            """)
        }

        GlassSection(title: "Placement") {
            Toggle("Hidden mode", isOn: prefs.binding(\.hiddenMode))
            Note("Parks the dot inside the notch, where the display has no pixels.")
            Divider().opacity(0.4)
            Picker("Position", selection: prefs.binding(\.side)) {
                ForEach(DockSide.allCases) { Text($0.label).tag($0) }
            }
            SettingSlider(title: "Distance from notch",
                          value: prefs.binding(\.horizontalOffset),
                          range: 0...80, unit: "pt", standard: Defaults.horizontalOffset)
        }

        GlassSection(title: "Dot") {
            SettingSlider(title: "Size", value: prefs.binding(\.dotSize),
                          range: 8...22, unit: "pt", standard: Defaults.dotSize)
            Toggle("Show the number without hovering", isOn: prefs.binding(\.showCountAtRest))
            Toggle("Hide the dot while nothing is waiting", isOn: prefs.binding(\.hideWhenEmpty))
            Divider().opacity(0.4)
            SettingSlider(title: "Glassiness", value: prefs.binding(\.dotGlassiness),
                          range: 0...100, unit: "%", zeroLabel: "Solid",
                          standard: Defaults.dotGlassiness)
            Divider().opacity(0.4)
            SettingSlider(title: "Hover sensitivity",
                          value: prefs.binding(\.hoverSensitivity),
                          range: 0...90, unit: "pt", zeroLabel: "Touch",
                          standard: Defaults.hoverSensitivity)
            // Kept because the number says points and means patience: at the
            // bottom of the range the cursor has to land on the dot itself.
            Note("How close the cursor has to come before the menu opens.")
        }

        GlassSection(title: "Menu") {
            Toggle("Show details on hover", isOn: prefs.binding(\.showHoverCard))
            Toggle("Button for the Instagram inbox", isOn: prefs.binding(\.showInboxButton))
            Toggle("Colour glow in the menu", isOn: prefs.binding(\.menuGlow))
        }

        GlassSection(title: "Motion") {
            Toggle("Animations", isOn: prefs.binding(\.animations))
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var model: GlintModel
    @ObservedObject var prefs: Preferences
    /// Ticks so "Updated 4m ago" stays true while the window sits open.
    let tick: Date

    /// Wall-clock time of the last sync, next to the relative one. "4m ago" is
    /// the answer to "is it working"; the clock is the answer to "when did it
    /// stop", and the two questions get asked together.
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f
    }()

    /// Signed out is the one state with nothing to refresh, nothing to erase and
    /// no account to inspect, so it is the only one that changes the row.
    private var signedIn: Bool { model.state != .needsAuth }

    /// Every action the connection has, in one row, showing only what applies.
    ///
    /// `remedy` leads when there is one: it is the same button whether the fix
    /// is signing in or retrying a failed poll, and it is the thing to press.
    private var actions: some View {
        HStack(spacing: 8) {
            if let remedy = model.source.remedy {
                Button(remedy.title) { remedy.perform() }
                    .buttonStyle(.borderedProminent)
            }
            if signedIn {
                Button("Refresh") { model.refresh() }
                Button("Show what Glint is connected to") {
                    NSWorkspace.shared.open(URL(string: "https://www.instagram.com/accounts/access_tool/")!)
                }
            }
            Spacer(minLength: 0)
            if signedIn {
                Button("Sign out and erase session") { model.source.signOut() }
            }
        }
        .controlSize(.small)
    }

    var body: some View {
        GlassSection(title: "Application") {
            Toggle("Launch at login", isOn: prefs.binding(\.launchAtLogin))
            Toggle("Open the menu with \u{2325}G", isOn: prefs.binding(\.hotkeyEnabled))
            // The switch, which sound, and hearing it: one row, because they are
            // one decision.
            HStack(spacing: 8) {
                Toggle("Play a sound when something new arrives", isOn: prefs.binding(\.playSoundOnNew))
                Spacer(minLength: 0)
                Picker("", selection: prefs.binding(\.alertSound)) {
                    ForEach(AlertSounds.names, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 130)
                // Dimmed one control at a time. Disabling the row would take the
                // switch with it, and a switch that cannot be switched back on
                // is a trap.
                .disabled(!prefs.playSoundOnNew)
                // Picking one plays it. Choosing a sound you cannot hear is
                // choosing a word from a list, which is not the same thing.
                .onChange(of: prefs.alertSound) { _, _ in GlintModel.arrivalSound() }
                // Plays whatever an arrival would play, rather than a sound named
                // again here: two places naming a sound is how they end up being
                // different sounds.
                Button {
                    GlintModel.arrivalSound()
                } label: {
                    Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                }
                .controlSize(.small)
                .help("Hear it")
                .disabled(!prefs.playSoundOnNew)
            }
        }

        GlassSection(title: "Menu size") {
            SettingSlider(title: "Width", value: prefs.binding(\.menuWidth),
                          range: 200...480, unit: "pt", standard: Defaults.menuWidth)
            SettingSlider(title: "Height", value: prefs.binding(\.menuHeight),
                          range: 160...720, unit: "pt", standard: Defaults.menuHeight)
            Note("""
            Width is a floor: a long name still stretches the menu past it. Height is \
            a ceiling: more rows than fit will scroll inside it.
            """)
        }

        GlassSection(title: "Polling") {
            SettingSlider(title: "Check every", value: prefs.binding(\.pollInterval),
                          range: 5...120, unit: "s", standard: Defaults.pollInterval)
            SettingSlider(title: "Reload session every", value: prefs.binding(\.webReloadMinutes),
                          range: 5...60, unit: "m", standard: Defaults.webReloadMinutes)
        }

        // The privacy facts sit in this card rather than their own: they answer
        // "what is this connected to", which is the same question the status
        // line answers, and a separate box made them read as a disclaimer.
        GlassSection(title: "Connection") {
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
                    // Named rather than implied. "Updated 4m ago" reads as a
                    // note; "Last successful sync" is the thing you came here
                    // to check when the dot looks wrong.
                    HStack(spacing: 5) {
                        Text("Last successful sync: " + (model.source.lastUpdate.map {
                            "\(Self.clock.string(from: $0)) · \(RelativeTime.phrase(for: $0))"
                        } ?? "never"))
                        if model.source.isStale {
                            Text("· overdue").foregroundStyle(Palette.warning)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            Divider().opacity(0.4)
            Note("""
            Your password never goes through Glint, nothing but instagram.com is \
            contacted, and the session lives in ~/Library/WebKit.
            """)
            .textSelection(.enabled)
            actions
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
                    .fill(LinearGradient(colors: Accent.current.colors,
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
