import SwiftUI

/// The scoped view that unfolds from the dot.
///
/// Deliberately spare. It answers two questions — who is waiting on you, and
/// what is the rest of the noise — and then gets out of the way. Anything you
/// have already replied to is not here; the right-click menu carries the
/// commands that would otherwise clutter it.
struct HoverCardView: View {
    @ObservedObject var model: NotiflyModel
    @ObservedObject var prefs: Preferences
    let onOpenSettings: () -> Void

    static let width: CGFloat = 316

    private var threads: [DirectThread] { model.cardThreads() }
    private var showsMessages: Bool {
        prefs.isEnabled(.messages) || prefs.isEnabled(.reactions)
    }

    private var activityRows: [KindSummary] {
        model.summaries.filter { !$0.kind.isDirect && $0.count > 0 }
    }

    private var isEmpty: Bool { threads.isEmpty && activityRows.isEmpty }

    /// Square at the top so the card reads as the menu bar continuing downwards
    /// rather than as a floating window laid over it.
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 14,
                               bottomTrailingRadius: 14, topTrailingRadius: 0,
                               style: .continuous)
    }

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
                    .padding(.bottom, 6)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 320)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .background(shape.fill(Palette.card))
        .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 0.5))
        // Softer than a window shadow: enough to lift it off the wallpaper,
        // not enough to read as a separate surface.
        .shadow(color: .black.opacity(0.38), radius: 11, y: 5)
    }

    private var hairline: some View {
        Rectangle().fill(Palette.hairline).frame(height: 0.5).padding(.vertical, 4)
    }

    // MARK: - Header

    /// One line. The split matters — "3 waiting" must never hide the fact that
    /// all three are hearts on something you already sent.
    private var header: some View {
        HStack(spacing: 7) {
            Text(summaryLine)
                .font(.system(size: 11, weight: .medium))
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
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 7)
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
            .font(.system(size: 11))
            .foregroundStyle(Palette.textLo)
            .padding(.horizontal, 12)
            .padding(.bottom, 11)
    }

    private var signInPrompt: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Notifly needs a signed-in Instagram session.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textMid)
                .fixedSize(horizontal: false, vertical: true)
            Button("Sign in…") { model.source.presentLogin() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 11)
    }
}

// MARK: - Rows

private struct ThreadRow: View {
    let thread: DirectThread
    let showPreview: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 8) {
                avatar
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Text(thread.title)
                            .font(.system(size: 11.5, weight: thread.isUnread ? .semibold : .regular))
                            .foregroundStyle(thread.isUnread ? Palette.textHi : Palette.textMid)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(RelativeTime.string(for: thread.date))
                            .font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(Palette.textLo)
                    }
                    if showPreview, !thread.preview.isEmpty {
                        Text(thread.preview)
                            .font(.system(size: 10.5))
                            // A reaction is dimmed and italic: visibly not a
                            // message, before you even read the words.
                            .italic(thread.kind == .reaction)
                            .foregroundStyle(thread.kind == .reaction ? Palette.textLo : Palette.textMid)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(hovering ? Palette.cardRaised : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(AvatarTint.color(for: thread.title).opacity(0.9))
            Text(AvatarTint.initials(for: thread.title))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: 19, height: 19)
        .overlay(alignment: .topTrailing) {
            if thread.isUnread {
                Circle()
                    .fill(Accent.instagram.glow)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().strokeBorder(Palette.card, lineWidth: 1.5))
                    .offset(x: 2, y: -2)
            }
        }
        .padding(.top, 1)
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
                        .font(.system(size: 10))
                        .foregroundStyle(Accent.instagram.glow)
                        .frame(width: 19)
                    Text("\(summary.count) \(summary.kind.title.lowercased())")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textMid)
                    Spacer(minLength: 0)
                    if !samples.isEmpty {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(hovering || expanded ? Palette.textLo : .clear)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(hovering ? Palette.cardRaised : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(samples.prefix(4)) { item in
                        Text(item.text)
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.textLo)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button("Open", action: onOpen).controlSize(.mini)
                        Button("Mark read", action: onMarkRead).controlSize(.mini)
                    }
                    .padding(.top, 1)
                }
                .padding(.horizontal, 12)
                .padding(.leading, 19)
                .padding(.bottom, 6)
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
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(hovering ? Palette.textHi : Palette.textLo)
                .frame(width: 18, height: 16)
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
