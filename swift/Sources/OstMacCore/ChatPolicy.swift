// ChatPolicy.swift — CHATSYNC2b: two chat rules read from the Teams web
// client (tmp/recap2/chunks), so a chat looks and acts here the way it
// does in Teams.
//
// Mute (`ChatMuteRule`), the worker's `isConversationMuted`:
// - `properties.alerts` decides when present: "false" = muted, "true" =
//   not muted.
// - Without it, a MEETING chat (`19:meeting…`) is muted unless the owner
//   organized the meeting, following the owner's meeting RSVP
//   (`properties.meetingInfo` JSON `rsvpStatus`) and the owner's Teams
//   "Meeting chat notifications" settings (CHATSYNC3: read from the user
//   properties, `MeetingChatSettingsReader`; Teams defaults until read).
//   Prod config turns on `enableRSVPBasedMeetingChatNotifications`;
//   defaults: Accepted = not muted, Declined/Follow = muted,
//   Tentative/None = muted ("Mute until I join or send a message").
// - Any other chat without `alerts` is not muted.
//
// Delete chat (`ChatDeleteRule`), the chat-list menu's `deleteItem`:
// offered only when the owner's Teams messaging policy has
// `allowUserDeleteChat` (policy default false), and then for 1:1 chats,
// group chats, and meeting chats the owner did not organize; never for
// the chat with yourself. `MessagingPolicyReader` reads the policy with
// the Teams client's own read (`POST {middleTier}/beta/users/
// useraggregatesettings` with `{"messagingPolicy":true}`, no side effects).
// While the policy is unknown (not read yet, read failed) only 1:1 chats
// offer Delete.
//
// Blocking: `MessagingPolicyReader.fetch` runs off the main thread.
import Foundation

public enum ChatMuteRule {
    /// "Meeting chat notifications" choices (Teams user chat settings).
    /// "Unmuted" (invitedTo), "Mute until I join or send a message"
    /// (participatesIn), "Mute" (manuallyUnmuted: unmuted only by hand).
    public enum MeetingSetting: String, Sendable, Codable {
        case participatesIn = "MeetingsUserParticipatesIn"
        case invitedTo = "MeetingsUserIsInvitedTo"
        case manuallyUnmuted = "MeetingsManuallyUnmuted"
    }

    /// The owner's meeting-chat notification settings; `teamsDefault`
    /// until they have been read.
    public struct Settings: Sendable, Equatable, Codable {
        public var acceptedMeetings: MeetingSetting
        public var tentativeMeetings: MeetingSetting
        /// Teams' newer per-RSVP model (on = notify), keyed Accepted,
        /// Tentative, Follow, NoResponse, Declined; nil = the owner's
        /// settings hold only the dropdown model above.
        public var rsvpV2: [String: Bool]?
        public init(acceptedMeetings: MeetingSetting = .invitedTo,
                    tentativeMeetings: MeetingSetting = .participatesIn,
                    rsvpV2: [String: Bool]? = nil) {
            self.acceptedMeetings = acceptedMeetings
            self.tentativeMeetings = tentativeMeetings
            self.rsvpV2 = rsvpV2
        }
        public static let teamsDefault = Settings()
    }

    /// Per-RSVP defaults of Teams' v2 model (worker module `p`).
    static let rsvpV2Defaults: [String: Bool] = [
        "Accepted": true, "Tentative": true, "Follow": true, "NoResponse": false, "Declined": false,
    ]

    /// v2: muted = the RSVP's switch is off (stored, else the default).
    /// A Declined switch counts only when Teams stored one (the flag
    /// that shows it is otherwise off, and Declined is then muted).
    static func v2Muted(rsvp: String, _ v2: [String: Bool]) -> Bool {
        let key = rsvp == "None" ? "NoResponse" : rsvp
        if key == "Declined", v2["Declined"] == nil { return true }
        return !(v2[key] ?? rsvpV2Defaults[key] ?? false)
    }

    /// Meeting chat thread prefixes (all clouds), as the Teams worker lists them.
    static let meetingPrefixes = [
        "19:meeting", "19:gcch:meeting", "19:dod:meeting", "19:gal:meeting",
        "19:ag08:meeting", "19:ag09:meeting", "19:fr:meeting", "19:de:meeting",
    ]

    public static func isMeetingChat(_ chatID: String) -> Bool {
        let id = chatID.trimmingCharacters(in: .whitespaces)
        return meetingPrefixes.contains { id.hasPrefix($0) }
    }

