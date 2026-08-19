import Foundation
import SwiftUI

/// The buckets Glint counts and shows separately.
///
/// `messages` and `reactions` are deliberately distinct: a reply carries
/// information, a heart tapped on something you already sent does not. Lumping
/// them together is what makes a notification badge untrustworthy.
enum ActivityKind: String, CaseIterable, Identifiable, Codable {
    case messages
    case reactions
    case likes
    case comments
    case follows
    case tags
    case requests

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages:  return "Messages"
        case .reactions: return "Reactions"
        case .likes:     return "Likes"
        case .comments:  return "Comments"
        case .follows:   return "New followers"
        case .tags:      return "Tags & mentions"
        case .requests:  return "Message requests"
        }
    }

    var explanation: String {
        switch self {
        case .messages:  return "Someone actually wrote to you."
        case .reactions: return "Someone reacted to a message you sent."
        case .likes:     return "Likes on your posts and comments."
        case .comments:  return "Comments on your posts."
        case .follows:   return "New followers and follow requests."
        case .tags:      return "You were tagged or mentioned."
        case .requests:  return "Messages from people you don't follow."
        }
    }

    var symbol: String {
        switch self {
        case .messages:  return "bubble.left.fill"
        case .reactions: return "heart.text.square.fill"
        case .likes:     return "heart.fill"
        case .comments:  return "text.bubble.fill"
        case .follows:   return "person.badge.plus.fill"
        case .tags:      return "at"
        case .requests:  return "tray.fill"
        }
    }

    /// The word for one of these, for a line that already names the person:
    /// "2 likes, 1 comment". `title` is a section heading and reads wrong there.
    func shortNoun(count: Int) -> String {
        let one: String
        switch self {
        case .messages:  one = "message"
        case .reactions: one = "reaction"
        case .likes:     one = "like"
        case .comments:  one = "comment"
        case .follows:   one = "follow"
        case .tags:      one = "mention"
        case .requests:  one = "request"
        }
        return count == 1 ? one : one + "s"
    }

    /// Everything except plain messages defaults off, so the dot starts out
    /// meaning "a person wrote to you" and nothing else.
    var defaultEnabled: Bool { self == .messages }

    /// Kinds that come from the direct inbox rather than the activity feed.
    var isDirect: Bool { self == .messages || self == .reactions || self == .requests }
}

/// What the newest entry in a thread actually is.
enum MessageKind: String, Equatable, Codable {
    case text, reaction, media, voice, share, system, other

    var isSubstantive: Bool {
        switch self {
        case .text, .media, .voice, .share: return true
        case .reaction, .system, .other:    return false
        }
    }

    var label: String? {
        switch self {
        case .reaction: return "reaction"
        case .media:    return "photo"
        case .voice:    return "voice"
        case .share:    return "shared"
        default:        return nil
        }
    }
}

/// One unread message inside a conversation.
struct ThreadMessage: Identifiable, Equatable {
    let id: String
    let preview: String
    let kind: MessageKind
    /// A thumbnail on Instagram's CDN, for photos, reels and GIFs. Signed and
    /// short-lived, so it is fetched when the row is drawn and never cached.
    let image: URL?
    let date: Date
}

struct DirectThread: Identifiable, Equatable {
    let id: String
    /// Usernames, already joined for group threads.
    let title: String
    let fullName: String
    let preview: String
    let kind: MessageKind
    let isUnread: Bool
    /// True when the newest entry is one of yours - which is the case for a
    /// reaction, since the reaction sits on your own message.
    let isMine: Bool
    let isGroup: Bool
    let isMuted: Bool
    let date: Date
    /// Everything unread in this conversation, oldest first, capped by the
    /// script. A chat is one row, but a row can hold several messages.
    let messages: [ThreadMessage]
    /// How many were unread before the cap, so the row can say what it is not
    /// showing.
    let unreadCount: Int
    /// The last thing they wrote before you answered, once `answered(upTo:)`
    /// has taken it out of `messages`.
    ///
    /// `preview` cannot stand in for it. That is whatever is newest in the
    /// conversation, and the moment the poll catches up with your reply the
    /// newest thing is your own message - so the row printed the answer as
    /// though they had written it, directly above the copy `SentReplyRow`
    /// draws underneath, and the pair read as the same message twice. Kept
    /// here instead, where trimming still has the real one in hand.
    var answeredMessage: ThreadMessage? = nil

    /// Where clicking this row goes.
    var url: URL? {
        URL(string: "https://www.instagram.com/direct/t/\(id)/")
    }

    /// How many unread messages the row is not showing.
    var hiddenMessages: Int { max(0, unreadCount - messages.count) }

    /// How much this conversation is asking of you, in messages rather than in
    /// conversations. Instagram counts unread *threads*, which is why three
    /// messages from one person used to put a 1 on the dot; what is waiting is
    /// three things to read, whoever wrote them.
    ///
    /// Never zero for an unread thread: where Instagram gives no run to count,
    /// the newest item stands in for it.
    var attentionCount: Int { isUnread ? max(unreadCount, 1) : 0 }

