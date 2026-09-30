// ChatSync3Tests.swift — CHATSYNC3 with fake transports: the owner's own
// meeting-chat notification setting (R1). Zero network; fixture tokens.
import Foundation
import XCTest
@testable import OstMacCore

// MARK: R1 settings parse + mute rule

final class ChatSync3SettingsTests: XCTestCase {
    let meeting = "19:meeting_MzA5@thread.v2"

    func info(_ rsvp: String) -> String { #"{"rsvpStatus":"\#(rsvp)"}"# }

    /// A `v1/users/ME/properties` reply: `userPersonalSettings` is a JSON string.
    static func properties(_ chatSettings: String?) -> String {
        let ups = chatSettings.map { #"{"selectedPreset":"Default","chatSettings":\#($0)}"# } ?? #"{"selectedPreset":"Default"}"#
        let escaped = ups.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"readReceiptsEnabled":"true","userPersonalSettings":"\#(escaped)"}"#
    }

    func parse(_ body: String, status: Int = 200) -> ChatMuteRule.Settings? {
        MeetingChatSettingsReader.parse(status: status, data: Data(body.utf8))
    }

    func testParseReadsTheOwnersMeetingChatChoice() {
        // The owner's live shape (probe 1): dropdown model, full names.
        let owner = parse(Self.properties(#"{"meetingChatNotification":"MeetingsUserParticipatesIn","meetingChatNotificationForAcceptedMeetings":"MeetingsUserIsInvitedTo","meetingChatNotificationForTentativeMeetings":"MeetingsUserParticipatesIn"}"#))
        XCTAssertEqual(owner, .teamsDefault)
        // Changed choices, short wire forms too.
        let changed = parse(Self.properties(#"{"meetingChatNotificationForAcceptedMeetings":"none","meetingChatNotificationForTentativeMeetings":"all"}"#))
        XCTAssertEqual(changed?.acceptedMeetings, .manuallyUnmuted)
        XCTAssertEqual(changed?.tentativeMeetings, .invitedTo)
        XCTAssertNil(changed?.rsvpV2)
        // v2 switches: booleans or On/Off.
        let v2 = parse(Self.properties(#"{"meetingChatNotificationRSVPv2Accepted":false,"meetingChatNotificationRSVPv2Tentative":"Off","meetingChatNotificationRSVPv2Declined":"On"}"#))
        XCTAssertEqual(v2?.rsvpV2, ["Accepted": false, "Tentative": false, "Declined": true])
        // Readable, never changed = Teams defaults; unreadable = nil.
        XCTAssertEqual(parse(Self.properties(nil)), .teamsDefault)
        XCTAssertEqual(parse(Self.properties(#"{"meetingChatNotificationForTentativeMeetings":"bogus"}"#)), .teamsDefault)
        XCTAssertNil(parse(#"{"readReceiptsEnabled":"true"}"#), "no userPersonalSettings")
        XCTAssertNil(parse(Self.properties(nil), status: 500))
        XCTAssertNil(parse("not json"))
    }

    func testMuteFollowsTheOwnersSetting() {
        func muted(_ rsvp: String, _ s: ChatMuteRule.Settings, creator: Bool = false) -> Bool {
            ChatMuteRule.isMuted(chatID: meeting, alerts: nil, meetingInfo: info(rsvp), creatorIsSelf: creator, settings: s)
        }
        let unmuteAll = ChatMuteRule.Settings(acceptedMeetings: .invitedTo, tentativeMeetings: .invitedTo)
        XCTAssertFalse(muted("Tentative", unmuteAll))
        XCTAssertFalse(muted("None", unmuteAll))
        XCTAssertTrue(muted("Declined", unmuteAll), "Declined/Follow stay muted in the dropdown model")
        let muteAll = ChatMuteRule.Settings(acceptedMeetings: .manuallyUnmuted, tentativeMeetings: .manuallyUnmuted)
        XCTAssertTrue(muted("Accepted", muteAll))
        XCTAssertFalse(muted("Accepted", muteAll, creator: true), "organizer never muted")
        XCTAssertTrue(muted("Accepted", .init(acceptedMeetings: .participatesIn)))
        // alerts still wins over any setting.
        XCTAssertFalse(ChatMuteRule.isMuted(chatID: meeting, alerts: "true", meetingInfo: info("None"),
                                            creatorIsSelf: false, settings: muteAll))
        // v2: stored switch, else Teams' v2 default; Declined only by a stored switch.
        let v2 = ChatMuteRule.Settings(rsvpV2: ["Accepted": false])
        XCTAssertTrue(muted("Accepted", v2))
        XCTAssertFalse(muted("Tentative", v2), "v2 default: Tentative on")
        XCTAssertFalse(muted("Follow", v2))
        XCTAssertTrue(muted("None", v2), "v2 default: NoResponse off")
        XCTAssertTrue(muted("Declined", v2))
        XCTAssertFalse(muted("Declined", .init(rsvpV2: ["Declined": true])))
    }

    func testSendOrJoinTurnsUntilJoinOrSendChatsOn() {
        func on(_ a: ChatMuteRule.Activity, _ rsvp: String, alerts: String? = nil,
                _ s: ChatMuteRule.Settings = .teamsDefault, id: String? = nil) -> Bool {
            ChatMuteRule.unmutes(on: a, chatID: id ?? meeting, alerts: alerts, meetingInfo: info(rsvp), settings: s)
        }
        // Owner's setting: tentative/no reply = until I join or send.
        XCTAssertTrue(on(.send, "Tentative"))
        XCTAssertTrue(on(.send, "None"))
        XCTAssertTrue(on(.join, "None"))
        XCTAssertFalse(on(.send, "Accepted"), "accepted is already unmuted")
        XCTAssertFalse(on(.send, "Follow"), "a send leaves Follow/Declined muted")
        XCTAssertFalse(on(.send, "Declined"))
        XCTAssertTrue(on(.join, "Follow"), "a join turns Follow/Declined on")
        XCTAssertTrue(on(.join, "Declined"))
        // Muted outright, or unmuted already: nothing to do.
        let mute = ChatMuteRule.Settings(acceptedMeetings: .manuallyUnmuted, tentativeMeetings: .manuallyUnmuted)
        XCTAssertFalse(on(.send, "Tentative", mute))
        XCTAssertFalse(on(.send, "Tentative", .init(tentativeMeetings: .invitedTo)))
        XCTAssertTrue(on(.send, "Accepted", .init(acceptedMeetings: .participatesIn)))
        // A chat with its own alerts, or not a meeting chat: never.
        XCTAssertFalse(on(.send, "Tentative", alerts: "false"))
        XCTAssertFalse(on(.send, "Tentative", alerts: "true"))
        XCTAssertFalse(on(.send, "Tentative", id: "19:grp@thread.v2"))
        // v2: whatever its switches keep muted; Declined only with a stored switch.
        XCTAssertTrue(on(.send, "None", .init(rsvpV2: [:])))
        XCTAssertFalse(on(.send, "Tentative", .init(rsvpV2: [:])))
        XCTAssertFalse(on(.send, "Declined", .init(rsvpV2: [:])))
        XCTAssertTrue(on(.send, "Declined", .init(rsvpV2: ["Declined": false])))
    }

    func testCacheKeepsTheLastReadAndPersistsIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chatsync3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("meeting-chat-settings.json").path
        let owner = ChatMuteRule.Settings(acceptedMeetings: .invitedTo, tentativeMeetings: .invitedTo)
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        let cache = MeetingChatSettingsCache(persistPath: path)
        var reads = 0
        // Unknown and unreadable: Teams' defaults.
        XCTAssertEqual(cache.settings(profile: "a", now: t0) { reads += 1; return nil }, .teamsDefault)
        // Failed read retries after a minute, not every list read.
        XCTAssertEqual(cache.settings(profile: "a", now: t0.addingTimeInterval(30)) { reads += 1; return owner }, .teamsDefault)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(cache.settings(profile: "a", now: t0.addingTimeInterval(61)) { reads += 1; return owner }, owner)
        XCTAssertEqual(reads, 2)
        // Fresh for 5 minutes: no read.
        XCTAssertEqual(cache.settings(profile: "a", now: t0.addingTimeInterval(300)) { reads += 1; return nil }, owner)
        XCTAssertEqual(reads, 2)
        // Due again but the read fails: the last read stays (no flip to defaults).
        XCTAssertEqual(cache.settings(profile: "a", now: t0.addingTimeInterval(400)) { reads += 1; return nil }, owner)
        XCTAssertEqual(reads, 3)
        // Per account.
        XCTAssertNil(cache.known(profile: "b"))
        // A relaunch starts from the stored value, so a failed first read keeps it.
        let relaunched = MeetingChatSettingsCache(persistPath: path)
        XCTAssertEqual(relaunched.known(profile: "a"), owner)
        XCTAssertEqual(relaunched.settings(profile: "a", now: t0) { nil }, owner)
        // Memory-only caches write nothing.
        let mem = MeetingChatSettingsCache()
        _ = mem.settings(profile: "a", now: t0) { owner }
        XCTAssertEqual(mem.known(profile: "a"), owner)
    }
}

// MARK: R1 end to end with the chat-list read and the send/join write

extension FfiLaterB4ChatsTests {
    static let propsURL = "\(svcBase)/v1/users/ME/properties"

    func meetingConv(_ id: String, rsvp: String, alerts: String? = nil) -> String {
        let a = alerts.map { #""alerts":"\#($0)","# } ?? ""
        return #"{"id":"\#(id)","properties":{\#(a)"meetingInfo":"{\"rsvpStatus\":\"\#(rsvp)\"}"},"threadProperties":{"threadType":"meeting","topic":"Weekly sync","creator":"8:orgid:bbbbbbbb-1111-2222-3333-444444444444"},"lastMessage":{"id":"1760000000100","messagetype":"RichText/Html","content":"hi","imdisplayname":"Emma Clark","from":"https://h/v1/users/ME/contacts/8:orgid:bbbbbbbb-1111-2222-3333-444444444444"}}"#
    }

    func testChatListAppliesTheOwnersMeetingChatSetting() throws {
        signIn()
        let tentative = "19:meeting_AAA@thread.v2", accepted = "19:meeting_BBB@thread.v2"
        http.routes[csaURL()] = (200, #"{"conversations":["# + [meetingConv(tentative, rsvp: "Tentative"),
                                                                    meetingConv(accepted, rsvp: "Accepted")].joined(separator: ",") + "]}")
        http.routes["https://graph.microsoft.com/v1.0/me"] = (200, #"{"id":"aaaaaaaa-1111-2222-3333-444444444444","displayName":"Owner Name"}"#)
        // Owner: tentative meetings unmuted, accepted meetings muted.
        http.routes[Self.propsURL] = (200, ChatSync3SettingsTests.properties(
            #"{"meetingChatNotificationForAcceptedMeetings":"MeetingsManuallyUnmuted","meetingChatNotificationForTentativeMeetings":"MeetingsUserIsInvitedTo"}"#))
        let c = ctx()
        let r = try CoreReads.chats(limit: 20, ctx: c)
        let byID = Dictionary(uniqueKeysWithValues: r.chats.map { ($0.id, $0.muted) })
        XCTAssertEqual(byID[tentative], false, "owner unmutes tentative meeting chats")
        XCTAssertEqual(byID[accepted], true, "owner mutes accepted meeting chats")
        // One settings read for the page, none on the next poll (5 min interval).
        _ = try CoreReads.chats(limit: 20, ctx: c)
        XCTAssertEqual(http.urls.filter { $0 == Self.propsURL }.count, 1)
        // The settings read carries the chat service token.
        XCTAssertEqual(http.calls.first { $0.url == Self.propsURL }?.headers["Authentication"], "skypetoken=FIXTURE-SKYPE")
    }

    func testChatListWithUnreadableSettingUsesTeamsDefault() throws {
        signIn()
        let tentative = "19:meeting_AAA@thread.v2", accepted = "19:meeting_BBB@thread.v2"
        http.routes[csaURL()] = (200, #"{"conversations":["# + [meetingConv(tentative, rsvp: "Tentative"),
                                                                    meetingConv(accepted, rsvp: "Accepted")].joined(separator: ",") + "]}")
        http.routes["https://graph.microsoft.com/v1.0/me"] = (200, #"{"id":"aaaaaaaa-1111-2222-3333-444444444444","displayName":"Owner Name"}"#)
        http.routes[Self.propsURL] = (503, "")
        let r = try CoreReads.chats(limit: 20, ctx: ctx())
        let byID = Dictionary(uniqueKeysWithValues: r.chats.map { ($0.id, $0.muted) })
        XCTAssertEqual(byID[tentative], true, "Teams default: until I join or send")
        XCTAssertEqual(byID[accepted], false)
    }

    func testChatListWithoutAlertslessMeetingChatsSkipsTheSettingsRead() throws {
        signIn()
        http.routes[csaURL()] = (200, #"{"conversations":["# + meetingConv("19:meeting_AAA@thread.v2", rsvp: "None", alerts: "true") + "]}")
        http.routes["https://graph.microsoft.com/v1.0/me"] = (200, #"{"id":"aaaaaaaa-1111-2222-3333-444444444444","displayName":"Owner Name"}"#)
        _ = try CoreReads.chats(limit: 20, ctx: ctx())
        XCTAssertFalse(http.urls.contains(Self.propsURL))
    }

    func testSendOrJoinWritesAlertsOnlyWhenTeamsWould() {
        signIn()
        let id = "19:meeting_AAA@thread.v2"
        let convURL = "\(Self.svcBase)/v1/users/ME/conversations/\(id)"
        http.routes[Self.propsURL] = (200, ChatSync3SettingsTests.properties(nil)) // owner = Teams defaults
        final class Puts: @unchecked Sendable {
            let lock = NSLock(); var bodies: [String] = []
            func add(_ s: String) { lock.withLock { bodies.append(s) } }
        }
        func run(_ a: ChatMuteRule.Activity, rsvp: String, alerts: String? = nil, chat: String = id) -> [String] {
            http.routes["\(Self.svcBase)/v1/users/ME/conversations/\(chat)"] = (200, meetingConv(chat, rsvp: rsvp, alerts: alerts))
            let puts = Puts()
            _ = MeetingChatUnmute.run(a, chatID: chat, profile: "default", ctx: ctx(), cache: MeetingChatSettingsCache()) { pid, body in
                XCTAssertEqual(pid, chat)
                puts.add(String(decoding: body, as: UTF8.self))
            }
            return puts.bodies
        }
        XCTAssertEqual(run(.send, rsvp: "None"), [#"{"alerts":"true"}"#], "until I join or send: a send turns it on")
        XCTAssertEqual(run(.join, rsvp: "Tentative"), [#"{"alerts":"true"}"#])
        XCTAssertEqual(run(.send, rsvp: "Accepted"), [], "already unmuted")
        XCTAssertEqual(run(.send, rsvp: "None", alerts: "false"), [], "muted by hand stays muted")
        XCTAssertEqual(run(.send, rsvp: "Follow"), [])
        XCTAssertEqual(run(.join, rsvp: "Follow"), [#"{"alerts":"true"}"#])
        // Not a meeting chat: no read at all.
        let before = http.urls.count
        XCTAssertEqual(run(.send, rsvp: "None", chat: "19:grp@thread.v2"), [])
        XCTAssertEqual(http.urls.count, before + 0, "plain chats never read")
        XCTAssertTrue(http.urls.contains(convURL))
    }
}
