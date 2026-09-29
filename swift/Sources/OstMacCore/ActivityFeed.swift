// ActivityFeed.swift — the Teams activity feed (`48:notifications`) as
// Activity rows.
//
// Teams posts every activity item (mention, reply, reaction, missed
// call, meeting and app notifications) into the owner's
// `48:notifications` conversation. Each message carries
// `properties.activity` (JSON object or JSON string) naming the source
// thread/message, the actor, a preview and a timestamp, plus
// `properties.isread` (the feed's own read flag). Reading the page is a
// plain GET that moves no read state; this app never writes the feed's
// read horizon.
//
//   let items = ActivityFeed.parse(data)   // newest first
//
// Threading: pure; callers own the store.
import Foundation

public enum ActivityFeed {
    /// The feed conversation id.
    public static let conversationID = "48:notifications"

    /// Row kind for one feed item (case-insensitive `activityType` +
    /// `activitySubtype`). Unknown types are app notifications.
    public static func kind(type: String, subtype: String?) -> ActivityKind {
        let t = type.lowercased()
        let sub = (subtype ?? "").lowercased()
        switch t {
        case "mention", "mentioninchat", "personmention":
            return ["everyone", "team", "channel", "tag"].contains(sub) ? .channelBlast : .mention
        case "teammention", "channelmention", "tagmention", "everyonemention":
            return .channelBlast
        case "reply", "replytoreply", "replyinchat", "threadreply":
            return .reply
        case "reaction", "reactioninchat", "reactioninchannel", "like":
            return .reaction
        case "missedcall", "callmissed":
            return .missedCall
        case "follow", "channelnewmessage", "newchannelmessage":
            return .channelPost
        default:
            // Graph-sent items (`msGraph`) name the meeting in the subtype
            // (privateMeetingCreated, channelMeetingCanceled, …).
            for word in ["meeting", "call", "calendar"] where t.contains(word) || sub.contains(word) {
                return .meeting
            }
            return .app
        }
    }

    /// Parse one `…/conversations/48:notifications/messages` page into
    /// rows, newest first. Items without a source thread still land
    /// (app notifications) but never jump.
    public static func parse(_ data: Data) -> [ActivityItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = root["messages"] as? [[String: Any]]
        else { return [] }
        var seen = Set<String>()
        var out: [ActivityItem] = []
        for m in messages {
            let props = m["properties"] as? [String: Any] ?? [:]
            guard let act = ChatListSeed.object(props["activity"]),
                  let type = string(act["activityType"]), !type.isEmpty
            else { continue }
            let kind = kind(type: type, subtype: string(act["activitySubtype"]))
            let chatID = string(act["sourceThreadId"]) ?? ""
            let sourceMessage = string(act["sourceMessageId"]).flatMap { $0.isEmpty || $0 == "0" ? nil : $0 }
            let notificationID = string(act["activityId"]) ?? string(m["id"]) ?? ""
            let at = stamp(act["activityTimestamp"]) ?? stamp(m["originalarrivaltime"])
                ?? ChatListSeed.int64(m["id"]).map { UInt64(max(0, $0) / 1000) } ?? 0
            let preview = CoreReads.truncatePreview(
                CoreReads.stripHTML(string(act["messagePreview"]) ?? ""))
            let actor = string(act["sourceUserImDisplayName"]) ?? ""
            let topic = string(act["sourceThreadTopic"]) ?? ""
            let id: String
            let messageID: String?
            switch kind {
            case .mention, .channelBlast, .reply, .reaction, .channelPost:
                // Same id the realtime path mints: one row per message.
                guard !chatID.isEmpty, let sourceMessage else { continue }
                messageID = sourceMessage
                id = ActivityItem.makeID(kind: kind, chatID: chatID, messageID: sourceMessage)
            case .missedCall, .meeting, .app:
                guard !notificationID.isEmpty || sourceMessage != nil else { continue }
                messageID = kind == .missedCall ? nil : sourceMessage
                id = ActivityItem.makeID(
                    kind: kind, chatID: chatID.isEmpty ? "-" : chatID,
                    messageID: "n" + (notificationID.isEmpty ? sourceMessage ?? "" : notificationID))
            }
            guard seen.insert(id).inserted else { continue }
            out.append(ActivityItem(
                kind: kind, chatID: chatID, messageID: messageID,
                actor: kind == .reaction && actor.isEmpty ? "" : actor,
                chatName: topic,
                snippet: kind == .missedCall ? "Missed call" : preview,
                at: at, reviewed: ChatListSeed.bool(props["isread"]), id: id,
                callerID: kind == .missedCall ? string(act["sourceUserId"]) : nil))
        }
        return out.sorted { $0.at == $1.at ? $0.id < $1.id : $0.at > $1.at }
    }

    static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    /// ISO-8601 (with or without fractional seconds) → unix seconds.
    static func stamp(_ v: Any?) -> UInt64? {
        guard let s = string(v), !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return UInt64(max(0, d.timeIntervalSince1970)) }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return UInt64(max(0, d.timeIntervalSince1970)) }
        return nil
    }
}
