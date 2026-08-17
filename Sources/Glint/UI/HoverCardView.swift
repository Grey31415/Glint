import SwiftUI

/// The scoped view that unfolds from the dot.
///
/// Deliberately spare. It answers two questions - who is waiting on you, and
/// what is the rest of the noise - and then gets out of the way. Anything you
/// have already replied to is not here; the right-click menu carries the
/// commands that would otherwise clutter it.
struct HoverCardView: View {
    @ObservedObject var model: GlintModel
    @ObservedObject var prefs: Preferences
    let onOpenSettings: () -> Void
    /// When true the rows are laid out without a ScrollView.
    ///
    /// A ScrollView's ideal height along its scroll axis is minimal, so the
    /// invisible copy used to size the morph reported ~65pt however much was in
    /// it, and the menu opened far too short. Measuring the rows directly and
    /// clamping with the same maximum gives the height the real card will take.
    /// Thread whose reply field is open, owned by the controller so the
    /// measuring copy draws it too and the menu grows to fit.
    var composing: String? = nil
    var onCompose: (String?) -> Void = { _ in }
    var measuring: Measuring = .none
    /// The width this copy lays out at. Ignored while measuring width.
    var width: CGFloat = HoverCardView.minWidth

    enum Measuring: Equatable {
        case none
        /// Real height, at the width the menu will use.
        case height
        /// Natural width, unconstrained.
        case width
    }

    /// The menu opens at `minWidth` and only widens for names that would
    /// otherwise truncate. Previews never widen it: they are the one thing long
    /// enough to drag the whole menu open, and clipping one costs nothing.
    static let minWidth: CGFloat = 252
    static let maxWidth: CGFloat = 360
    /// Tallest the rows area is allowed to get before it scrolls.
    static let maxRowsHeight: CGFloat = 360

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
            } else if measuring == .none {
                ScrollView { rows }
                    .scrollIndicators(.never)
                    .frame(maxHeight: Self.maxRowsHeight)
                    .scrollBounceBehavior(.basedOnSize)
            } else {
                rows.frame(maxHeight: Self.maxRowsHeight)
            }
        }
        .frame(width: measuring == .width ? nil : width, alignment: .leading)
        // No background, border or shadow here: this is the *contents* of the
        // morphing surface, which supplies the glass and the shape.
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsMessages {
                ForEach(threads) { thread in
                    ThreadEntry(thread: thread,
                                showPreview: prefs.showMessagePreviews && measuring != .width,
                                // Like previews, answers are dropped while
                                // measuring width: a long one would drag the
                                // whole menu open, and clipping it costs nothing.
                                replies: measuring == .width ? [] : model.replies(to: thread.id),
                                isComposing: composing == thread.id,
                                measuring: measuring != .none,
                                onReply: { onCompose(composing == thread.id ? nil : thread.id) },
                                onTap: { model.open(thread) },
                                onSend: { text in await model.send(text, to: thread) },
                                onClose: { onCompose(nil) })
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

    private var hairline: some View {
        Rectangle().fill(Palette.hairline).frame(height: 0.5).padding(.vertical, 5)
    }

    // MARK: - Header

    /// One line. The split matters - "3 waiting" must never hide the fact that
    /// all three are hearts on something you already sent.
    private var header: some View {
        HStack(spacing: 8) {
            Text(summaryLine)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.total > 0 ? Palette.textHi : Palette.textLo)
                .lineLimit(1)
            Spacer(minLength: 0)
            if model.total > 0 {
                MiniButton(help: "Mark all read", action: { model.markAllRead() }) {
                    Image(systemName: "checkmark").font(.system(size: 10.5, weight: .semibold))
                }
            } else if model.totalSuppressed > 0 {
                MiniButton(help: "Undo mark as read", action: { model.clearReadMarks() }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10.5, weight: .semibold))
                }
            }
            if prefs.showInboxButton {
                MiniButton(help: "Open Instagram messages", action: { model.openInbox() }) {
                    InstagramMark()
                        .stroke(style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
                        .frame(width: 12, height: 12)
                }
            }
            MiniButton(help: "Settings", action: onOpenSettings) {
                Image(systemName: "gearshape").font(.system(size: 10.5, weight: .semibold))
            }
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
            // Short enough to sit on one line at the menu's minimum width. The
            // old wording was 240pt of text in 224pt of space, so it depended
            // on the menu widening to fit it and lost its last word when it
            // did not.
            Text("Glint is signed out of Instagram.")
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

/// A conversation, what you have answered into it, and its reply field, as one
/// object.
///
/// The highlight belongs here rather than on the row. While the field is open
/// the two are one target, and lighting only the row above it made the field
/// look like it belonged to whatever came next. Answers indent under the message
/// for the same reason: the block has to read as one conversation, top to bottom.
private struct ThreadEntry: View {
    let thread: DirectThread
    let showPreview: Bool
    let replies: [SentReply]
    let isComposing: Bool
    let measuring: Bool
    let onReply: () -> Void
    let onTap: () -> Void
    let onSend: (String) async -> SendResult
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThreadRow(thread: thread,
                      showPreview: showPreview,
                      isComposing: isComposing,
                      onReply: onReply,
                      onTap: onTap)

            ForEach(replies) { reply in
                SentReplyRow(reply: reply)
            }

            if isComposing {
                ReplyComposer(thread: thread,
                              measuring: measuring,
                              onSend: onSend,
                              onClose: onClose)
            }
        }
        .background(hovering || isComposing ? Palette.rowHover : .clear)
        .onHover { hovering = $0 }
    }
}

