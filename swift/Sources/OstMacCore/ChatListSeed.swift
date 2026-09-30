// ChatListSeed.swift — Unread and Mentions filter state from Teams.
//
// The Unread and Mentions stores used to accrue from live events only,
// so both filters were empty after every launch. These pure rules seed
// them from what Teams already knows:
//
// - Unread: the chat list's per-user read horizon
//   (`properties.consumptionhorizon` = "<readTimeMs>;<clientMs>;<msgId>")
//   against the last message. Both the horizon time AND its message id
//   must be behind the last message: a live audit of 628 conversations
//   found each half alone misfires (time-only flagged chats whose newer
//   message id the owner had already acked; id-only flagged chats read
//   after a trailing control message). Own last messages are read;
//   only user content (Text / RichText, media included) counts —
//   member adds, call events and other control messages never do.
// - Mentions: the activity feed (`48:notifications`), whose
//   `mentionInChat` items name the source chat and message. An item is
//   unreviewed while the feed still marks it unread OR the message sits
//   past that chat's read horizon.
//
//   let unread = ChatListSeed.isUnread(horizon: h, lastMessageID: id, ...)
//   let flagged = ChatListSeed.mentionedChats(activity, horizons: map)
//
// Threading: pure, Sendable values; callers own the stores.
import Foundation

/// One `mentionInChat` item from the activity feed.
public struct MentionActivity: Sendable, Equatable {
    /// Source chat id.
    public let chatID: String
    /// Source message id (epoch ms, as Teams mints them).
    public let messageID: Int64
    /// The feed's own read flag for the item.
    public let isRead: Bool
    /// `@everyone` (activitySubtype "everyone") rather than the owner by name.
    public let everyone: Bool

    public init(chatID: String, messageID: Int64, isRead: Bool, everyone: Bool = false) {
        self.chatID = chatID
        self.messageID = messageID
        self.isRead = isRead
        self.everyone = everyone
    }

    /// When the mentioning message was sent (message ids are epoch ms).
    public var sentAt: Date {
        Date(timeIntervalSince1970: TimeInterval(messageID) / 1000)
    }
}

/// Server-side unread state for one listed chat (UnreadStore seed).
public struct UnreadSeed: Sendable, Equatable {
    public let chatID: String
    public let unread: Bool
    public let lastMessageAt: Date?
    public let muted: Bool
    /// Teams "Mark as unread" bookmark sits behind the newest message
    /// (CHATSYNC): unread even when the owner read it here before.
    public let markedUnread: Bool

    public init(chatID: String, unread: Bool, lastMessageAt: Date?, muted: Bool = false, markedUnread: Bool = false) {
        self.chatID = chatID
        self.unread = unread || markedUnread
        self.lastMessageAt = lastMessageAt
        self.muted = muted
        self.markedUnread = markedUnread
    }
}

