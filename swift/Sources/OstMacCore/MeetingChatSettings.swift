// MeetingChatSettings.swift — CHATSYNC3 R1: the owner's own "Meeting chat
// notifications" choice (Teams Settings > Notifications and activity >
// Meeting chats: Mute / Mute until I join or send a message / Unmute).
//
// Where Teams keeps it (tmp/recap2/chunks, precompiled-shared-worker):
// the chat-settings provider reads user-preferences category
// "userPersonalSettings" -> `chatSettings`, which the chat service serves
// in the owner's user properties (`GET {chatService}/v1/users/ME/
// properties`, `userPersonalSettings` = JSON string). Keys:
// `meetingChatNotificationForAcceptedMeetings` / `...ForTentativeMeetings`
// ("MeetingsUserIsInvitedTo" = unmuted, "MeetingsUserParticipatesIn" =
// until I join or send, "MeetingsManuallyUnmuted" = muted; the short wire
// forms "all" / "participated" / "none" too) and, in Teams' newer model,
// per-RSVP switches `meetingChatNotificationRSVPv2{Accepted,Tentative,
// Follow,NoResponse,Declined}`.
//
// `MeetingChatSettingsCache` keeps one value per account: re-read at most
// every 5 minutes, a failed read keeps the last one (else the persisted
// one, else Teams' defaults), so mutes never flip back and forth.
// `MeetingChatUnmute` is Teams' "until I join or send" half: a send or a
// meeting join turns the chat's `alerts` on when the setting says so.
//
// Blocking: every read and write here runs off the main thread.
import Foundation

public enum MeetingChatSettingsReader {
    static func setting(_ raw: Any?) -> ChatMuteRule.MeetingSetting? {
        switch (raw as? String)?.trimmingCharacters(in: .whitespaces) {
        case "MeetingsUserIsInvitedTo", "all": .invitedTo
        case "MeetingsUserParticipatesIn", "participated": .participatesIn
        case "MeetingsManuallyUnmuted", "none": .manuallyUnmuted
        default: nil
        }
    }

    /// A v2 switch: stored as a boolean, or "On"/"Off" as the settings UI names it.
    static func flag(_ raw: Any?) -> Bool? {
        if let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        switch (raw as? String)?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "on", "true": return true
        case "off", "false": return false
        default: return nil
        }
    }

    static let v2States = ["Accepted", "Tentative", "Follow", "NoResponse", "Declined"]

    /// The owner's settings from a properties reply; nil = not readable
    /// (HTTP error, no `userPersonalSettings`). Readable without meeting
    /// keys = the owner never changed them = Teams' defaults.
    static func parse(status: Int, data: Data) -> ChatMuteRule.Settings? {
        guard (200..<300).contains(status),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var ups = obj["userPersonalSettings"] as? [String: Any]
        if ups == nil, let s = obj["userPersonalSettings"] as? String, let d = s.data(using: .utf8) {
            ups = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        guard let ups else { return nil }
        let chat = (ups["chatSettings"] as? [String: Any]) ?? [:]
        var s = ChatMuteRule.Settings.teamsDefault
        if let v = setting(chat["meetingChatNotificationForAcceptedMeetings"]) { s.acceptedMeetings = v }
        if let v = setting(chat["meetingChatNotificationForTentativeMeetings"]) { s.tentativeMeetings = v }
        var v2: [String: Bool] = [:]
        for state in v2States {
            if let on = flag(chat["meetingChatNotificationRSVPv2\(state)"]) { v2[state] = on }
        }
        if !v2.isEmpty { s.rsvpV2 = v2 }
        return s
    }

    /// One read with the caller's token (blocking; never refreshes).
    static func read(chatService: String, skype: String, http: any ReadFetcher) -> ChatMuteRule.Settings? {
        var base = chatService
        while base.hasSuffix("/") { base.removeLast() }
        guard let data = try? CoreReads.chatGET("\(base)/v1/users/ME/properties", code: "meeting_chat_settings",
                                                skype: skype, http: http) else { return nil }
        return parse(status: 200, data: data)
    }
}

/// Per-account meeting-chat settings with a re-read interval and a
/// last-known fallback (see file header).
public final class MeetingChatSettingsCache: @unchecked Sendable {
    public static let shared = MeetingChatSettingsCache()
    /// Seconds between reads; a failed read retries after `retryAfter`.
    static let ttl: TimeInterval = 300
    static let retryAfter: TimeInterval = 60

    private let lock = NSLock()
    private var known: [String: ChatMuteRule.Settings] = [:]
    private var nextRead: [String: Date] = [:]
    private var loaded = false
    private var path: String?

