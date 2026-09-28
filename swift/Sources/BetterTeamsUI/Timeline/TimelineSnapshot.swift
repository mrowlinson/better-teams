// TimelineSnapshot.swift — pure map from store messages to timeline
// rows (UI-SPEC §6.2.1). Sender runs within 5 min share one header.
// Updates diff by item ID; `revision` changes whenever a row's rendered
// content (and so its height) can change. Channel posts group by
// `reply_to` (§6.3): the Posts scope shows root posts, each followed by
// a thread summary row; the thread scope shows one root and its replies.
import Foundation
import OstMacCore

public enum TimelineItem: Hashable, Sendable {
    case daySeparator(key: String, label: String)
    case newMessagesDivider
    case message(id: String, revision: Int, showsHeader: Bool)
    case typing
    /// Under a channel root post: "N replies" / "Reply" (§6.3).
    case threadSummary(rootID: String, replies: Int, lastReply: String?)

    /// Stable row identity (R4).
    public var id: String {
        switch self {
        case .daySeparator(let key, _): "day:\(key)"
        case .newMessagesDivider: "new"
        case .message(let id, _, _): "msg:\(id)"
        case .typing: "typing"
        case .threadSummary(let root, _, _): "thread:\(root)"
        }
    }

    public var revision: Int {
        switch self {
        case .daySeparator(_, let label): label.hashValue & 0x7fff_ffff
        case .newMessagesDivider, .typing: 0
        case .message(_, let r, _): r
        case .threadSummary(_, let n, let last): (n &* 31 &+ (last?.count ?? 0)) & 0x7fff_ffff
        }
    }

    public var messageID: String? {
        if case .message(let id, _, _) = self { return id }
        return nil
    }
}

public enum TimelineSnapshot {
    /// Grouping window for one header.
    public static let groupWindow: TimeInterval = 5 * 60

    public static func items(
        messages: [ChatMessage], failed: Set<String>, firstUnreadID: String? = nil,
        typing: Bool = false, dayKey: (String) -> String = { MessageRender.dayKey($0) },
        dayLabel: (String) -> String = { MessageRender.dayLabel($0) }
    ) -> [TimelineItem] {
        var out: [TimelineItem] = []
        out.reserveCapacity(messages.count + 4)
        var lastDay: String?
        var prev: ChatMessage?
        for m in messages {
            let day = dayKey(m.timestamp)
            var newDay = false
            if day != lastDay {
                out.append(.daySeparator(key: day, label: dayLabel(day)))
                lastDay = day
                newDay = true
            }
            if let firstUnreadID, m.id == firstUnreadID {
                out.append(.newMessagesDivider)
                newDay = true
            }
            let header = newDay || !continues(prev, m)
            out.append(.message(id: m.id, revision: revision(m, failed: failed.contains(m.id), header: header),
                                showsHeader: header))
            prev = m
        }
        if typing { out.append(.typing) }
        return out
    }

    /// Same sender within the grouping window.
    static func continues(_ a: ChatMessage?, _ b: ChatMessage) -> Bool {
        guard let a, a.sender == b.sender, a.isOwn == b.isOwn,
              let ta = TeamsTime.parseISO(a.timestamp), let tb = TeamsTime.parseISO(b.timestamp)
        else { return false }
        return abs(tb.timeIntervalSince(ta)) <= groupWindow
    }

    /// Stable content revision (FNV-1a; never `hashValue`, which is
    /// seeded per process).
    public static func revision(_ m: ChatMessage, failed: Bool, header: Bool) -> Int {
        var h: UInt64 = 14_695_981_039_346_656_037
        func mix(_ s: String) {
            for b in s.utf8 { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
            h = (h ^ 0xff) &* 1_099_511_628_211
        }
        mix(m.content)
        mix(m.sender)
        mix(m.timestamp)
        mix(m.reply_to ?? "")
        mix(m.reactions.map { "\($0)" }.joined(separator: ","))
        mix("\(m.edited)\(m.deleted)\(failed)\(header)\(m.isOwn)")
        return Int(truncatingIfNeeded: h & 0x7fff_ffff_ffff_ffff)
    }
}

/// What a timeline shows (§6.2.1, §6.3).
public enum TimelineScope: Hashable, Sendable {
    /// Every message (chats).
    case conversation
    /// Channel Posts tab: root posts + thread summary rows.
    case posts
    /// One channel thread: the root post and its replies.
    case thread(rootID: String)

