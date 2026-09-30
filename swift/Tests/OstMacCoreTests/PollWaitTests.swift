// Poll-wait adoption: blocking trouter drain + feed wait loop (1s timer fallback).
import XCTest

@testable import OstMacCore

final class PollWaitTests: XCTestCase {
    // Real core: raw wait with 0 timeout == immediate drain, empty hub.
    func testRawPollWaitZeroTimeout() throws {
        let p = try RustCore.trouterPollWait(timeoutMs: 0)
        XCTAssertTrue(p.ok)
        XCTAssertEqual(p.events.count, 0)
    }

    // Real core: typed wait with 0 timeout == immediate drain, empty hub.
    func testTypedPollWaitZeroTimeout() throws {
        let p = try RustCore.trouterPollTypedWait(timeoutMs: 0)
        XCTAssertTrue(p.ok)
        XCTAssertEqual(p.messages.count, 0)
        XCTAssertFalse(p.resync)
    }

    // Wait loop dispatches one blocking-wait batch like a timer tick.
    func testPollWaitOnceDispatches() throws {
        let msg = RealtimeMessage(
            chatID: "19:w@thread.v2", msgId: "m1", sender: "A",
            text: "hi", time: "2026-09-24T00:00:00Z", isEdit: false)
        let feed = RealtimeFeed(
            pollWait: { _ in RealtimePoll(ok: true, messages: [msg], resync: false, skipped: 0) },
            start: { 0 }, stop: { 0 })
        let got = LockedBox<[String]>([])
        feed.subscribe { m in got.mutate { $0.append(m.msgId) } }
        let r = try feed.pollWaitOnce(timeoutMs: 0)
        XCTAssertEqual(r.messages, 1)
        XCTAssertEqual(got.value, ["m1"])
        XCTAssertEqual(feed.pollCount, 1)
    }

    // Wait failure falls back to the 1s timer loop (feed stays live).
    func testWaitErrorFallsBackToTimer() throws {
        struct Boom: Error {}
        let feed = RealtimeFeed(
            poll: { RealtimePoll(ok: true, messages: [], resync: false, skipped: 0) },
            pollWait: { _ in throw Boom() },
            start: { 0 }, stop: { 0 })
        feed.pollInterval = 60 // timer armed but never fires during test
        feed.start()
        XCTAssertEqual(feed.currentState, .live)
        TestWait.untilBlocking(interval: 0.02) { feed.lastError != nil }
        XCTAssertNotNil(feed.lastError)
        XCTAssertEqual(feed.currentState, .live)
        feed.stop()
        XCTAssertEqual(feed.currentState, .stopped)
    }
}
