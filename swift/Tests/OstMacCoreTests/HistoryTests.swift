// HistoryTests.swift — om-history: window + day-chunk helpers,
// retry/error seams, demo history thread.
import XCTest

@testable import OstMacCore

@MainActor
final class HistoryTests: XCTestCase {
    // MARK: - Timestamp parsing

    /// Server shape (7-digit fraction) parses to the right UTC instant.
    func testMessageDateServerStamp() {
        let d = ConversationStore.messageDate("2026-09-22T12:53:06.9690000Z")
        XCTAssertNotNil(d)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d!)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 9)
        XCTAssertEqual(c.day, 22)
        XCTAssertEqual(c.hour, 12)
        XCTAssertEqual(c.minute, 53)
        XCTAssertEqual(c.second, 6)
    }

    func testMessageDatePlainAndGarbage() {
        XCTAssertNotNil(ConversationStore.messageDate("2026-09-22T12:53:06Z"))
        XCTAssertNil(ConversationStore.messageDate(""))
        XCTAssertNil(ConversationStore.messageDate("not-a-date"))
        XCTAssertNil(ConversationStore.messageDate("t")) // unit-test shorthand
    }

    // MARK: - Window coverage (explicit-hours shape; the default
    // window value is pinned by ChannelHistoryTests)

    private func msg(_ ts: String) -> ChatMessage {
        ChatMessage(id: "m", sender: "A", timestamp: ts, content: "x")
    }

    func testWindowCovered() {
        let now = ConversationStore.messageDate("2026-09-23T12:00:00Z")!
        // Recent oldest: keep paging.
        XCTAssertFalse(ConversationStore.windowCovered(
            [msg("2026-09-23T11:00:00Z")], now: now, hours: 24))
        // Oldest past the window: covered.
        XCTAssertTrue(ConversationStore.windowCovered(
            [msg("2026-09-22T11:59:00Z")], now: now, hours: 24))
        // Exactly on the edge counts as covered.
        XCTAssertTrue(ConversationStore.windowCovered(
            [msg("2026-09-22T12:00:00Z")], now: now, hours: 24))
        // Empty pages cover nothing: keep paging.
        XCTAssertFalse(ConversationStore.windowCovered([], now: now, hours: 24))
        // Unparseable stamps stop the window (never spin on garbage).
        XCTAssertTrue(ConversationStore.windowCovered([msg("t")], now: now, hours: 24))
    }

    // MARK: - Day-chunk crossing

    func testDayChunkDone() {
        // Same day: chunk continues.
        XCTAssertFalse(ConversationStore.dayChunkDone(
            startDayKey: "2026-09-23", messages: [msg("2026-09-23T09:00:00Z")]))
        // Crossed into an earlier day: chunk done.
        XCTAssertTrue(ConversationStore.dayChunkDone(
            startDayKey: "2026-09-23", messages: [msg("2026-09-22T16:00:00Z")]))
        // Empty never counts as crossed.
        XCTAssertFalse(ConversationStore.dayChunkDone(startDayKey: "2026-09-23", messages: []))
    }

    // MARK: - Retry / error seams

    func testRetryOpenNoopsWithoutChatOrInDemo() {
        let live = ConversationStore()
        live.retryOpen()
        XCTAssertFalse(live.loading)
        XCTAssertTrue(live.messages.isEmpty)
        let demo = ConversationStore.demo()
        let count = demo.messages.count
        demo.retryOpen()
        XCTAssertFalse(demo.loading)
        XCTAssertEqual(demo.messages.count, count)
        XCTAssertNil(demo.error)
    }

    func testSeedDemoErrorDemoOnly() {
        let live = ConversationStore()
        live.seedDemoError("boom")
        XCTAssertNil(live.error)
        let demo = ConversationStore.demo()
        demo.seedDemoError("boom")
        XCTAssertEqual(demo.error, "boom")
    }

    // MARK: - Scroll shot hook

    func testScrollTarget() {
        XCTAssertEqual(
            ConversationStore.scrollTarget(args: ["app", "--scroll-to", "hist-1"]), "hist-1")
        XCTAssertNil(ConversationStore.scrollTarget(args: ["app"]))
        XCTAssertNil(ConversationStore.scrollTarget(args: ["app", "--scroll-to"]))
        XCTAssertNil(ConversationStore.scrollTarget(args: ["app", "--scroll-to", "  "]))
    }

    // MARK: - Demo history thread

    func testHistoryDemoThreadSpansThreeDays() {
        let msgs = DemoData.historyMessages()
        XCTAssertEqual(msgs.count, 38)
        XCTAssertEqual(msgs.first?.id, "hist-1")
        XCTAssertEqual(MessageRender.daySections(msgs).count, 3)
        // Sidebar row + routing agree with the thread tail.
        XCTAssertEqual(DemoData.messages(for: DemoData.historyID).count, 38)
        let row = DemoData.historyChat()
        XCTAssertEqual(row.name, "Release Train")
        XCTAssertEqual(row.last_message_preview, msgs.last?.content)
    }
}