    /// `persistPath` nil = memory only (tests); the app sets one.
    public init(persistPath: String? = nil) {
        path = persistPath.map { NSString(string: $0).expandingTildeInPath }
    }

    /// The app's store (config dir, next to rules.json).
    public static var defaultPath: String { UnixConfig.defaultPath(for: "meeting-chat-settings.json") }

    /// Point the cache at a file (the app, once at launch).
    public func persist(to path: String) {
        lock.withLock {
            self.path = NSString(string: path).expandingTildeInPath
            loaded = false
        }
    }

    /// Last known settings for the account; nil = never read.
    public func known(profile: String) -> ChatMuteRule.Settings? {
        lock.withLock { loadIfNeeded(); return known[profile] }
    }

    /// The account's settings, reading when due (`read` runs outside the lock).
    func settings(profile: String, now: Date = Date(),
                  read: () -> ChatMuteRule.Settings?) -> ChatMuteRule.Settings {
        let due: Bool = lock.withLock {
            loadIfNeeded()
            return (nextRead[profile] ?? .distantPast) <= now
        }
        guard due else { return known(profile: profile) ?? .teamsDefault }
        let fresh = read()
        return lock.withLock {
            nextRead[profile] = now.addingTimeInterval(fresh == nil ? Self.retryAfter : Self.ttl)
            if let fresh, known[profile] != fresh {
                known[profile] = fresh
                save()
            }
            return known[profile] ?? .teamsDefault
        }
    }

    // Lock held.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let stored = try? JSONDecoder().decode([String: ChatMuteRule.Settings].self, from: data) else { return }
        for (k, v) in stored where known[k] == nil { known[k] = v }
    }

    // Lock held. Best effort: a failed write keeps the memory value.
    private func save() {
        guard let path, let data = try? JSONEncoder().encode(known) else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Teams' "until I join or send a message": after the owner sends in a
/// meeting chat or joins its meeting, the chat's `alerts` goes to "true"
/// when `ChatMuteRule.unmutes` says so (one read of the chat, one write).
public enum MeetingChatUnmute {
    typealias Put = @Sendable (_ chatID: String, _ body: Data) throws -> Void

    /// Blocking. True when `alerts` was written.
    static func run(_ activity: ChatMuteRule.Activity, chatID: String, profile: String,
                    ctx: ReadContext, cache: MeetingChatSettingsCache, put: Put) -> Bool {
        guard ChatMuteRule.isMeetingChat(chatID),
              let (skype, slots) = try? CoreReads.skypeToken(profile: profile, code: "meeting_chat_alerts", ctx: ctx)
        else { return false }
        let svc = CoreReads.chatServiceURL(slots)
        let id = chatID.trimmingCharacters(in: .whitespaces)
        guard let data = try? CoreReads.chatGET("\(svc)/v1/users/ME/conversations/\(id)", code: "meeting_chat_alerts",
                                                skype: skype, http: ctx.http),
              let conv = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        let props = (conv["properties"] as? [String: Any]) ?? [:]
        let settings = cache.settings(profile: profile) {
            MeetingChatSettingsReader.read(chatService: svc, skype: skype, http: ctx.http)
        }
        guard ChatMuteRule.unmutes(on: activity, chatID: id, alerts: props["alerts"] as? String,
                                   meetingInfo: props["meetingInfo"] as? String, settings: settings) else { return false }
        do {
            try put(id, ReadSync.body("alerts", "true"))
            return true
        } catch {
            return false
        }
    }

    /// Fire and forget, off the main thread (Teams logs a failure and moves on).
    public static func after(_ activity: ChatMuteRule.Activity, chatID: String) {
        guard ChatMuteRule.isMeetingChat(chatID) else { return }
        let profile = CoreLocal.activeProfileID()
        Task<Void, Never>.blocking(priority: .utility) {
            guard let ctx = try? CoreReads.production() else { return }
            _ = run(activity, chatID: chatID, profile: profile, ctx: ctx, cache: .shared) { id, body in
                let (skype, slots) = try CoreReads.skypeToken(profile: profile, code: "meeting_chat_alerts", ctx: ctx)
                guard let url = URL(string: ReadSync.propertyURL(base: CoreReads.chatServiceURL(slots),
                                                                 chatID: id, name: "alerts")) else {
                    throw CoreCallError.failed("meeting_chat_alerts: bad chat id")
                }
                let resp = try URLSessionCalendarHTTP().send(
                    "PUT", url: url,
                    headers: ["Authentication": "skypetoken=\(skype)", "Content-Type": "application/json"],
                    body: body)
                guard (200..<300).contains(resp.status) else {
                    throw CoreCallError.failed("meeting_chat_alerts: HTTP \(resp.status)")
                }
            }
        }
    }
}
