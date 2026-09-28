// LongChannelFixtureTests.swift — om-hu-fixture: the 300-msg demo
// long channel (scroll/cap shots) routes through DemoData, zero real
// data, and stays bigger than every initial-load cap.
import XCTest

@testable import OstMacCore

@MainActor
final class LongChannelFixtureTests: XCTestCase {
    /// 300 bubbles, unique ascending ids, 10 day sections.
    func testLongChannelHas300() {
        let msgs = DemoData.longChannelMessages()
        XCTAssertEqual(msgs.count, 300)
        XCTAssertEqual(msgs.first?.id, "lchan-1")
        XCTAssertEqual(msgs.last?.id, "lchan-300")
        XCTAssertEqual(Set(msgs.map(\.id)).count, 300)
        // Ascending time.
        let dates = msgs.map { ConversationStore.messageDate($0.timestamp) }
        XCTAssertTrue(dates.allSatisfy { $0 != nil })
        for i in 1 ..< dates.count {
            XCTAssertLessThanOrEqual(dates[i - 1]!, dates[i]!, "order at \(i)")
        }
        XCTAssertEqual(MessageRender.daySections(msgs).count, 10)
        // Scroll-shot anchors exist.
        for id in ["lchan-1", "lchan-150", "lchan-300"] {
            XCTAssertTrue(msgs.contains { $0.id == id }, id)
        }
    }

    /// Wiring: team row, routing, demo fence, shared files, own tail.
    func testLongChannelWiring() {
        XCTAssertTrue(DemoData.teams.flatMap(\.channels).contains {
            $0.id == DemoData.longChannelID
        })
        XCTAssertEqual(
            DemoData.name(for: DemoData.longChannelID),
            "Engineering > #Release Review")
        XCTAssertEqual(DemoData.messages(for: DemoData.longChannelID).count, 300)
        XCTAssertTrue(DemoData.isDemoID(DemoData.longChannelID))
        XCTAssertFalse(DemoData.sharedFiles(for: DemoData.longChannelID).isEmpty)
        // Own tail (demo open adopts peers through it → Seen).
        XCTAssertTrue(DemoData.longChannelMessages().last?.isOwn == true)
        // Other demo channels keep the short canned thread.
        XCTAssertEqual(DemoData.messages(for: "demo-chan-general").count, 2)
    }

    /// Zero real data: only the fictional crew.
    func testLongChannelZeroRealData() {
        let allowed: Set<String> = [
            "Megan Harper", "Tom Becker", "Ava Lindqvist", "Me",
        ]
        for m in DemoData.longChannelMessages() {
            XCTAssertTrue(allowed.contains(m.sender), "real name leak: \(m.sender)")
            XCTAssertFalse(m.content.isEmpty, "empty bubble: \(m.id)")
        }
    }

    /// The fixture exceeds every initial-load cap, so cap shots and
    /// window math have something to bite on.
    func testLongChannelExceedsCaps() {
        let msgs = DemoData.longChannelMessages()
        // Page caps: one open (3×50) and one day-load (4×50) each
        // cover only part of the thread.
        XCTAssertLessThan(ConversationStore.openMaxPages * 50, msgs.count)
        XCTAssertLessThan(ConversationStore.dayLoadMaxPages * 50, msgs.count)
        // Time window: the last 72h hold a strict slice of the thread.
        let now = Date()
        let edge = now.addingTimeInterval(-ConversationStore.historyWindowHours * 3600)
        let inWindow = msgs.filter {
            (ConversationStore.messageDate($0.timestamp) ?? .distantPast) > edge
        }
        XCTAssertFalse(inWindow.isEmpty)
        XCTAssertLessThan(inWindow.count, msgs.count)
        // The thread head sits outside the window: newest-only loads
        // always have older pages waiting.
        let oldest = ConversationStore.messageDate(msgs.first!.timestamp)!
        XCTAssertLessThanOrEqual(oldest, edge)
    }
}
