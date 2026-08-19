import AppKit
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

    /// One row per correspondent: their conversation and their activity
    /// together.
    private var entries: [GlintModel.CardEntry] { model.cardEntries() }

    /// Counts with nobody to attribute them to. Instagram badges a category
    /// without always saying who is behind it, and that number has to stay on
    /// the card or it stops agreeing with the dot.
    private var activityRows: [KindSummary] { model.unattributedActivity() }

    private var isEmpty: Bool { entries.isEmpty && activityRows.isEmpty }

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
            syncLine
        }
        .frame(width: measuring == .width ? nil : width, alignment: .leading)
        // No background, border or shadow here: this is the *contents* of the
        // morphing surface, which supplies the glass and the shape.
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                if let thread = entry.thread {
                    ThreadEntry(thread: thread,
                                stored: model.draft(for: thread.id),
                                sendOnReturn: prefs.sendOnReturn,
                                onDraft: { model.setDraft($0, for: thread.id) },
                                // Never while measuring width: an image that
                                // has not arrived yet is a different size from
                                // one that has, and the menu would settle on
                                // whichever the measuring copy saw first.
                                showThumbnails: prefs.showMediaThumbnails && measuring == .none,
                                activity: entry.activity,
                                activityLine: entry.activityLine,
                                showPreview: prefs.showMessagePreviews && measuring != .width,
                                // Like previews, answers are dropped while
                                // measuring width: a long one would drag the
                                // whole menu open, and clipping it costs nothing.
                                replies: measuring == .width ? [] : model.replies(to: thread.id),
                                isComposing: composing == thread.id,
                                measuring: measuring != .none,
                                onReply: { onCompose(composing == thread.id ? nil : thread.id) },
                                onTap: { model.open(thread) },
                                onOpenActivity: { model.open(entry.activity.first?.kind ?? .likes) },
                                onSend: { text in await model.send(text, to: thread) },
                                onClose: { onCompose(nil) })
                } else {
                    ActorRow(entry: entry,
                             showDetail: measuring != .width,
                             onOpen: { model.open(entry.kinds.first ?? .likes) })
                }
            }
            if !activityRows.isEmpty {
                if !entries.isEmpty { hairline }
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

    /// When Glint last actually heard from Instagram.
    ///
    /// The counts are only ever as good as the last poll, and every failure
    /// mode short of signing out used to keep the last good numbers on screen
    /// and say nothing - a dot that has been wrong for an hour looks exactly
    /// like a dot that is right. Quiet while everything is current; the line
    /// speaks up when it is not.
    @ViewBuilder
    private var syncLine: some View {
        let stale = model.source.isStale
        let offline = model.state == .offline
        if offline || stale || model.source.lastUpdate == nil {
            HStack(spacing: 5) {
                Image(systemName: offline ? "wifi.slash" : "clock.arrow.circlepath")
                    .font(.system(size: 9))
                Text(offline ? "Offline · last synced \(lastSyncPhrase)"
                             : "Last synced \(lastSyncPhrase)")
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(offline ? Palette.warning : Palette.textLo)
            .padding(.horizontal, 14)
            .padding(.bottom, 9)
        }
    }

    private var lastSyncPhrase: String {
        guard let last = model.source.lastUpdate else { return "never" }
        return RelativeTime.phrase(for: last)
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
    /// The unsent message for this thread, if there is one.
    let stored: String
    let sendOnReturn: Bool
    let onDraft: (String) -> Void
    let showThumbnails: Bool
    /// What this person has also done outside the conversation.
    let activity: [ActivityItem]
    let activityLine: String
    let showPreview: Bool
    let replies: [SentReply]
    let isComposing: Bool
    let measuring: Bool
    let onReply: () -> Void
    let onTap: () -> Void
    let onOpenActivity: () -> Void
    let onSend: (String) async -> SendResult
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThreadRow(thread: thread,
                      showPreview: showPreview,
                      showThumbnails: showThumbnails,
                      isComposing: isComposing,
                      hasDraft: !stored.isEmpty,
                      onReply: onReply,
                      onTap: onTap)

            if !activity.isEmpty {
                ActivitySuffix(kinds: activity.map(\.kind), line: activityLine, onTap: onOpenActivity)
            }

            ForEach(replies) { reply in
                SentReplyRow(reply: reply)
            }

            if isComposing {
                ReplyComposer(thread: thread,
                              measuring: measuring,
                              stored: stored,
                              sendOnReturn: sendOnReturn,
                              onDraft: onDraft,
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
    let showThumbnails: Bool
    let isComposing: Bool
    /// Something typed here and not sent. Worth a mark, or a kept draft is a
    /// secret.
    let hasDraft: Bool
    let onReply: () -> Void
    let onTap: () -> Void

    @State private var hovering = false

    /// Width reserved for the unread marker. Read rows keep the same gutter so
    /// usernames stay on one vertical line rather than shifting as threads are
    /// read.
    private let gutter: CGFloat = 8

    /// The lines under the name.
    ///
    /// `messages` is empty for a thread that is not waiting on you - one you
    /// have answered, which lingers on the card for five minutes - so a single
    /// line stands in there and the row looks exactly as it did.
    ///
    /// Which line matters. For a thread you answered it has to be the message
    /// you answered, kept aside before the trim, because `preview` is the
    /// newest item in the conversation and by the next poll that is your own
    /// reply - printed as theirs, above `SentReplyRow` printing it again.
    /// `isMine` catches the same thing for a thread answered somewhere else.
    private var previews: [ThreadMessage] {
        if !thread.messages.isEmpty { return thread.messages }
        if let answered = thread.answeredMessage { return [answered] }
        guard !thread.isMine, !thread.preview.isEmpty else { return [] }
        return [ThreadMessage(id: thread.id, preview: thread.preview, kind: thread.kind,
                              image: nil, date: thread.date)]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(thread.isUnread ? Accent.current.glow : .clear)
                .frame(width: gutter, height: gutter)
                .padding(.top, 4)
            // Two, not one: a row can now carry several message lines, and at
            // one point they read as a wrapped paragraph rather than as
            // separate messages.
            VStack(alignment: .leading, spacing: 2) {
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
                if showPreview {
                    // Every unread message, oldest first, rather than the
                    // newest one standing in for all of them. Two people
                    // writing one line each and one person writing four are
                    // different situations and the card used to show them
                    // identically.
                    ForEach(previews) { message in
                        Text(message.preview)
                            .font(.system(size: 11.5))
                            // A reaction is dimmed and italic: visibly not a
                            // message, before you even read the words.
                            .italic(message.kind == .reaction)
                            .foregroundStyle(message.kind == .reaction ? Palette.textLo : Palette.textMid)
                            .lineLimit(1)
                            // Right-click rather than a button: the row is
                            // already carrying two actions, and a third
                            // control on every line would make a list of
                            // messages look like a toolbar.
                            .contextMenu {
                                Button("Copy message") { Pasteboard.copy(message.preview) }
                                Button("Copy conversation") {
                                    Pasteboard.copy(previews.map(\.preview).joined(separator: "\n"))
                                }
                            }
                        if showThumbnails, let image = message.image {
                            Thumbnail(url: image)
                        }
                    }
                    if thread.hiddenMessages > 0 {
                        Text("+\(thread.hiddenMessages) more")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textLo)
                    }
                } else if thread.unreadCount > 1 {
                    // With previews switched off the count is the only way the
                    // row can say there is more than one.
                    Text("\(thread.unreadCount) messages")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.textLo)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)

            ReplyButton(active: isComposing, hasDraft: hasDraft, action: onReply)
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
    var hasDraft: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: hasDraft && !active ? "pencil.line" : "pencil")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(active || hasDraft ? Accent.current.glow
                                                    : (hovering ? Palette.textHi : Palette.textLo))
                .frame(width: 20, height: 18)
                .background(Capsule().fill(hovering && !active ? Palette.rowHover : .clear))
        }
        .buttonStyle(.plain)
        .help(active ? "Close reply" : (hasDraft ? "Unsent draft" : "Reply"))
        .onHover { hovering = $0 }
    }
}

/// The reply field, unfolded under its row.
///
/// It used to be one line on purpose: the invisible copy that sizes the menu
/// draws this too, and a field whose height depended on what had been typed
/// into the real one would have measured the menu wrong. Now that drafts live
/// in the model rather than in this view's state, both copies render the same
/// text and the menu grows with it, which is what makes several lines possible
/// at all.
private struct ReplyComposer: View {
    let thread: DirectThread
    /// True in the copy that only exists to be measured. It takes the same
    /// room and must never take focus.
    let measuring: Bool
    /// What was typed and not sent, restored from the model.
    let stored: String
    /// Whether Return sends or starts a new line.
    let sendOnReturn: Bool
    let onDraft: (String) -> Void
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
                TextField("Message \(thread.title)", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textHi)
                    .lineLimit(1...4)
                    .focused($focused)
                    .disabled(sending || measuring)
                    .onSubmit { if sendOnReturn, canSend { send() } }
                    // Only the inverted mode is intercepted. Left alone, a
                    // vertical field already does the messaging idiom - Return
                    // submits, Shift-Return breaks the line - so handling that
                    // case here would be reimplementing what works.
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard !sendOnReturn else { return .ignored }
                        if press.modifiers.contains(.command) || press.modifiers.contains(.shift) {
                            if canSend { send() }
                            return .handled
                        }
                        return .ignored
                    }

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
        .onAppear {
            draft = stored
            if !measuring { focused = true }
        }
        // The model owns the text, so it survives the menu closing - which is
        // easy to do by accident, the menu being a thing you leave by moving
        // the cursor. It is also what lets the measuring copy render the same
        // number of lines as the real field.
        .onChange(of: draft) { _, new in if !measuring { onDraft(new) } }
        // The other direction, for the copy that only measures: it has to
        // follow what is being typed into the real field or the menu stops
        // growing after the first line.
        .onChange(of: stored) { _, new in if measuring { draft = new } }
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
                onDraft("")
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

/// A person's activity hung under their conversation.
///
/// Indented to the message's text column, like a sent reply, so the block reads
/// as one person rather than as a second row that happens to follow. Quiet on
/// purpose: somebody writing to you and somebody liking a photo are not the
/// same news, and merging them by author must not flatten that.
private struct ActivitySuffix: View {
    let kinds: [ActivityKind]
    let line: String
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: kinds.first?.symbol ?? "heart.fill")
                .font(.system(size: 9))
                .foregroundStyle(Palette.textLo)
            Text(line)
                .font(.system(size: 11))
                .foregroundStyle(hovering ? Palette.textMid : Palette.textLo)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        // 14 of row padding, 8 of marker, 8 of gap: the text column.
        .padding(.leading, 30)
        .padding(.trailing, 14)
        .padding(.bottom, 5)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
    }
}