    /// `alerts` as Teams reads it: "false" = muted, "true" = not, else unknown.
    public static func explicitMute(_ alerts: String?) -> Bool? {
        switch alerts?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "false": true
        case "true": false
        default: nil
        }
    }

    /// The owner's RSVP from `properties.meetingInfo` (JSON string);
    /// anything unreadable or unlisted is "None".
    public static func rsvpStatus(meetingInfo: String?) -> String {
        let known = ["Accepted", "Declined", "Follow", "Tentative", "None"]
        guard let raw = meetingInfo, let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let s = obj["rsvpStatus"] as? String, known.contains(s) else { return "None" }
        return s
    }

    /// Teams' muted state for one chat.
    public static func isMuted(chatID: String, alerts: String?, meetingInfo: String?,
                               creatorIsSelf: Bool, settings: Settings = .teamsDefault) -> Bool {
        if let explicit = explicitMute(alerts) { return explicit }
        guard isMeetingChat(chatID), !creatorIsSelf else { return false }
        let rsvp = rsvpStatus(meetingInfo: meetingInfo)
        if let v2 = settings.rsvpV2 { return v2Muted(rsvp: rsvp, v2) }
        switch rsvp {
        case "Declined", "Follow": return true
        case "Accepted": return settings.acceptedMeetings != .invitedTo
        default: return settings.tentativeMeetings != .invitedTo
        }
    }

    /// What turns a "Mute until I join or send a message" chat back on.
    public enum Activity: Sendable { case send, join }

    /// Teams' autoEnableConversationAlerts (worker `sendMessageInConv` and
    /// the meeting-join resolver): a meeting chat with no `alerts` of its
    /// own gets `alerts` "true" when the owner's choice for that RSVP is
    /// "until I join or send". Declined/Follow chats come back on a join,
    /// not a send; v2 turns on whatever its switches keep muted.
    public static func unmutes(on activity: Activity, chatID: String, alerts: String?,
                               meetingInfo: String?, settings: Settings) -> Bool {
        guard isMeetingChat(chatID), alerts == nil else { return false }
        let rsvp = rsvpStatus(meetingInfo: meetingInfo)
        if let v2 = settings.rsvpV2 { return v2Muted(rsvp: rsvp, v2) && !(rsvp == "Declined" && v2["Declined"] == nil) }
        switch rsvp {
        case "Accepted": return settings.acceptedMeetings == .participatesIn
        case "Declined", "Follow": return activity == .join
        default: return settings.tentativeMeetings == .participatesIn
        }
    }
}

public enum ChatDeleteRule {
    /// The owner's Teams messaging policy on deleting chats.
    public enum Policy: Sendable, Equatable {
        case unknown, allowed, denied
    }

    /// Whether the chat menu offers Delete for this chat.
    public static func canDelete(chatID: String, isGroup: Bool, isMeetingOrganizer: Bool,
                                 policy: Policy) -> Bool {
        let id = chatID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !ChatListFilter.isSelfChat(id) else { return false }
        switch policy {
        case .denied: return false
        case .unknown: return !isGroup
        case .allowed:
            if ChatMuteRule.isMeetingChat(id) { return !isMeetingOrganizer }
            return true
        }
    }
}

public enum MessagingPolicyReader {
    public struct Raw: Sendable, Equatable {
        public var status: Int
        public var resultCode: String?
        public var allowUserDeleteChat: Bool?
        public var valueKeyCount: Int
    }

    static let path = "beta/users/useraggregatesettings"
    static let defaultMiddleTier = "https://teams.microsoft.com/api/mt/amer"

    static func url(middleTier: String?) -> URL? {
        var base = (middleTier?.isEmpty == false ? middleTier! : defaultMiddleTier)
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: "\(base)/\(path)")
    }

    /// Parse the `useraggregatesettings` reply.
    static func parse(status: Int, data: Data) -> Raw {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let ns = obj?["messagingPolicy"] as? [String: Any]
        let value = ns?["value"] as? [String: Any]
        return Raw(status: status, resultCode: ns?["resultCode"] as? String,
                   allowUserDeleteChat: value?["allowUserDeleteChat"] as? Bool,
                   valueKeyCount: value?.count ?? 0)
    }

    /// Policy from a parsed reply: a readable flag decides; anything else
    /// (HTTP error, namespace missing) stays unknown.
    static func policy(_ raw: Raw) -> ChatDeleteRule.Policy {
        guard (200..<300).contains(raw.status), let v = raw.allowUserDeleteChat else {
            // Namespace present and readable but the flag absent: Teams
            // uses the policy default (false).
            if (200..<300).contains(raw.status), raw.valueKeyCount > 0 { return .denied }
            return .unknown
        }
        return v ? .allowed : .denied
    }

    /// One read with the stored tokens (never refreshes; stale = unknown).
    static func fetchRaw(slots: TokenSlots, now: UInt64,
                         http: any CalendarHTTP = URLSessionCalendarHTTP()) -> Raw {
        let fail = Raw(status: 0, resultCode: nil, allowUserDeleteChat: nil, valueKeyCount: 0)
        guard let aad = slots.accessToken, !aad.isExpired(now: now),
              let sk = slots.skypeToken, !sk.isExpired(now: now),
              let url = url(middleTier: CoreReads.regionGTMS(slots)["middleTier"]) else { return fail }
        let body = Data(#"{"messagingPolicy":true}"#.utf8)
        guard let resp = try? http.send("POST", url: url, headers: [
            "Authorization": "Bearer \(aad.token)",
            "X-Skypetoken": sk.token,
            "x-ms-client-type": "desktop",
            "Content-Type": "application/json;charset=UTF-8",
            "Accept": "application/json",
        ], body: body) else { return fail }
        return parse(status: resp.status, data: resp.data)
    }

    /// The active profile's delete-chat policy (blocking).
    public static func fetch() -> ChatDeleteRule.Policy {
        guard let ctx = try? CoreReads.production() else { return .unknown }
        let slots = ctx.store.load(profile: TomlConfig.normalize(CoreLocal.activeProfileID()))
        return policy(fetchRaw(slots: slots, now: ctx.now()))
    }
}