/// The row is no longer one big button.
///
/// It carries two actions now, opening the conversation and opening the reply
/// field, and a button inside a button does not behave on macOS. The text takes
/// a tap gesture and the pen stays a real button.
private struct ThreadRow: View {
    let thread: DirectThread
    let showPreview: Bool
    let isComposing: Bool
    let onReply: () -> Void
    let onTap: () -> Void

    @State private var hovering = false

    /// Width reserved for the unread marker. Read rows keep the same gutter so
    /// usernames stay on one vertical line rather than shifting as threads are
    /// read.
    private let gutter: CGFloat = 8

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(thread.isUnread ? Accent.current.glow : .clear)
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
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)

            ReplyButton(active: isComposing, action: onReply)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

/// What you sent, under what you sent it to.
///
/// Indented to the message's text column and hung off an elbow, so the eye
/// reads the pair as question then answer without needing a label to say so.
/// "you" is still there, quietly, for the case where a thread has collected
/// several answers and the indent alone stops carrying the distinction.
private struct SentReplyRow: View {
    let reply: SentReply

    /// Aligns the elbow's upright with the left edge of the username above:
    /// 14pt of card padding, then the 8pt unread gutter and its 8pt of spacing.
    private let indent: CGFloat = 30

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ReplyElbow()
                .stroke(Accent.current.glow.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .frame(width: 10, height: 11)
                .padding(.top, 1)
            Text("you")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textLo)
            Text(reply.text)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.textMid)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text(RelativeTime.string(for: reply.date))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Palette.textLo)
        }
        .padding(.leading, indent)
        .padding(.trailing, 14)
        .padding(.bottom, 5)
    }
}

/// Down from the message, then a quarter turn into the answer.
///
/// Drawn rather than typed as an arrow glyph: a character would sit on the text
/// baseline and carry its own side bearings, which put the corner in a slightly
/// different place at every font size.
private struct ReplyElbow: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(5, rect.width, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

/// A pen, because it opens somewhere to write. The aeroplane lives in the
/// field, where it does the sending.
///
/// Only conversations get one. The activity rows underneath are likes,
/// comments and follows, which have no thread to reply into.
private struct ReplyButton: View {
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "pencil")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(active ? Accent.current.glow
                                        : (hovering ? Palette.textHi : Palette.textLo))
                .frame(width: 20, height: 18)
                .background(Capsule().fill(hovering && !active ? Palette.rowHover : .clear))
        }
        .buttonStyle(.plain)
        .help(active ? "Close reply" : "Reply")
        .onHover { hovering = $0 }
    }
}

