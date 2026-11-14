// CallEndedRowTests.swift — P2#16 (§8 End): a connected call that
// ends lands in Calls ▸ Recent as "Call ended · <duration>".
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class CallEndedRowTests: XCTestCase {
    func testEndedCallReadsCallEnded() {
        let t: UInt64 = 1_790_000_000
        let ended = CallRecord(
            id: "c1", direction: .outgoing, peer: "8:orgid:ava", peerName: "Ava Lindqvist",
            thread: "19:ava", startedAt: t, endedAt: t + 754, durationSecs: 754)
        let rows = CallsRowModel.rows(history: [ended], activity: [])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.detailLine, "Call ended · 12:34")
    }

    func testUnconnectedAndMissedKeepDirection() {
        let t: UInt64 = 1_790_000_000
        let unanswered = CallRecord(
            id: "c2", direction: .outgoing, peer: "8:orgid:ava", peerName: "Ava Lindqvist",
            startedAt: t, endedAt: t + 30)
        let missed = CallRecord(
            id: "c3", direction: .missed, peer: "8:orgid:ava", peerName: "Ava Lindqvist",
            startedAt: t, endedAt: t + 30)
        let rows = CallsRowModel.rows(history: [unanswered, missed], activity: [])
        XCTAssertEqual(rows.first { $0.id == "rec:c2" }?.detailLine, "Outgoing")
        XCTAssertEqual(rows.first { $0.id == "rec:c3" }?.detailLine, "Missed")
    }
}
