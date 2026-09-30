// ChatSync2bTests.swift — CHATSYNC2b with fake transports: Teams mute
// rule for meeting chats (R2), delete-chat gating by the Teams messaging
// policy (R1), pushed read positions (R3), pop-out chat views (R4),
// message-level Mark as unread held while the chat stays open (R5), and
// ReadSync resend + idle chain pruning (R6). Zero network.
import Foundation
import XCTest
@testable import OstMacCore

/// Property writer that fails chosen writes and counts every attempt.
final class FlakyPropertyWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var _puts: [(name: String, value: String)] = []
    private var _attempts = 0
    /// Fails a horizon write while this returns true (argument: its value).
    var failHorizon: @Sendable (String) -> Bool = { _ in false }

    var puts: [(name: String, value: String)] { lock.withLock { _puts } }
    var attempts: Int { lock.withLock { _attempts } }
    var horizons: [String] { puts.filter { $0.name == "consumptionhorizon" }.map(\.value) }

    var writer: ReadSync.Writer {
        { [self] _, name, body in
            let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let value = (obj?[name]).map { "\($0)" } ?? ""
            let fail = name == "consumptionhorizon" && failHorizon(value)
            lock.withLock {
                _attempts += 1
                if !fail { _puts.append((name, value)) }
            }
            if fail { throw CoreCallError.failed("read_state: \(name) HTTP 500") }
        }
    }
}

@MainActor
final class ChatSync2bTests: XCTestCase {
    let chat = "19:a_b@unq.gbl.spaces"
    let meeting = "19:meeting_MzA5@thread.v2"
    let open = ReadViewGate(isOpen: true, windowActive: true, atLatest: true, loaded: true)

    func msg(_ id: String, cid: String? = nil) -> ChatMessage {
        ChatMessage(id: id, sender: "Emma Clark", timestamp: "", content: "hi", clientMessageID: cid)
    }

    func sync(_ w: FlakyPropertyWriter) -> ReadSync {
        let s = ReadSync(writer: w.writer, now: { 1_760_000_000_999 })
        s.retryDelayNs = 0
        return s
    }