/// The reply field, unfolded under its row.
///
/// One line on purpose. The invisible copy that sizes the menu draws this too,
/// and it can only report the right height if the field's height cannot depend
/// on what has been typed into the real one.
private struct ReplyComposer: View {
    let thread: DirectThread
    /// True in the copy that only exists to be measured. It takes the same
    /// room and must never take focus.
    let measuring: Bool
    let onSend: (String) async -> SendResult
    let onClose: () -> Void

    @State private var draft = ""
    @State private var sending = false
    @State private var note: String?
    @FocusState private var focused: Bool

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSend: Bool { !trimmed.isEmpty && !sending }
    private var field: RoundedRectangle { RoundedRectangle(cornerRadius: 11, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Message \(thread.title)", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textHi)
                    .focused($focused)
                    .disabled(sending || measuring)
                    .onSubmit { if canSend { send() } }

                if sending {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 18, height: 16)
                } else {
                    Button(action: send) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(canSend ? Accent.current.glow : Palette.textLo)
                            .frame(width: 18, height: 16)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .liquidGlass(shape: field,
                         tint: Accent.current.glow.opacity(0.10),
                         enabled: true)
            .clipShape(field)
            .overlay(field.strokeBorder(Palette.rim.opacity(0.22), lineWidth: 0.6))

            if let note {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.warning)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.leading, 16)
        .padding(.bottom, 7)
        .onExitCommand(perform: onClose)
        .onAppear { if !measuring { focused = true } }
    }

    private func send() {
        let text = trimmed
        sending = true
        note = nil
        Task {
            let result = await onSend(text)
            sending = false
            switch result {
            case .sent:
                draft = ""
                onClose()
            case .dryRun(let request):
                draft = ""
                note = "Dry run. Nothing was sent. \(request.prefix(90))"
            case .needsAuth:
                note = "Signed out of Instagram."
            case .failed(let why):
                note = why
            }
        }
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
                        .foregroundStyle(Accent.current.glow)
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
                .background(hovering ? Palette.rowHover : .clear)
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

/// Takes its icon rather than a symbol name, because one of them is not a
/// symbol: SF Symbols carries no brand marks.
private struct MiniButton<Icon: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            icon()
                .foregroundStyle(hovering ? Palette.textHi : Palette.textLo)
                .frame(width: 20, height: 18)
                .background(Capsule().fill(hovering ? Palette.rowHover : .clear))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// The Instagram glyph, drawn as an outline: rounded square, lens, flash.
///
/// A line drawing rather than the real logo. The gradient version is a wordmark
/// that has to be reproduced exactly or not at all, and dropping a saturated
/// badge into a row of hairline glyphs would make it the loudest thing in a menu
/// whose whole point is being quiet.
struct InstagramMark: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2,
                         width: side, height: side).insetBy(dx: side * 0.07, dy: side * 0.07)
        var path = Path()
        path.addRoundedRect(in: box,
                            cornerSize: CGSize(width: side * 0.30, height: side * 0.30),
                            style: .continuous)
        path.addEllipse(in: CGRect(x: box.midX - side * 0.21, y: box.midY - side * 0.21,
                                   width: side * 0.42, height: side * 0.42))
        let flash = side * 0.10
        path.addEllipse(in: CGRect(x: box.maxX - side * 0.30, y: box.minY + side * 0.20,
                                   width: flash, height: flash))
        return path
    }
}

/// Compact relative timestamps: "now", "4m", "2h", "3d".
enum RelativeTime {
    /// The same clock, phrased to stand in a sentence. "now" reads correctly on
    /// its own but not with "ago" after it.
    static func phrase(for date: Date) -> String {
        switch string(for: date) {
        case "":    return "never"
        case "now": return "just now"
        case let stamp: return "\(stamp) ago"
        }
    }

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
