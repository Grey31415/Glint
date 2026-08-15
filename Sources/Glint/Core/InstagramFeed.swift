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

struct DirectThread: Identifiable, Equatable {
    let id: String
    /// Usernames, already joined for group threads.
    let title: String
    let fullName: String
    let preview: String
    let kind: MessageKind
    let isUnread: Bool
    /// True when the newest entry is one of yours — which is the case for a
    /// reaction, since the reaction sits on your own message.
    let isMine: Bool
    let isGroup: Bool
    let isMuted: Bool
    let date: Date

    /// Where clicking this row goes.
    var url: URL? {
        URL(string: "https://www.instagram.com/direct/t/\(id)/")
    }

    /// Which bucket this thread counts toward, if unread.
    var bucket: ActivityKind {
        kind == .reaction ? .reactions : .messages
    }

    /// Whether this belongs in the card at all.
    ///
    /// The card is a list of things waiting on you, not a history. If the
    /// newest entry is yours, you have already replied and the thread is done —
    /// it disappears. Anything unread always stays; a message they sent that
    /// you have read but not answered stays for a while, then ages out.
    func needsAttention(now: Date = Date(), unansweredWindow: TimeInterval = 7 * 86_400) -> Bool {
        if isMine { return false }
        if isUnread { return true }
        guard kind.isSubstantive else { return false }
        return now.timeIntervalSince(date) < unansweredWindow
    }
}

struct ActivityItem: Identifiable, Equatable {
    let id: String
    let text: String
    let kind: ActivityKind
    let isNew: Bool
    let date: Date
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
    case failed(String)

    var summary: String {
        switch self {
        case .loading:        return "Connecting…"
        case .ready:          return "Connected"
        case .needsAuth:      return "Sign in required"
        case .failed(let why): return "Error — \(why)"
        }
    }
}
