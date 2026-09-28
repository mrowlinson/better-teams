// ChannelHistoryTests.swift — om-channel-history: few-days initial cap,
// paging helpers, open-chain anchor suppression, land-on-latest.
import XCTest

@testable import OstMacCore

@MainActor
final class ChannelHistoryTests: XCTestCase {
    private static func msg(_ id: String, _ ts: String) -> ChatMessage {
        ChatMessage(id: id, sender: "A", timestamp: ts, content: "x")
    }

    // MARK: - Initial-load caps (few days, few pages)

    func testInitialLoadCaps() {
        // Initial open covers the last few days, bounded page fetches;
        // older history pages back on scroll (day-chunks unchanged).
        XCTAssertEqual(ConversationStore.historyWindowHours, 72)
        XCTAssertEqual(ConversationStore.openMaxPages, 2)
        XCTAssertEqual(ConversationStore.dayLoadMaxPages, 4)
    }

    func testWindowCoversFewDays() {
        let now = ConversationStore.messageDate("2026-09-23T12:00:00Z")!
        // 71h-old oldest: window not covered, keep paging.
        XCTAssertFalse(ConversationStore.windowCovered(
            [Self.msg("a", "2026-09-20T13:00:00Z")], now: now))
        // 73h-old oldest: covered, stop.
        XCTAssertTrue(ConversationStore.windowCovered(
            [Self.msg("a", "2026-09-20T11:00:00Z")], now: now))
        // Empty pages cover nothing: keep paging (blank-page chains
        // still terminate on the page cap / token end).
        XCTAssertFalse(ConversationStore.windowCovered([], now: now))
        // Unparseable stamps stop the window (never spin on garbage).
        XCTAssertTrue(ConversationStore.windowCovered([Self.msg("a", "t")], now: now))
    }

    // MARK: - Pagination purity (long-channel page joins)

    func testPrependExistingWinsNoDupes() {
        let list = [Self.msg("b", "t"), Self.msg("c", "t")]
        let older = [Self.msg("a", "t"), Self.msg("b", "t")]
        let out = ConversationStore.prepend(older, to: list)
        XCTAssertEqual(out.map(\.id), ["a", "b", "c"])
    }

    // MARK: - Open-chain anchor suppression (blank-park fix)

    // MARK: - Land on latest (open completion)

    // MARK: - Open-chain progress + capped marker (om-hu-polish)

    private static func msgs() -> [ChatMessage] {
        [msg("a", "t"), msg("tail-9", "t")]
    }
}