    /// Waits (bounded) until `done` holds; the retry runs on its own task.
    func settle(_ done: @escaping () -> Bool) async {
        for _ in 0 ..< 300 where !done() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    // MARK: R2 mute

    func testMuteRuleFollowsTeamsWorker() {
        let info: (String) -> String = { #"{"rsvpStatus":"\#($0)","isOrganizer":false}"# }
        // `alerts` decides whenever present, meeting or not.
        XCTAssertTrue(ChatMuteRule.isMuted(chatID: chat, alerts: "false", meetingInfo: nil, creatorIsSelf: false))
        XCTAssertFalse(ChatMuteRule.isMuted(chatID: meeting, alerts: "true", meetingInfo: info("None"), creatorIsSelf: false))
        // Plain chats without it: not muted.
        XCTAssertFalse(ChatMuteRule.isMuted(chatID: chat, alerts: nil, meetingInfo: nil, creatorIsSelf: false))
        XCTAssertFalse(ChatMuteRule.isMuted(chatID: "19:abc@thread.v2", alerts: nil, meetingInfo: nil, creatorIsSelf: false))
        // Meeting chats without it: RSVP + Teams defaults; organizer never.
        XCTAssertTrue(ChatMuteRule.isMuted(chatID: meeting, alerts: nil, meetingInfo: info("None"), creatorIsSelf: false))
        XCTAssertTrue(ChatMuteRule.isMuted(chatID: meeting, alerts: nil, meetingInfo: nil, creatorIsSelf: false))
        XCTAssertTrue(ChatMuteRule.isMuted(chatID: meeting, alerts: nil, meetingInfo: info("Tentative"), creatorIsSelf: false))
        XCTAssertTrue(ChatMuteRule.isMuted(chatID: meeting, alerts: nil, meetingInfo: info("Declined"), creatorIsSelf: false))
        XCTAssertTrue(ChatMuteRule.isMuted(chatID: meeting, alerts: nil, meetingInfo: info("Follow"), creatorIsSelf: false))
        XCTAssertFalse(ChatMuteRule.isMuted(chatID: meeting, alerts: nil, meetingInfo: info("Accepted"), creatorIsSelf: false))
        XCTAssertFalse(ChatMuteRule.isMuted(chatID: meeting, alerts: nil, meetingInfo: info("None"), creatorIsSelf: true))
        XCTAssertTrue(ChatMuteRule.isMuted(chatID: "19:gcch:meeting_x@thread.v2", alerts: nil, meetingInfo: nil, creatorIsSelf: false))
        // The two Teams settings flip the defaults.
        let loud = ChatMuteRule.Settings(acceptedMeetings: .invitedTo, tentativeMeetings: .invitedTo)
        XCTAssertFalse(ChatMuteRule.isMuted(chatID: meeting, alerts: nil, meetingInfo: info("Tentative"),
                                            creatorIsSelf: false, settings: loud))
        let quiet = ChatMuteRule.Settings(acceptedMeetings: .participatesIn)
        XCTAssertTrue(ChatMuteRule.isMuted(chatID: meeting, alerts: nil, meetingInfo: info("Accepted"),
                                           creatorIsSelf: false, settings: quiet))
        XCTAssertEqual(ChatMuteRule.rsvpStatus(meetingInfo: "not json"), "None")
    }
}

// R2 end to end: the chat-list read maps a meeting chat without `alerts`
// to muted (the owner's case: Teams shows it muted, the app did not),
// the organizer's own meeting chat to not muted, and leaves plain chats
// without `alerts` unknown.
extension FfiLaterB4ChatsTests {
    func testMeetingChatsWithoutAlertsTakeTeamsMuteDefault() throws {
        signIn()
        let me = "aaaaaaaa-1111-2222-3333-444444444444"
        let other = "bbbbbbbb-1111-2222-3333-444444444444"
        func conv(_ id: String, topic: String, props: String, tp: String = "") -> String {
            #"{"id":"\#(id)","properties":{\#(props)},"threadProperties":{"threadType":"meeting","topic":"\#(topic)"\#(tp)},"lastMessage":{"id":"1760000000100","messagetype":"RichText/Html","content":"hi","imdisplayname":"Emma Clark","from":"https://h/v1/users/ME/contacts/8:orgid:\#(other)"}}"#
        }
        let invited = conv("19:meeting_AAA@thread.v2", topic: "Weekly sync",
                           props: #""meetingInfo":"{\"rsvpStatus\":\"None\"}""#,
                           tp: #","creator":"8:orgid:\#(other)""#)
        let organized = conv("19:meeting_BBB@thread.v2", topic: "Planning", props: #""lastimreceivedtime":"x""#,
                             tp: #","isCreator":"true""#)
        let byMri = conv("19:meeting_CCC@thread.v2", topic: "Review", props: #""lastimreceivedtime":"x""#,
                         tp: #","creator":"8:orgid:\#(me)""#)
        let unmuted = conv("19:meeting_DDD@thread.v2", topic: "Retro", props: #""alerts":"true""#)
        let group = #"{"id":"19:grp@thread.v2","properties":{"lastimreceivedtime":"x"},"threadProperties":{"threadType":"chat","topic":"Team lunch"},"lastMessage":{"id":"1760000000100","messagetype":"RichText/Html","content":"hi","imdisplayname":"Emma Clark","from":"https://h/v1/users/ME/contacts/8:orgid:\#(other)"}}"#
        http.routes[csaURL()] = (200, #"{"conversations":["# + [invited, organized, byMri, unmuted, group].joined(separator: ",") + "]}")
        http.routes["https://graph.microsoft.com/v1.0/me"] = (200, #"{"id":"\#(me)","displayName":"Owner Name"}"#)
        // CHATSYNC3: the owner's settings unreadable here -> Teams' defaults.
        http.routes["\(Self.svcBase)/v1/users/ME/properties"] = (404, "")
        let r = try CoreReads.chats(limit: 20, ctx: ctx())
        let byID = Dictionary(uniqueKeysWithValues: r.chats.map { ($0.id, $0) })
        XCTAssertEqual(byID["19:meeting_AAA@thread.v2"]?.muted, true, "invited meeting chat, no alerts: muted like Teams")
        XCTAssertEqual(byID["19:meeting_AAA@thread.v2"]?.is_creator, false)
        XCTAssertEqual(byID["19:meeting_BBB@thread.v2"]?.muted, false, "organizer's meeting chat")
        XCTAssertEqual(byID["19:meeting_BBB@thread.v2"]?.is_creator, true)
        XCTAssertEqual(byID["19:meeting_CCC@thread.v2"]?.is_creator, true, "creator MRI = owner")
        XCTAssertEqual(byID["19:meeting_CCC@thread.v2"]?.muted, false)
        XCTAssertEqual(byID["19:meeting_DDD@thread.v2"]?.muted, false, "explicit alerts wins")
        XCTAssertNil(byID["19:grp@thread.v2"]?.muted, "plain chat without alerts: unknown, as before")
    }
}

// MARK: R1 delete gating

extension ChatSync2bTests {
    func testDeleteFollowsTeamsPolicyAndOrganizer() {
        let self1 = "48:notes"
        func can(_ id: String, group: Bool = false, organizer: Bool = false, _ p: ChatDeleteRule.Policy) -> Bool {
            ChatDeleteRule.canDelete(chatID: id, isGroup: group, isMeetingOrganizer: organizer, policy: p)
        }
        // Allowed: 1:1, group, meeting chats the owner did not organize.
        XCTAssertTrue(can(chat, .allowed))
        XCTAssertTrue(can("19:grp@thread.v2", group: true, .allowed))
        XCTAssertTrue(can(meeting, group: true, .allowed))
        XCTAssertFalse(can(meeting, group: true, organizer: true, .allowed))
        // Denied: none. Unknown: 1:1 only.
        XCTAssertFalse(can(chat, .denied))
        XCTAssertFalse(can("19:grp@thread.v2", group: true, .denied))
        XCTAssertTrue(can(chat, .unknown))
        XCTAssertFalse(can("19:grp@thread.v2", group: true, .unknown))
        XCTAssertFalse(can(meeting, group: true, .unknown))
        // Never the chat with yourself, never an empty id.
        XCTAssertFalse(can(self1, .allowed))
        XCTAssertFalse(can("  ", .allowed))
    }

    func testMessagingPolicyReplyParsing() {
        func policy(_ status: Int, _ body: String) -> ChatDeleteRule.Policy {
            MessagingPolicyReader.policy(MessagingPolicyReader.parse(status: status, data: Data(body.utf8)))
        }
        XCTAssertEqual(policy(200, #"{"messagingPolicy":{"value":{"allowUserDeleteChat":true,"allowUserEditMessage":true},"resultCode":"Success"}}"#), .allowed)
        XCTAssertEqual(policy(200, #"{"messagingPolicy":{"value":{"allowUserDeleteChat":false},"resultCode":"Success"}}"#), .denied)
        XCTAssertEqual(policy(200, #"{"messagingPolicy":{"value":{"allowUserEditMessage":true},"resultCode":"Success"}}"#),
                       .denied, "namespace read, flag absent = Teams default false")
        XCTAssertEqual(policy(200, #"{"messagingPolicy":{"resultCode":"Failure"}}"#), .unknown)
        XCTAssertEqual(policy(500, #"{"messagingPolicy":{"value":{"allowUserDeleteChat":true}}}"#), .unknown)
        XCTAssertEqual(policy(200, "not json"), .unknown)
        XCTAssertEqual(MessagingPolicyReader.url(middleTier: "https://teams.microsoft.com/api/mt/emea/")?.absoluteString,
                       "https://teams.microsoft.com/api/mt/emea/beta/users/useraggregatesettings")
        XCTAssertEqual(MessagingPolicyReader.url(middleTier: nil)?.absoluteString,
                       "https://teams.microsoft.com/api/mt/amer/beta/users/useraggregatesettings")
    }

    func testMessagingPolicyReadIsTheTeamsPost() throws {
        let http = StubCalendarHTTP([(200, #"{"messagingPolicy":{"value":{"allowUserDeleteChat":true},"resultCode":"Success"}}"#)])
        let now: UInt64 = 1_760_000_000
        let slots = TokenSlots(accessToken: StoredTokenValue(token: "FIXTURE-AAD", now: now, expiresIn: 3_600),
                               skypeToken: StoredTokenValue(token: "FIXTURE-SKYPE", now: now, expiresIn: 3_600),
                               regionGtms: #"{"middleTier":"https://teams.microsoft.com/api/mt/emea"}"#)
        let raw = MessagingPolicyReader.fetchRaw(slots: slots, now: now, http: http)
        XCTAssertEqual(MessagingPolicyReader.policy(raw), .allowed)
        let sent = try XCTUnwrap(http.sent.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.url.absoluteString, "https://teams.microsoft.com/api/mt/emea/beta/users/useraggregatesettings")
        XCTAssertEqual(sent.body?["messagingPolicy"] as? Bool, true)
        XCTAssertEqual(sent.headers["Authorization"], "Bearer FIXTURE-AAD")
        XCTAssertEqual(sent.headers["X-Skypetoken"], "FIXTURE-SKYPE")
        // Stale tokens: no request, unknown.
        let stale = StubCalendarHTTP([])
        let old = MessagingPolicyReader.fetchRaw(slots: slots, now: now + 7_200, http: stale)
        XCTAssertEqual(MessagingPolicyReader.policy(old), .unknown)
        XCTAssertTrue(stale.sent.isEmpty)
    }

    func testChatListOffersDeleteByPolicy() async {
        let rows = [
            ChatItem(chatId: chat, name: "Oliver Bennett"),
            ChatItem(chatId: "19:grp@thread.v2", name: "Team lunch", is_group: true),
            ChatItem(chatId: meeting, name: "Weekly sync", is_group: true, is_creator: false),
            ChatItem(chatId: "19:meeting_own@thread.v2", name: "Planning", is_group: true, is_creator: true),
        ]
        let model = ChatListViewModel(fetcher: { _ in ChatsResponse(ok: true, chats: rows) })
        await model.load()
        XCTAssertEqual(model.deletePolicy, .unknown)
        XCTAssertEqual(rows.map { model.canDelete($0.id) }, [true, false, false, false])
        model.deletePolicy = .allowed
        XCTAssertEqual(rows.map { model.canDelete($0.id) }, [true, true, true, false])
        model.deletePolicy = .denied
        XCTAssertEqual(rows.map { model.canDelete($0.id) }, [false, false, false, false])
        XCTAssertFalse(model.canDelete("19:missing@thread.v2"))
    }
}

// MARK: R3 pushed read state

extension ChatSync2bTests {
    static let owner = "aaaaaaaa-1111-2222-3333-444444444444"
    static let mateFrom = "https://h/v1/users/ME/contacts/8:orgid:bbbbbbbb-1111-2222-3333-444444444444"

    func push(horizon: String?, bookmark: String? = nil, from: String = mateFrom,
              type: String = "RichText/Html", time: String? = "2025-10-09T08:53:30.000Z") -> ReadStateEvent {
        ReadStateEvent(chatID: chat, horizon: horizon, bookmark: bookmark, lastMessageID: "1760000000100",
                       lastMessageTime: "2025-10-09T08:53:20.100Z", lastMessageType: type,
                       lastMessageFrom: from, time: time)
    }

    func testPollEnvelopeCarriesReadStates() throws {
        let json = #"{"ok":true,"messages":[],"resync":false,"skipped":0,"read_states":[{"chat_id":"19:a_b@unq.gbl.spaces","horizon":"1760000000100;1760000000999;0","bookmark":"0;1760000000999;0","last_message_id":"1760000000100","last_message_time":"2025-10-09T08:53:20.100Z","last_message_type":"RichText/Html","time":"2025-10-09T08:53:30.000Z"}]}"#
        let p = try JSONDecoder().decode(RealtimePoll.self, from: Data(json.utf8))
        XCTAssertEqual(p.readStates?.count, 1)
        XCTAssertEqual(p.readStates?.first?.chatID, chat)
        XCTAssertEqual(p.readStates?.first?.bookmark, "0;1760000000999;0")
        XCTAssertNil(p.readStates?.first?.lastMessageFrom)
        // Older cores: no key, no events.
        let old = #"{"ok":true,"messages":[],"resync":false,"skipped":0}"#
        XCTAssertNil(try JSONDecoder().decode(RealtimePoll.self, from: Data(old.utf8)).readStates)

        let got = LockedBox<[ReadStateEvent]>([])
        var poll = RealtimePoll(ok: true, messages: [], resync: false, skipped: 0)
        poll.readStates = [push(horizon: "1760000000100;1760000000999;0")]
        let pinned = poll
        let feed = RealtimeFeed(poll: { pinned },
                                pollWait: { _ in RealtimePoll(ok: true, messages: [], resync: false, skipped: 0) },
                                start: { 0 }, stop: { 0 })
        feed.onReadState { evs in got.mutate { $0 += evs } }
        _ = try feed.pollOnce()
        XCTAssertEqual(got.value.map(\.chatID), [chat])
    }

    func testPushedSeedMatchesFetchedVerdict() throws {
        let behind = "1760000000050;1760000000060;0", covering = "1760000000100;1760000000999;0"
        // Read elsewhere / unread elsewhere.
        XCTAssertEqual(ChatListSeed.pushedSeed(push(horizon: covering), ownerOID: Self.owner, muted: false)?.unread, false)
        XCTAssertEqual(ChatListSeed.pushedSeed(push(horizon: behind), ownerOID: Self.owner, muted: false)?.unread, true)
        // Own message or a control message never makes it unread.
        let mine = "https://h/v1/users/ME/contacts/8:orgid:\(Self.owner)"
        XCTAssertEqual(ChatListSeed.pushedSeed(push(horizon: behind, from: mine), ownerOID: Self.owner, muted: false)?.unread, false)
        XCTAssertEqual(ChatListSeed.pushedSeed(push(horizon: behind, type: "ThreadActivity/AddMember"),
                                               ownerOID: Self.owner, muted: false)?.unread, false)
        // Marked unread elsewhere (bookmark behind the newest message).
        let marked = try XCTUnwrap(ChatListSeed.pushedSeed(push(horizon: covering, bookmark: "1760000000099;1760000000999;0"),
                                                           ownerOID: Self.owner, muted: true))
        XCTAssertTrue(marked.markedUnread)
        XCTAssertTrue(marked.unread)
        XCTAssertTrue(marked.muted)
        // Cleared bookmark: not marked.
        XCTAssertEqual(ChatListSeed.pushedSeed(push(horizon: covering, bookmark: "0;1760000000999;0"),
                                               ownerOID: Self.owner, muted: false)?.markedUnread, false)
        // No owner identity or no horizon: no verdict unless marked.
        XCTAssertNil(ChatListSeed.pushedSeed(push(horizon: behind), ownerOID: nil, muted: false))
        XCTAssertNil(ChatListSeed.pushedSeed(push(horizon: nil), ownerOID: Self.owner, muted: false))
        XCTAssertEqual(ChatListSeed.pushedSeed(push(horizon: nil, bookmark: "1760000000099;1;0"),
                                               ownerOID: nil, muted: false)?.markedUnread, true)
    }

    // Pushes flip only the changed row, in server-time order: a local
    // change made after the pushed event stays.
    func testPushedSeedsDriveUnreadRowsInServerOrder() throws {
        let store = UnreadStore(dock: FakeDockBadge())
        let covering = "1760000000100;1760000000999;0"
        let t0 = try XCTUnwrap(ChatListFormat.parse("2025-10-09T08:53:30.000Z"))
        // Marked unread on another client → row unread.
        let marked = try XCTUnwrap(ChatListSeed.pushedSeed(push(horizon: covering, bookmark: "1760000000099;1760000000999;0"),
                                                           ownerOID: Self.owner, muted: false))
        store.seed([marked], asOf: t0)
        XCTAssertTrue(store.isUnread(chatID: chat))
        // Read there later → row read.
        let read = try XCTUnwrap(ChatListSeed.pushedSeed(push(horizon: covering, bookmark: "0;1760000000999;0"),
                                                         ownerOID: Self.owner, muted: false))
        store.seed([read], asOf: t0.addingTimeInterval(5))
        XCTAssertFalse(store.isUnread(chatID: chat))
        // Owner marks unread here now; a push from before that must not undo it.
        store.markUnread(chatID: chat)
        store.seed([read], asOf: t0.addingTimeInterval(6))
        XCTAssertTrue(store.isUnread(chatID: chat), "stale push kept the newer local mark")
        // The ISO event time Teams sends parses (7 fractional digits or 3).
        XCTAssertNotNil(ChatListFormat.parse("2025-10-09T08:53:30.1234567Z"))
    }
    // Feed -> row: ChatSync3BehaviorTests.testConversationUpdatePushUpdatesTheChatRow.
}

// MARK: R4 pop out chat, R5 message-level Mark as unread

extension ChatSync2bTests {
    // Pop-out open/key-window rules and the row/message menus:
    // ChatSync3BehaviorTests (behavioral, CHATSYNC3 R4).

    // R5: Teams keeps a chat marked unread from an open chat unread while
    // it stays open (bookmark at the newest message; views of that same
    // message do not re-mark it). A newer message, or leaving the chat
    // and coming back, reads it again.
    func testMarkUnreadWhileOpenHoldsUntilNewerMessageOrLeave() async throws {
        let w = FlakyPropertyWriter(), s = sync(w)
        await s.viewed(chatID: chat, messages: [msg("1760000000300", cid: "33")], gate: open)?.value
        try await s.markUnread(chatID: chat, lastMessageMs: 1_760_000_000_300, clientMessageID: "33", holdWhileOpen: true)
        XCTAssertEqual(w.puts.last?.name, "consumptionHorizonBookmark")
        XCTAssertEqual(w.puts.last?.value, "1760000000299;1760000000999;33")
        // Same newest message on screen: nothing written, stays unread.
        XCTAssertNil(s.viewed(chatID: chat, messages: [msg("1760000000300", cid: "33")], gate: open))
        XCTAssertEqual(s.holds[chat], 1_760_000_000_300)
        // A newer message: read again (horizon + bookmark cleared).
        await s.viewed(chatID: chat, messages: [msg("1760000000400")], gate: open)?.value
        XCTAssertEqual(w.puts.suffix(2).map(\.name), ["consumptionhorizon", "consumptionHorizonBookmark"])
        XCTAssertNil(s.holds[chat])

        // Leaving the chat drops the hold: the next view reads it.
        try await s.markUnread(chatID: chat, lastMessageMs: 1_760_000_000_400, holdWhileOpen: true)
        XCTAssertNil(s.viewed(chatID: chat, messages: [msg("1760000000400")], gate: open))
        s.releaseHolds(keeping: [chat])
        XCTAssertNotNil(s.holds[chat], "still open: kept")
        s.releaseHolds(keeping: [])
        let before = w.puts.count
        await s.viewed(chatID: chat, messages: [msg("1760000000400")], gate: open)?.value
        XCTAssertEqual(w.puts.count, before + 2)
        XCTAssertEqual(w.puts.last?.value, "0;1760000000999;0")

        // A failed mark keeps no hold.
        let s2 = ReadSync(writer: { _, _, _ in throw CoreCallError.failed("HTTP 500") }, now: { 1_760_000_000_999 })
        do { try await s2.markUnread(chatID: chat, lastMessageMs: 1, holdWhileOpen: true); XCTFail("threw") } catch {}
        XCTAssertNil(s2.holds[chat])
    }
}

// MARK: R6 resend + chain pruning

extension ChatSync2bTests {
    // A newer position whose write fails is resent (not left until the
    // next view), and the chat's chain is gone once idle.
    func testFailedNewerHorizonIsResent() async {
        let w = FlakyPropertyWriter(), s = sync(w)
        await s.viewed(chatID: chat, messages: [msg("1760000000100")], gate: open)?.value
        let failed = LockedBox(false)
        w.failHorizon = { v in
            guard v.hasPrefix("1760000000200"), !failed.value else { return false }
            failed.mutate { $0 = true }
            return true
        }
        await s.viewed(chatID: chat, messages: [msg("1760000000200", cid: "22")], gate: open)?.value
        await settle { w.horizons.count == 2 && s.activeChains == 0 }
        XCTAssertEqual(w.horizons, ["1760000000100;1760000000999;0", "1760000000200;1760000000999;22"])
        XCTAssertEqual(s.retries, 1)
        XCTAssertEqual(s.readThrough[chat], 1_760_000_000_200)
        XCTAssertEqual(s.activeChains, 0, "idle chain pruned")
        // Already acked: the same view sends nothing more.
        XCTAssertNil(s.viewed(chatID: chat, messages: [msg("1760000000200", cid: "22")], gate: open))
    }

    // A resend never undoes a later Mark as Unread (it would clear the
    // bookmark the owner just set).
    func testResendDroppedByLaterMarkUnread() async throws {
        let w = FlakyPropertyWriter(), s = sync(w)
        s.retryDelayNs = 50_000_000
        s.adopt(horizons: [:], markedUnread: [chat], listed: [chat])
        w.failHorizon = { _ in true }
        await s.viewed(chatID: chat, messages: [msg("1760000000100")], gate: open)?.value
        w.failHorizon = { _ in false }
        try await s.markUnread(chatID: chat, lastMessageMs: 1_760_000_000_100, holdWhileOpen: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        await settle { s.activeChains == 0 }
        XCTAssertEqual(w.horizons, [], "no resend after the mark")
        XCTAssertEqual(w.puts.map(\.name), ["consumptionHorizonBookmark"])
        XCTAssertEqual(s.retries, 0)
    }

    func testResendGivesUpAfterMaxRetries() async {
        let w = FlakyPropertyWriter(), s = sync(w)
        w.failHorizon = { _ in true }
        await s.viewed(chatID: chat, messages: [msg("1760000000100")], gate: open)?.value
        await settle { w.attempts == 1 + ReadSync.maxRetries && s.activeChains == 0 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(w.attempts, 1 + ReadSync.maxRetries, "bounded")
        XCTAssertEqual(s.retries, ReadSync.maxRetries)
        XCTAssertNotNil(s.lastError)
        XCTAssertEqual(s.activeChains, 0)
        // Still retryable by the next view once Teams answers again.
        w.failHorizon = { _ in false }
        await s.viewed(chatID: chat, messages: [msg("1760000000100")], gate: open)?.value
        XCTAssertEqual(w.horizons, ["1760000000100;1760000000999;0"])
    }

    func testChainsArePrunedAcrossManyChats() async throws {
        let w = FlakyPropertyWriter(), s = sync(w)
        for i in 0 ..< 20 {
            await s.viewed(chatID: "19:c\(i)@thread.v2", messages: [msg("17600000001\(10 + i)")], gate: open)?.value
            try await s.markUnread(chatID: "19:c\(i)@thread.v2", lastMessageMs: 1_760_000_000_500)
        }
        await settle { s.activeChains == 0 }
        XCTAssertEqual(s.activeChains, 0)
        XCTAssertEqual(w.puts.count, 40)
    }
}
