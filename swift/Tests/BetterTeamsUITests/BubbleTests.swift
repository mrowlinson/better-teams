// BubbleTests.swift — Teams-style chat bubbles (UI-SPEC §6.2.1): which
// bubble a row sits on (own trailing, others leading, channel posts
// unbubbled) and sender-run grouping (header/avatar on the first message
// of a run only).
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class BubbleTests: XCTestCase {
    private func msg(_ id: String, _ sender: String, at minute: Int) -> ChatMessage {
        ChatMessage(id: id, sender: sender, timestamp: String(format: "2026-09-27T09:%02d:00Z", minute),
                    content: "hi", isOwn: sender == "Me")
    }

    func testOwnTrailingOthersLeadingChannelPostsUnbubbled() {
        let own = msg("a", "Me", at: 0)
        let other = msg("b", "Megan Harper", at: 0)
        XCTAssertEqual(RowBubble.of(own, scope: .conversation), .own)
        XCTAssertEqual(RowBubble.of(other, scope: .conversation), .other)
        XCTAssertEqual(RowBubble.of(own, scope: .posts), RowBubble.none)
        XCTAssertEqual(RowBubble.of(other, scope: .posts), RowBubble.none)
        XCTAssertEqual(RowBubble.of(other, scope: .thread(rootID: "r")), RowBubble.none)
    }

    func testHeaderOnlyOnFirstOfEachSenderRun() {
        let list = [
            msg("1", "Megan Harper", at: 0),
            msg("2", "Megan Harper", at: 1),   // same run
            msg("3", "Me", at: 2),             // sender change
            msg("4", "Me", at: 3),             // same run
            msg("5", "Megan Harper", at: 4),   // back to Megan: new run
            msg("6", "Megan Harper", at: 11),  // > 5 min gap: new run
            msg("7", "Tom Becker", at: 12),    // other sender
        ]
        let headers = TimelineSnapshot.items(messages: list, failed: [], dayKey: { _ in "d" },
                                             dayLabel: { $0 })
            .compactMap { item -> Bool? in
                if case .message(_, _, let h) = item { return h }
                return nil
            }
        XCTAssertEqual(headers, [true, false, true, false, true, true, true])
    }

    func testAppendingToRunLeavesEarlierRowsUntouched() {
        // Stable UI: a new message in a run never changes the rows above it.
        let base = [msg("1", "Megan Harper", at: 0), msg("2", "Megan Harper", at: 1)]
        let before = TimelineSnapshot.items(messages: base, failed: [], dayKey: { _ in "d" }, dayLabel: { $0 })
        let after = TimelineSnapshot.items(messages: base + [msg("3", "Megan Harper", at: 2)], failed: [],
                                           dayKey: { _ in "d" }, dayLabel: { $0 })
        XCTAssertEqual(Array(after.prefix(before.count)), before)
    }
}