public enum ChatListSeed {
    /// Parsed read horizon: read time and last-read message id (0 when
    /// a field is missing or not a number). Blank input is nil.
    public static func horizon(_ raw: String?) -> (readMs: Int64, messageID: Int64)? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false)
        let read = parts.first.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        let msg = parts.count > 2 ? Int64(parts[2].trimmingCharacters(in: .whitespaces)) ?? 0 : 0
        // The Teams web client writes the message's clientmessageid in
        // the third field (worker: `${originalArrivalTime};${timeStamp};
        // ${clientMessageId}`), a random 19-digit number, not a message
        // id. Only an epoch-ms-shaped value is a message id; anything
        // else leaves the id axis open (the time axis decides, as in
        // Teams).
        return (read, isEpochMs(msg) ? msg : 0)
    }

    /// Message ids and arrival times are epoch ms (13 digits today).
    static func isEpochMs(_ v: Int64) -> Bool { v >= 1_000_000_000_000 && v < 100_000_000_000_000 }

    /// Teams "Mark as unread" (`consumptionHorizonBookmark`,
    /// "<arrival-1>;<nowMs>;<clientMessageId>"; cleared = "0;<nowMs>;0"):
    /// set and behind the newest message.
    public static func isMarkedUnread(bookmark raw: String?, lastMessageTime: String?) -> Bool {
        guard let b = horizon(raw), b.readMs > 0 else { return false }
        guard let last = lastMessageTime.flatMap(ChatListFormat.parse) else { return true }
        return Int64((last.timeIntervalSince1970 * 1000).rounded()) > b.readMs
    }

    /// True when a message (id and send time in epoch ms) sits past the
    /// horizon on BOTH axes (see the file header for why both).
    public static func isPast(horizon: (readMs: Int64, messageID: Int64), messageID: Int64?, sentMs: Int64?) -> Bool {
        guard let at = sentMs ?? messageID else { return false }
        let pastID = messageID.map { $0 > horizon.messageID } ?? true
        return pastID && at > horizon.readMs
    }

    /// User content that makes a chat unread: Text / RichText (media
    /// included). Control messages (member adds, call events, topic
    /// changes) never do.
    public static func countsAsUnread(messageType: String?) -> Bool {
        let t = messageType ?? ""
        return t.hasPrefix("Text") || t.hasPrefix("RichText")
    }

    /// Server unread for one chat, or nil when the list carried no read
    /// horizon (unknown — leave the store alone).
    public static func isUnread(
        horizon raw: String?, lastMessageID: String?, lastMessageTime: String?,
        messageType: String?, fromOwner: Bool
    ) -> Bool? {
        guard let h = horizon(raw) else { return nil }
        if fromOwner { return false }
        guard countsAsUnread(messageType: messageType) else { return false }
        let id = lastMessageID.flatMap { Int64($0) }
        let sent = lastMessageTime.flatMap(ChatListFormat.parse).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
        return isPast(horizon: h, messageID: id, sentMs: sent)
    }

    /// Unread seeds for fetched rows that carry a server verdict.
    public static func unreadSeeds(_ chats: [ChatItem], mutedIDs: Set<String> = []) -> [UnreadSeed] {
        chats.compactMap { c in
            let marked = isMarkedUnread(bookmark: c.read_bookmark, lastMessageTime: c.last_message_time)
            guard let u = c.unread ?? (marked ? true : nil) else { return nil }
            return UnreadSeed(
                chatID: c.id, unread: u,
                lastMessageAt: c.last_message_time.flatMap(ChatListFormat.parse),
                muted: mutedIDs.contains(c.id), markedUnread: marked)
        }
    }

    /// A pushed read-position change (Trouter `ConversationUpdate`,
    /// CHATSYNC2b R3) as an Unread seed, same verdict as a fetched row.
    /// Nil when it carries none (no horizon or owner identity, no newest
    /// message, not marked unread).
    public static func pushedSeed(_ ev: ReadStateEvent, ownerOID: String?, muted: Bool) -> UnreadSeed? {
        let marked = isMarkedUnread(bookmark: ev.bookmark, lastMessageTime: ev.lastMessageTime)
        var unread: Bool?
        if horizon(ev.horizon) != nil, let oid = ownerOID, !oid.isEmpty,
           ev.lastMessageID != nil || ev.lastMessageTime != nil {
            unread = isUnread(
                horizon: ev.horizon, lastMessageID: ev.lastMessageID,
                lastMessageTime: ev.lastMessageTime, messageType: ev.lastMessageType,
                fromOwner: CoreReads.mriIsSelf(CoreReads.mriFromUserLink(ev.lastMessageFrom), selfOID: oid))
        }
        guard let u = unread ?? (marked ? true : nil) else { return nil }
        return UnreadSeed(chatID: ev.chatID, unread: u,
                          lastMessageAt: ev.lastMessageTime.flatMap(ChatListFormat.parse),
                          muted: muted, markedUnread: marked)
    }

    /// Chats with an unreviewed mention → newest such mention's send
    /// time. Unknown horizons fall back to the feed's read flag alone.
    public static func mentionedChats(_ activity: [MentionActivity], horizons: [String: String]) -> [String: Date] {
        var out: [String: Date] = [:]
        for a in activity where !a.chatID.isEmpty {
            let past = horizon(horizons[a.chatID]).map {
                isPast(horizon: $0, messageID: a.messageID, sentMs: a.messageID)
            } ?? false
            guard !a.isRead || past else { continue }
            out[a.chatID] = max(out[a.chatID] ?? .distantPast, a.sentAt)
        }
        return out
    }

    /// Parse the activity feed page (`48:notifications` messages): the
    /// `mentionInChat` items only. `properties.activity` arrives as an
    /// object or a JSON string; `isread` as a string or bool. Bad data
    /// yields an empty list, never an error.
    public static func parseMentionActivity(_ data: Data) -> [MentionActivity] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = root["messages"] as? [[String: Any]]
        else { return [] }
        var out: [MentionActivity] = []
        for m in messages {
            let props = m["properties"] as? [String: Any] ?? [:]
            guard let act = object(props["activity"]),
                  (act["activityType"] as? String)?.caseInsensitiveCompare("mentionInChat") == .orderedSame,
                  let chat = act["sourceThreadId"] as? String, !chat.isEmpty,
                  let msg = int64(act["sourceMessageId"])
            else { continue }
            out.append(MentionActivity(
                chatID: chat, messageID: msg, isRead: bool(props["isread"]),
                everyone: (act["activitySubtype"] as? String)?.lowercased() == "everyone"))
        }
        return out
    }

    static func object(_ v: Any?) -> [String: Any]? {
        if let d = v as? [String: Any] { return d }
        guard let s = v as? String, let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func int64(_ v: Any?) -> Int64? {
        if let s = v as? String { return Int64(s) }
        if let n = v as? NSNumber { return n.int64Value }
        return nil
    }

    static func bool(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let s = v as? String { return s.lowercased() == "true" }
        return false
    }
}
