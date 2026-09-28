// Call tests: signaling models, typed-poll calls field, feed dispatch,
// demo store transitions. No core/network (pure decode + injected fns).
import XCTest

@testable import OstMacCore

final class CallTests: XCTestCase {
    func testCallInfoDecode() throws {
        let json = """
        {"id":"c1","dir":"in","peer":"8:orgid:aaa","peer_name":"Doe, Jane",
         "thread":"","state":"ringing","started_at":123,
         "detail":"modalities: Audio"}
        """
        let c = try JSONDecoder().decode(CallInfo.self, from: Data(json.utf8))
        XCTAssertEqual(c.id, "c1")
        XCTAssertEqual(c.peerName, "Doe, Jane")
        XCTAssertEqual(c.startedAt, 123)
        XCTAssertTrue(c.isActive)
        XCTAssertEqual(c.displayPeer, "Doe, Jane")
        XCTAssertNil(c.controller)
    }

    func testCallInfoEndedIsInactive() throws {
        let c = CallInfo(
            id: "c1", dir: "out", peer: "8:orgid:aaa", thread: "19:t",
            state: "ended")
        XCTAssertFalse(c.isActive)
        XCTAssertEqual(c.displayPeer, "8:orgid:aaa")
    }

    func testCallStatusNullSlot() throws {
        let s = try decodeOrThrow(
            CallStatus.self, from: Data(#"{"ok":true,"call":null}"#.utf8))
        XCTAssertTrue(s.ok)
        XCTAssertNil(s.call)
    }

    func testCallResultPlaceAccepted() throws {
        let json = """
        {"ok":true,"placed":true,"accepted":true,
         "call":{"id":"c2","dir":"out","peer":"8:orgid:bbb","peer_name":"",
         "thread":"19:t","state":"connected","started_at":7}}
        """
        let r = try decodeOrThrow(CallResult.self, from: Data(json.utf8))
        XCTAssertEqual(r.placed, true)
        XCTAssertEqual(r.accepted, true)
        XCTAssertNil(r.rejection)
        XCTAssertEqual(r.call?.state, "connected")
    }

    func testCallResultRejected() throws {
        let r = try decodeOrThrow(
            CallResult.self,
            from: Data(#"{"ok":true,"placed":true,"accepted":false,"rejection":"Busy"}"#.utf8))
        XCTAssertEqual(r.accepted, false)
        XCTAssertEqual(r.rejection, "Busy")
        XCTAssertNil(r.call)
    }

    func testCallErrorEnvelopeThrows() {
        XCTAssertThrowsError(
            try decodeOrThrow(
                CallResult.self,
                from: Data(#"{"ok":false,"error":"no_incoming","detail":"none"}"#.utf8)))
    }

    func testTypedPollCallsDecode() throws {
        let json = """
        {"ok":true,"resync":false,"skipped":1,"messages":[],
         "calls":[{"kind":"incoming","call_id":"call-9","peer":"8:orgid:aaa",
         "peer_name":"Doe, Jane"}]}
        """
        let p = try decodeOrThrow(RealtimePoll.self, from: Data(json.utf8))
        XCTAssertEqual(p.calls?.count, 1)
        XCTAssertEqual(p.calls?[0].kind, "incoming")
        XCTAssertEqual(p.calls?[0].callID, "call-9")
    }

    func testTypedPollWithoutCallsIsNil() throws {
        // Old core builds omit the key: must still decode.
        let p = try decodeOrThrow(
            RealtimePoll.self,
            from: Data(#"{"ok":true,"resync":false,"skipped":0,"messages":[]}"#.utf8))
        XCTAssertNil(p.calls)
    }

    func testFeedDispatchesCallEvents() throws {
        let p = RealtimePoll(
            ok: true, messages: [], resync: false, skipped: 0,
            calls: [CallEvent(kind: "incoming", callID: "c9", peerName: "Doe, Jane")])
        let feed = RealtimeFeed(poll: { p })
        let got = LockedBox<[CallEvent]>([])
        feed.onCall { ev in got.mutate { $0.append(ev) } }
        _ = try feed.pollOnce()
        XCTAssertEqual(got.value.count, 1)
        XCTAssertEqual(got.value[0].callID, "c9")
        // No subs, no crash; second poll with nil calls dispatches nothing.
        let p2 = RealtimePoll(ok: true, messages: [], resync: false, skipped: 0)
        let feed2 = RealtimeFeed(poll: { p2 })
        let n = LockedBox(0)
        feed2.onCall { _ in n.mutate { $0 += 1 } }
        _ = try feed2.pollOnce()
        XCTAssertEqual(n.value, 0)
    }

    func testDemoStoreSeedAndEnd() {
        let s = CallStore(demo: true)
        XCTAssertTrue(s.isDemo)
        s.seedDemo(state: "incoming")
        XCTAssertEqual(s.call?.state, "ringing")
        XCTAssertEqual(s.call?.displayPeer, "Doe, Jane")
        s.accept() // demo echo flips to connected synchronously
        XCTAssertEqual(s.call?.state, "connected")
        s.end()
        XCTAssertNil(s.call)
        s.seedDemo(state: "bogus")
        XCTAssertNil(s.call)
    }
}