    var isThread: Bool {
        if case .thread = self { return true }
        return false
    }
}

/// Channel threads mined from `reply_to` (§6.3). A reply whose parent is
/// not loaded shows as its own post (flat fallback, never hidden).
public struct ChannelThreads: Equatable, Sendable {
    public var roots: [ChatMessage]
    public var replies: [String: [ChatMessage]]

    public init(_ messages: [ChatMessage]) {
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var roots: [ChatMessage] = []
        var replies: [String: [ChatMessage]] = [:]
        for m in messages {
            if let root = Self.root(of: m, in: byID), root != m.id {
                replies[root, default: []].append(m)
            } else {
                roots.append(m)
            }
        }
        self.roots = roots
        self.replies = replies
    }

    /// The loaded root a message belongs to (its own id for roots and
    /// orphans). Follows parents up to 16 hops; cycles stop at the start.
    public static func root(of m: ChatMessage, in byID: [String: ChatMessage]) -> String? {
        var current = m
        var seen: Set<String> = [m.id]
        for _ in 0..<16 {
            guard let p = current.reply_to?.trimmingCharacters(in: .whitespaces), !p.isEmpty,
                  let parent = byID[p], seen.insert(p).inserted
            else { break }
            current = parent
        }
        return current.id
    }
}

public extension TimelineSnapshot {
    /// Scoped rows: chats use `items(messages:)`; Posts and Thread group
    /// channel messages by `reply_to`.
    static func items(
        messages: [ChatMessage], failed: Set<String>, scope: TimelineScope,
        dayKey: (String) -> String = { MessageRender.dayKey($0) },
        dayLabel: (String) -> String = { MessageRender.dayLabel($0) }
    ) -> [TimelineItem] {
        switch scope {
        case .conversation:
            return items(messages: messages, failed: failed, dayKey: dayKey, dayLabel: dayLabel)
        case .thread(let rootID):
            let t = ChannelThreads(messages)
            guard let root = t.roots.first(where: { $0.id == rootID }) else { return [] }
            return items(messages: [root] + (t.replies[rootID] ?? []), failed: failed,
                         dayKey: dayKey, dayLabel: dayLabel)
        case .posts:
            let t = ChannelThreads(messages)
            var out: [TimelineItem] = []
            var lastDay: String?
            for m in t.roots {
                let day = dayKey(m.timestamp)
                if day != lastDay {
                    out.append(.daySeparator(key: day, label: dayLabel(day)))
                    lastDay = day
                }
                // Every post shows its author (posts never merge headers).
                out.append(.message(id: m.id, revision: revision(m, failed: failed.contains(m.id), header: true),
                                    showsHeader: true))
                let replies = t.replies[m.id] ?? []
                out.append(.threadSummary(rootID: m.id, replies: replies.count, lastReply: replies.last?.timestamp))
            }
            return out
        }
    }

    /// Row that shows `messageID` in a scope: in Posts a reply lands on
    /// its root post; elsewhere the message itself.
    static func visibleTarget(_ messageID: String, scope: TimelineScope, in byID: [String: ChatMessage]) -> String {
        guard scope == .posts, let m = byID[messageID] else { return messageID }
        return ChannelThreads.root(of: m, in: byID) ?? messageID
    }

    /// A reply's quote of its own thread root is noise inside the thread.
    static func showsQuote(_ m: ChatMessage, scope: TimelineScope) -> Bool {
        if case .thread(let root) = scope { return m.reply_to != root }
        return true
    }
}
