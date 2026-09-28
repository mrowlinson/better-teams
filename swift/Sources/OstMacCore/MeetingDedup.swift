// MeetingDedup.swift — om-rules lane: meeting-start collapse + dedup.
//
// Port of TeamsNotifier's TeamsCore/MeetingDedup.swift, adapted for OstMac:
// classify() takes plain strings (OstMac's RealtimeMessage carries text/
// raw/chatID/sender rather than TeamsNotifier's EventMessage.Message).
// One semantic adaptation: the core renders a missing sender as "?", so
// "?" counts as unknown-sender for Play-beacon detection (TeamsNotifier
// requires an empty sender).
import Foundation

/// Meeting-lifecycle signal classification + per-chat meeting-start dedup.
///
/// One meeting burst used to produce ~15 notifications from four shapes,
/// all inside 19:meeting_* threads as notifiable types: (a) "<chat>Play"
/// beacons with unknown sender, repeated; (b) raw JSON meeting-metadata
/// blobs; (c) Facilitator bot open/close bookends; (d) empty-text bodies.
/// New behavior: each meeting burst collapses into ONE synthesized
/// "Meeting starting: <chat>" notification (first signal notifies, rest
/// suppressed within the per-chat window). Raw beacon/blob/bookend/empty
/// bodies never notify.
public enum MeetingSignal: Sendable, Equatable {
    case playBeacon
    case meetingBlob
    case facilitatorOpen
    case facilitatorClose
    case emptyText
    case jsonBlob
    case codeBlob
    case normal

    /// Classify a message. Pure; every branch covered by tests.
    ///
    /// - `text`: stripped plain text (notification body).
    /// - `content`: unstripped wire body (blank-wire check).
    /// - Empty plain text is a signal only in meeting threads or when
    ///   the wire content itself is blank. Markup-only bodies
    ///   ("<p><br/></p>") in normal chats stay `.normal`.
    /// - Meeting blobs need scopeId + storageId plus a meeting key
    ///   (meetingTenantId/meetingOrganizerId/iCalUid): strict, so a
    ///   user-pasted JSON snippet stays a plain `.jsonBlob` (skipped,
    ///   never opens the meeting window).
    /// - Play beacons: strict "<chat>Play" (or "<chat> Play") with an
    ///   unknown sender in ANY thread, plus a fallback (unknown sender +
    ///   meeting thread + "Play" suffix) for when chat-name resolution
    ///   failed. Case-sensitive "Play"; a lone "Play" never matches.
    ///   Unknown sender = empty OR "?" (the core's missing-name marker).
    /// - Facilitator: sender "Facilitator" (case-insensitive) with the
    ///   observed open/close markers (apostrophe-normalized). Any other
    ///   Facilitator text is `.normal` (only open/close were observed).
    public static func classify(text: String, content: String, chatID: String, senderName: String, chatDisplayName: String) -> MeetingSignal {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isMeetingThread(chatID) || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .emptyText
            }
            return .normal
        }
        if isMeetingBlob(text) { return .meetingBlob }
        if isJSONBlob(text) { return .jsonBlob }
        if isCodeBlob(text) { return .codeBlob }
        if isPlayBeacon(text: text, chatID: chatID, senderName: senderName, chatDisplayName: chatDisplayName) { return .playBeacon }
        if isFacilitator(senderName) {
            let norm = normalizedApostrophes(text).lowercased()
            if norm.contains("here to help with the meeting") { return .facilitatorOpen }
            if norm.contains("that's a wrap") { return .facilitatorClose }
        }
        return .normal
    }

    /// Meeting chat threads look like 19:meeting_<id>@thread.v2.
    public static func isMeetingThread(_ chatID: String) -> Bool {
        chatID.range(of: "meeting_", options: .caseInsensitive) != nil
    }

    static func isMeetingBlob(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{"),
              let data = t.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        guard obj["scopeId"] != nil, obj["storageId"] != nil else { return false }
        return obj["meetingTenantId"] != nil || obj["meetingOrganizerId"] != nil || obj["iCalUid"] != nil
    }

    /// Any whole-body JSON object/array (meeting blobs test first, so
    /// this is the non-meeting remainder: never notifies, never opens).
    static func isJSONBlob(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") || t.hasPrefix("["),
              let data = t.data(using: .utf8)
        else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// Whole-body fenced code block (```...```): never notifies.
    static func isCodeBlob(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("```") && t.hasSuffix("```") && t.count > 6
    }

    static func isPlayBeacon(text: String, chatID: String, senderName: String, chatDisplayName: String) -> Bool {
        guard isUnknownSender(senderName) else { return false }
        if !chatDisplayName.isEmpty,
           text == chatDisplayName + "Play" || text == chatDisplayName + " Play"
        {
            return true
        }
        guard isMeetingThread(chatID) else { return false }
        return text.hasSuffix("Play") && text.count > 4
    }

    /// Empty sender, or the core's "?" missing-name marker (the beacon
    /// path never carries a display name).
    public static func isUnknownSender(_ senderName: String) -> Bool {
        let t = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == "?"
    }

    public static func isFacilitator(_ senderName: String) -> Bool {
        senderName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "facilitator"
    }

    static func normalizedApostrophes(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
    }
}

/// Meeting-start dedup: per-chat sliding window over meeting
/// activity. First meeting signal per chat notifies; further signals
/// within `windowSeconds` of the last meeting activity fold (skip).
/// A later meeting (gap > window) notifies again.
///
/// Why sliding, not chat+day/half-day buckets: the observed burst spans
/// noon (11:57:09Z -> 12:03:42Z), so pure buckets would notify TWICE for
/// one meeting. Time clustering is the burst identity: observed
/// within-burst gaps are <= ~3min, inter-meeting gaps hours.
/// Entries older than the window prune on each call (bounded memory).
public struct MeetingStartDedup: Sendable {
    private var lastActive: [String: Date] = [:]

    public init() {}

    /// Fold repeats within 2h of the last meeting signal per chat.
    public static let windowSeconds: TimeInterval = 2 * 60 * 60

    /// Open-signals (Play beacon, meeting blob, Facilitator open) call
    /// this: true when no meeting activity in the window (records it),
    /// false when folding (slides the window forward).
    public mutating func shouldNotify(chatID: String, date: Date) -> Bool {
        prune(now: date)
        if let last = lastActive[chatID], date.timeIntervalSince(last) < Self.windowSeconds {
            lastActive[chatID] = date
            return false
        }
        lastActive[chatID] = date
        return true
    }

    /// Fold-only signals (Facilitator close, meeting-thread
    /// empty/JSON/code bodies) extend an OPEN window so a long meeting
    /// keeps folding. Never opens one: a lone close with no window
    /// leaves no trace, and the next meeting still notifies.
    public mutating func observe(chatID: String, date: Date) {
        guard let last = lastActive[chatID], date.timeIntervalSince(last) < Self.windowSeconds else { return }
        lastActive[chatID] = date
    }

    /// Live tracked-chat count. Tests/debug only.
    public var count: Int { lastActive.count }

    private mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.windowSeconds)
        lastActive = lastActive.filter { $0.value >= cutoff }
    }
}