/// Somebody who is only in your notifications - no conversation, just things
/// they did. Same shape as a thread row so the list stays one list, with the
/// unread marker hollowed out because nothing here is waiting on a reply.
private struct ActorRow: View {
    let entry: GlintModel.CardEntry
    let showDetail: Bool
    let onOpen: () -> Void

    @State private var hovering = false

    private let gutter: CGFloat = 8

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.kinds.first?.symbol ?? "heart.fill")
                .font(.system(size: 9.5))
                .foregroundStyle(Accent.current.glow.opacity(0.85))
                .frame(width: gutter, height: gutter)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.textMid)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(RelativeTime.string(for: entry.date))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(Palette.textLo)
                }
                if showDetail {
                    Text(entry.activityLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.textLo)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(hovering ? Palette.rowHover : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
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
/// A photo, reel or GIF, small.
///
/// Fetched straight from Instagram's CDN on the signed URL the inbox handed
/// over. Nothing is cached to disk and nothing is drawn until it arrives - a
/// placeholder box that may never fill is worse than no box, because it says
/// something is coming.
private struct Thumbnail: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 84, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Palette.rim.opacity(0.18), lineWidth: 0.6))
                    .padding(.top, 2)
            }
        }
    }
}

/// One place that writes to the clipboard, so "copy" means the same thing
/// wherever it is offered.
enum Pasteboard {
    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}

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