    /// The same conversation with everything you have already answered taken
    /// out of it.
    ///
    /// Replying is not reading - Instagram leaves `last_seen_at` where it was
    /// until you open the thread properly - so the unread run still holds the
    /// message you just answered. Without this, somebody writing again brought
    /// their previous message back onto the card underneath your own reply to
    /// it, which reads as though the answer had not been sent.
    ///
    /// The messages beyond the script's cap are the *oldest* of the run, so a
    /// watermark that falls inside the visible window is past them too, and the
    /// count can be taken from what is left. A watermark older than anything
    /// visible says nothing about them, and the count stands.
    ///
    /// Trimming to nothing also drops `isUnread`. Instagram still calls the
    /// thread unread and will until you open it, but nothing in it is waiting
    /// on you any more, and every count and marker downstream reads that flag
    /// to decide whether something is.
    func answered(upTo when: Date) -> DirectThread {
        let kept = messages.filter { $0.date > when }
        guard kept.count != messages.count else { return self }
        return DirectThread(id: id,
                            title: title,
                            fullName: fullName,
                            preview: preview,
                            kind: kind,
                            isUnread: isUnread && !kept.isEmpty,
                            isMine: isMine,
                            isGroup: isGroup,
                            isMuted: isMuted,
                            date: date,
                            messages: kept,
                            unreadCount: kept.count,
                            // Oldest first, so the newest of the ones being
                            // dropped is the one the answer was answering.
                            answeredMessage: messages.last { $0.date <= when } ?? answeredMessage)
    }

    /// Which bucket this thread counts toward, if unread.
    var bucket: ActivityKind {
        kind == .reaction ? .reactions : .messages
    }

    /// Whether this belongs in the card at all.
    ///
    /// The card is a list of things waiting on you, not a history. Acknowledged
    /// means *seen*: once a thread is read - anywhere, including on a phone -
    /// it is done and disappears, as does anything you answered yourself.
    ///
    /// An earlier version also kept read-but-unanswered threads around for a
    /// week. That was wrong: reading a message on your phone is exactly the
    /// acknowledgement this is supposed to respect, and keeping those rows made
    /// the card a second inbox rather than a to-do list.
    var needsAttention: Bool {
        isUnread && !isMine
    }
}

struct ActivityItem: Identifiable, Equatable {
    let id: String
    let text: String
    /// Who did it. Instagram's `profile_name`, which is the username, so it
    /// compares directly against a one-to-one thread's title.
    let actor: String
    /// Their numeric id, which survives a rename and is what grouping keys on
    /// when it is there.
    let actorID: String
    let kind: ActivityKind
    let isNew: Bool
    let date: Date

    /// What the card shows once the actor's name is already on the row.
    ///
    /// Instagram writes the sentence starting with the username, and repeating
    /// it under a heading of the same name reads as a stutter.
    var detail: String {
        guard !actor.isEmpty, text.lowercased().hasPrefix(actor.lowercased()) else { return text }
        return String(text.dropFirst(actor.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Grouping key: the id when Instagram gave one, the name otherwise.
    var actorKey: String { actorID.isEmpty ? actor.lowercased() : actorID }
}

/// Everything read from Instagram in one poll.
struct InstagramFeed: Equatable {
    var threads: [DirectThread] = []
    var activity: [ActivityItem] = []
    /// Unseen counts straight from the activity endpoint, by kind.
    var activityCounts: [ActivityKind: Int] = [:]
    var pendingRequests: Int = 0
    /// Instagram's own unread-conversation number, kept as a sanity check.
    var unseenDirect: Int = 0

    var unreadThreads: [DirectThread] { threads.filter(\.isUnread) }

    /// Unread threads that are a real message rather than a reaction.
    var unreadMessages: [DirectThread] {
        threads.filter { $0.isUnread && $0.bucket == .messages }
    }

    var unreadReactions: [DirectThread] {
        threads.filter { $0.isUnread && $0.bucket == .reactions }
    }

    func count(for kind: ActivityKind) -> Int {
        switch kind {
        case .messages:  return unreadMessages.count
        case .reactions: return unreadReactions.count
        case .requests:  return pendingRequests
        default:         return activityCounts[kind] ?? 0
        }
    }

    func items(for kind: ActivityKind) -> [ActivityItem] {
        activity.filter { $0.kind == kind }
    }

    /// The number on the dot: only the buckets the user asked to be told about.
    func total(enabled: Set<ActivityKind>) -> Int {
        ActivityKind.allCases
            .filter { enabled.contains($0) }
            .reduce(0) { $0 + count(for: $1) }
    }
}

/// Connection state, kept separate from the feed contents so a transient
/// failure never silently blanks a good set of counts.
enum FeedState: Equatable {
    case loading
    case ready
    case needsAuth
    /// The machine has no route to the internet. Distinct from `failed`, which
    /// is Instagram saying no: one of them is worth a retry button and the
    /// other fixes itself the moment the network comes back.
    case offline
    case failed(String)

    var summary: String {
        switch self {
        case .loading:        return "Connecting…"
        case .ready:          return "Connected"
        case .needsAuth:      return "Sign in required"
        case .offline:        return "Offline"
        case .failed(let why): return "Error: \(why)"
        }
    }
}
