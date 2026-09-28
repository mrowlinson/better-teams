// NotifLiveTests — om-notif-live: trouter event → rules → posted
// notification, replayed end to end from a recorded typed-poll
// envelope. Injected fixtures only — no live network, no center.
import XCTest

@testable import OstMacCore

final class NotifLiveTests: XCTestCase {
    /// Recorded ostmac_trouter_poll_typed shape: one plain message.
    func pollJSON() -> Data {
        """
        {"ok":true,"resync":false,"skipped":0,"messages":[
        {"chat_id":"19:abc@thread.v2","id":"m9","sender":"Ava Lindqvist",
         "sender_id":"8:orgid:ava","text":"Are we still on for 10?",
         "time":"2026-09-24T05:00:00Z","is_edit":false,
         "message_type":"Text"}]}
        """.data(using: .utf8)!
    }

    func config(_ rules: [NotifyRule] = []) -> RulesConfig {
        var c = RulesConfig(
            owner: RulesOwner(displayName: "Me", mri: "8:orgid:me"))
        c.notifyRules = rules
        c.applyRules()
        return c
    }

    /// Full replay: poll → feed → rules → note → post → delivered.
    func testReplayPostsBanner() async throws {
        let poll = try decodeOrThrow(RealtimePoll.self, from: pollJSON())
        let feed = RealtimeFeed(poll: { poll })
        let gotBox = LockedBox<[RealtimeMessage]>([])
        feed.subscribe { m in gotBox.mutate { $0.append(m) } }
        let r = try feed.pollOnce()
        let got = gotBox.value
        XCTAssertEqual(r.messages, 1)
        XCTAssertEqual(got.count, 1)
        let decision = ChatFilter.decide(
            message: got[0], chatDisplayName: "Ava Lindqvist",
            ownerMRI: "8:orgid:me", rules: config())
        XCTAssertEqual(decision, .notify(reason: "chat-message"))
        guard case .notify(let reason) = decision else {
            return XCTFail("expected notify")
        }
        let note = MessageNotifications.makeRulesNote(
            for: got[0], chatName: "Ava Lindqvist", reason: reason)
        XCTAssertEqual(note.title, "Ava Lindqvist")
        XCTAssertEqual(note.body, "Are we still on for 10?")
        let fake = FakeNotificationCenter()
        await fake.post(note)
        let delivered = await fake.delivered()
        XCTAssertEqual(delivered, [note])
    }

    /// Same replay with a skip-own rule: an own echo never posts.
    func testReplaySkipsOwnEcho() throws {
        let data = """
        {"ok":true,"resync":false,"skipped":0,"messages":[
        {"chat_id":"19:abc@thread.v2","id":"m10","sender":"Me",
         "sender_id":"8:orgid:me","text":"on my way",
         "time":"2026-09-24T05:01:00Z","is_edit":false,
         "message_type":"Text"}]}
        """.data(using: .utf8)!
        let poll = try decodeOrThrow(RealtimePoll.self, from: data)
        let c = config([NotifyRule(kind: NotifyRule.skipMyMessages)])
        let d = ChatFilter.decide(
            message: poll.messages[0], chatDisplayName: "Ava Lindqvist",
            ownerMRI: "8:orgid:me", rules: c)
        XCTAssertEqual(d, .skip(reason: "own-message"))
    }

    /// Meeting burst replays collapse: the first beacon notifies (with
    /// the synthesized body), the repeat folds.
    func testReplayMeetingBurstCollapses() throws {
        let data = """
        {"ok":true,"resync":false,"skipped":0,"messages":[
        {"chat_id":"19:meeting_abc@thread.v2","id":"b1","sender":"?",
         "text":"Design SyncPlay",
         "time":"2026-09-24T05:02:00Z","is_edit":false,
         "message_type":"Text"},
        {"chat_id":"19:meeting_abc@thread.v2","id":"b2","sender":"?",
         "text":"Design SyncPlay",
         "time":"2026-09-24T05:02:05Z","is_edit":false,
         "message_type":"Text"}]}
        """.data(using: .utf8)!
        let poll = try decodeOrThrow(RealtimePoll.self, from: data)
        var dedup = MeetingStartDedup()
        let now = Date(timeIntervalSince1970: 1_758_000_000)
        let c = config()
        let d1 = ChatFilter.decide(
            message: poll.messages[0], chatDisplayName: "Design Sync",
            ownerMRI: "8:orgid:me", rules: c, meetingDedup: &dedup, now: now)
        XCTAssertEqual(d1, .notify(reason: ChatFilter.meetingStartingReason))
        guard case .notify(let reason) = d1 else {
            return XCTFail("expected notify")
        }
        let note = MessageNotifications.makeRulesNote(
            for: poll.messages[0], chatName: "Design Sync", reason: reason)
        XCTAssertEqual(note.title, "Design Sync")
        XCTAssertEqual(note.body, "Meeting starting: Design Sync")
        let d2 = ChatFilter.decide(
            message: poll.messages[1], chatDisplayName: "Design Sync",
            ownerMRI: "8:orgid:me", rules: c, meetingDedup: &dedup,
            now: now.addingTimeInterval(5))
        XCTAssertEqual(d2, .skip(reason: "meeting-start-suppressed"))
    }
}
