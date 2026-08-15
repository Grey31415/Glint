import SwiftUI

/// The scoped view that unfolds from the dot.
///
/// Deliberately spare. It answers two questions — who is waiting on you, and
/// what is the rest of the noise — and then gets out of the way. Anything you
/// have already replied to is not here; the right-click menu carries the
/// commands that would otherwise clutter it.
struct HoverCardView: View {
    @ObservedObject var model: GlintModel
    @ObservedObject var prefs: Preferences
    let onOpenSettings: () -> Void

    static let width: CGFloat = 360

    private var threads: [DirectThread] { model.cardThreads() }
    private var showsMessages: Bool {
        prefs.isEnabled(.messages) || prefs.isEnabled(.reactions)
    }

    private var activityRows: [KindSummary] {
        model.summaries.filter { !$0.kind.isDirect && $0.count > 0 }
    }

    private var isEmpty: Bool { threads.isEmpty && activityRows.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if case .needsAuth = model.state {
                signInPrompt
            } else if isEmpty {
                allClear
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if showsMessages {
                            ForEach(threads) { thread in
                                ThreadRow(thread: thread,
                                          showPreview: prefs.showMessagePreviews) {
                                    model.open(thread)
                                }
                            }
                        }
                        if !activityRows.isEmpty {
                            if showsMessages && !threads.isEmpty { hairline }
                            ForEach(activityRows) { summary in
                                ActivityRow(summary: summary,
                                            samples: model.feed.items(for: summary.kind),
                                            onOpen: { model.open(summary.kind) },
                                            onMarkRead: { model.markRead(summary.kind) })
                            }
                        }
                    }
                    .padding(.bottom, 7)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 360)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(width: Self.width, alignment: .leading)
        // No background, border or shadow here: this is the *contents* of the
        // morphing surface, which supplies the glass and the shape.
    }

    private var hairline: some View {
        Rectangle().fill(Palette.hairline).frame(height: 0.5).padding(.vertical, 5)
    }

    // MARK: - Header

    /// One line. The split matters — "3 waiting" must never hide the fact that
    /// all three are hearts on something you already sent.
    private var header: some View {
        HStack(spacing: 8) {
            Text(summaryLine)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.total > 0 ? Palette.textHi : Palette.textLo)
                .lineLimit(1)
            Spacer(minLength: 0)
            if model.total > 0 {
                MiniButton(symbol: "checkmark", help: "Mark all read") { model.markAllRead() }
            } else if model.totalSuppressed > 0 {
                MiniButton(symbol: "arrow.uturn.backward", help: "Undo mark as read") {
                    model.clearReadMarks()
                }
            }
            MiniButton(symbol: "gearshape", help: "Settings", action: onOpenSettings)
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 8)
    }

    private var summaryLine: String {
        switch model.state {
        case .loading where model.feed.threads.isEmpty: return "Connecting…"
        case .needsAuth: return "Signed out"
        case .failed:    return "Can't reach Instagram"
        default:
            guard model.total > 0 else {
                return model.totalSuppressed > 0
                    ? "\(model.totalSuppressed) marked read"
                    : "Nothing waiting"
            }
            return model.summaries
                .filter { $0.count > 0 }
                .map { "\($0.count) \($0.kind.title.lowercased())" }
                .joined(separator: " · ")
        }
    }

    private var allClear: some View {
        Text("You're all caught up.")
            .font(.system(size: 12))
            .foregroundStyle(Palette.textLo)
            .padding(.horizontal, 14)
            .padding(.bottom, 13)
    }

    private var signInPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Glint needs a signed-in Instagram session.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textMid)
                .fixedSize(horizontal: false, vertical: true)
            Button("Sign in…") { model.source.presentLogin() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 13)
    }
}

// MARK: - Rows

private struct ThreadRow: View {
    let thread: DirectThread
    let showPreview: Bool
    let onTap: () -> Void

    @State private var hovering = false

    /// Width reserved for the unread marker. Read rows keep the same gutter so
    /// usernames stay on one vertical line rather than shifting as threads are
    /// read.
    private let gutter: CGFloat = 8

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(thread.isUnread ? Accent.instagram.glow : .clear)
                    .frame(width: gutter, height: gutter)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(thread.title)
                            .font(.system(size: 12.5, weight: thread.isUnread ? .semibold : .regular))
                            .foregroundStyle(thread.isUnread ? Palette.textHi : Palette.textMid)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(RelativeTime.string(for: thread.date))
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(Palette.textLo)
                    }
                    if showPreview, !thread.preview.isEmpty {
                        Text(thread.preview)
                            .font(.system(size: 11.5))
                            // A reaction is dimmed and italic: visibly not a
                            // message, before you even read the words.
                            .italic(thread.kind == .reaction)
                            .foregroundStyle(thread.kind == .reaction ? Palette.textLo : Palette.textMid)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(hovering ? Color.white.opacity(0.10) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ActivityRow: View {
    let summary: KindSummary
    let samples: [ActivityItem]
    let onOpen: () -> Void
    let onMarkRead: () -> Void

    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if samples.isEmpty { onOpen() }
                else { withAnimation(Motion.card) { expanded.toggle() } }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: summary.kind.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(Accent.instagram.glow)
                        .frame(width: 16)
                    Text("\(summary.count) \(summary.kind.title.lowercased())")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textMid)
                    Spacer(minLength: 0)
                    if !samples.isEmpty {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(hovering || expanded ? Palette.textLo : .clear)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(hovering ? Color.white.opacity(0.10) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(samples.prefix(4)) { item in
                        Text(item.text)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textLo)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button("Open", action: onOpen).controlSize(.mini)
                        Button("Mark read", action: onMarkRead).controlSize(.mini)
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 14)
                .padding(.leading, 24)
                .padding(.bottom, 7)
            }
        }
    }
}

private struct MiniButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(hovering ? Palette.textHi : Palette.textLo)
                .frame(width: 20, height: 18)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.12 : 0)))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// Compact relative timestamps: "now", "4m", "2h", "3d".
enum RelativeTime {
    static func string(for date: Date) -> String {
        guard date > .distantPast else { return "" }
        let seconds = Date().timeIntervalSince(date)
        guard seconds >= 0 else { return "now" }
        switch seconds {
        case ..<60:      return "now"
        case ..<3600:    return "\(Int(seconds / 60))m"
        case ..<86_400:  return "\(Int(seconds / 3600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        default:         return "\(Int(seconds / 604_800))w"
        }
    }
}
