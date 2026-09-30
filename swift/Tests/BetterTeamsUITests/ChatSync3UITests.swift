// ChatSync3UITests.swift — CHATSYNC3 R3: same-sender runs group like the
// Teams worker's `attached` (same creator, previous not deleted, within
// 5 minutes of the previous message, chained) and a run's continuation
// rows never open a gap for the hover toolbar, at any window width.
import SwiftUI
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class ChatSync3UITests: XCTestCase {
    private func msg(_ id: String, _ sender: String, at second: Int, deleted: Bool = false) -> ChatMessage {
        var m = ChatMessage(id: id, sender: sender,
                            timestamp: String(format: "2026-09-27T09:%02d:%02dZ", second / 60, second % 60),
                            content: "hi", isOwn: sender == "Me")
        m.deleted = deleted
        return m
    }

    private func headers(_ list: [ChatMessage]) -> [Bool] {
        TimelineSnapshot.items(messages: list, failed: [], dayKey: { _ in "d" }, dayLabel: { $0 })
            .compactMap { item -> Bool? in
                if case .message(_, _, let h) = item { return h }
                return nil
            }
    }

    func testRunsChainWithinFiveMinutesOfThePreviousMessage() {
        // Each within 5 min of the one before: one run, though 12 min from its start.
        XCTAssertEqual(headers([msg("1", "Ava Lindqvist", at: 0), msg("2", "Ava Lindqvist", at: 240),
                                msg("3", "Ava Lindqvist", at: 480), msg("4", "Ava Lindqvist", at: 720)]),
                       [true, false, false, false])
        // Exactly 5:00 continues; 5:01 starts a new run.
        XCTAssertEqual(headers([msg("1", "Ava Lindqvist", at: 0), msg("2", "Ava Lindqvist", at: 300),
                                msg("3", "Ava Lindqvist", at: 601)]),
                       [true, false, true])
        // After a deleted message the next one shows its header (Teams).
        XCTAssertEqual(headers([msg("1", "Ava Lindqvist", at: 0), msg("2", "Ava Lindqvist", at: 10, deleted: true),
                                msg("3", "Ava Lindqvist", at: 20)]),
                       [true, false, true])
        // Own runs group the same way.
        XCTAssertEqual(headers([msg("1", "Me", at: 0), msg("2", "Me", at: 30), msg("3", "Ava Lindqvist", at: 40)]),
                       [true, false, true])
    }

    func testContinuationNeverGrowsForTheToolbarAtAnyWidth() {
        let tb = HoverToolbarRules.size(scale: 1)
        for own in [false, true] {
            for width in stride(from: CGFloat(160), through: 900, by: 40) {
                for cardW in stride(from: CGFloat(40), through: width, by: 60) {
                    let p = LanePlan.make(width: width, header: nil, card: CGSize(width: cardW, height: 33),
                                          toolbar: tb, ownTrailing: own,
                                          slack: own ? MessageRowView.ownGutter : MessageRowView.otherGutter,
                                          topPadding: 2)
                    XCTAssertEqual(p.size.height, 33, "own=\(own) w=\(width) card=\(cardW)")
                    XCTAssertTrue(p.placement == .side || p.placement == .overlay)
                    XCTAssertGreaterThanOrEqual(p.toolbar!.minY, -2, "inside its row")
                }
            }
        }
    }

    /// The pop-out case from the CHATSYNC2b capture: an 8-word continuation
    /// in the 520 pt pop-out laid out a 25 pt strip; hosted, the lane is
    /// now as tall as its bubble at both widths.
    func testHostedContinuationLaneHeightIsTheBubbleAtPopOutAndMainWidths() {
        let tb = HoverToolbarRules.size(scale: 1)
        func laneHeight(_ width: CGFloat) -> CGFloat {
            let lane = BubbleLane(ownTrailing: false, hasHeader: false, toolbar: tb,
                                  slack: MessageRowView.otherGutter, topPadding: 2) {
                Color.gray.frame(width: 220, height: 33)
                Color.clear
            }
            return NSHostingView(rootView: lane.frame(width: width)).fittingSize.height
        }
        XCTAssertEqual(laneHeight(400), 33, "pop-out lane width")
        XCTAssertEqual(laneHeight(900), 33, "main lane width")
        // Header rows keep their placement rules (header line or strip).
        let head = LanePlan.make(width: 400, header: CGSize(width: 150, height: 17), card: CGSize(width: 220, height: 33),
                                 toolbar: tb, ownTrailing: false, slack: MessageRowView.otherGutter, topPadding: 8)
        XCTAssertNotEqual(head.placement, .overlay)
    }
}
