// Realtime feed tests: typed envelope decode, dedupe, resync, backoff.
import XCTest

@testable import OstMacCore

final class RealtimeTests: XCTestCase {
    func pollFixture() throws -> RealtimePoll {
        let json = """
        {"ok":true,"resync":true,"skipped":2,"messages":[
        {"chat_id":"19:abc@thread.v2","id":"111","sender":"Doe, Jane",
         "text":"hi","time":"2026-09-22T14:25:45Z","is_edit":false},
        {"chat_id":"19:abc@thread.v2","id":"222","sender":"Doe, Jane",
         "text":"fixed","time":"2026-09-22T14:26:01Z","is_edit":true,
         "edited_id":"111"}]}
        """
        return try decodeOrThrow(RealtimePoll.self, from: Data(json.utf8))
    }

    func testTypedEnvelopeDecode() throws {
        let p = try pollFixture()
        XCTAssertTrue(p.resync)
        XCTAssertEqual(p.messages.count, 2)
        XCTAssertEqual(p.messages[0].chatID, "19:abc@thread.v2")
        XCTAssertEqual(p.messages[0].msgId, "111")
        XCTAssertEqual(p.messages[0].id, "111")
        XCTAssertFalse(p.messages[0].isEdit)
        XCTAssertTrue(p.messages[1].isEdit)
        XCTAssertEqual(p.messages[1].editedID, "111")
        XCTAssertEqual(p.skipped, 2)
    }

    func testPollOnceDedupesById() throws {
        let p = try pollFixture()
        let calls = LockedBox(0)
        let feed = RealtimeFeed(poll: { calls.mutate { $0 += 1 }; return p })
        let got = LockedBox<[String]>([])
        feed.subscribe { m in got.mutate { $0.append(m.msgId) } }
        let r1 = try feed.pollOnce()
        XCTAssertEqual(r1.messages, 2)
        let r2 = try feed.pollOnce() // same batch redelivered
        XCTAssertEqual(r2.messages, 0)
        XCTAssertEqual(got.value, ["111", "222"])
        XCTAssertEqual(calls.value, 2)
    }

    func testResyncHandlerFires() throws {
        let p = try pollFixture() // resync:true
        let feed = RealtimeFeed(poll: { p })
        let n = LockedBox(0)
        feed.onResync { n.mutate { $0 += 1 } }
        _ = try feed.pollOnce()
        XCTAssertEqual(n.value, 1)
    }

    func testNoResyncNoFire() throws {
        let json = #"{"ok":true,"resync":false,"skipped":0,"messages":[]}"#
        let p = try decodeOrThrow(RealtimePoll.self, from: Data(json.utf8))
        let feed = RealtimeFeed(poll: { p })
        let n = LockedBox(0)
        feed.onResync { n.mutate { $0 += 1 } }
        let r = try feed.pollOnce()
        XCTAssertEqual(r.messages, 0)
        XCTAssertFalse(r.resync)
        XCTAssertEqual(n.value, 0)
    }

    func testUnsubscribe() throws {
        let p = try pollFixture()
        let feed = RealtimeFeed(poll: { p })
        let n = LockedBox(0)
        let t = feed.subscribe { _ in n.mutate { $0 += 1 } }
        feed.unsubscribe(t)
        _ = try feed.pollOnce()
        XCTAssertEqual(n.value, 0)
    }

    func testBackoffSequence() {
        XCTAssertEqual(RealtimeBackoff.delay(forAttempt: 0), 1)
        XCTAssertEqual(RealtimeBackoff.delay(forAttempt: 1), 1)
        XCTAssertEqual(RealtimeBackoff.delay(forAttempt: 2), 2)
        XCTAssertEqual(RealtimeBackoff.delay(forAttempt: 3), 4)
        XCTAssertEqual(RealtimeBackoff.delay(forAttempt: 4), 8)
        XCTAssertEqual(RealtimeBackoff.delay(forAttempt: 5), 16)
        XCTAssertEqual(RealtimeBackoff.delay(forAttempt: 6), 30)
        XCTAssertEqual(RealtimeBackoff.delay(forAttempt: 99), 30)
    }

    func testStartCodeMapping() {
        XCTAssertFalse(RealtimeBackoff.shouldRetry(startCode: 0))
        XCTAssertFalse(RealtimeBackoff.shouldRetry(startCode: -1))
        XCTAssertTrue(RealtimeBackoff.shouldRetry(startCode: -2))
        XCTAssertTrue(RealtimeBackoff.shouldRetry(startCode: -3))
    }

    func testStartStopLifecycle() throws {
        let p = try pollFixture()
        let stops = LockedBox(0)
        let feed = RealtimeFeed(
            poll: { p },
            start: { 0 },
            stop: { stops.mutate { $0 += 1 }; return 0 }
        )
        feed.pollInterval = 60 // no timer fire during test
        feed.start()
        XCTAssertEqual(feed.currentState, .live)
        feed.stop()
        XCTAssertEqual(feed.currentState, .stopped)
        XCTAssertEqual(stops.value, 1)
    }
}
