// ConvRichUITests.swift — om-convrich-ui: rich demo merged into THE app's
// demo dataset (sidebar row + thread + failed bubble + retry).
import XCTest

@testable import OstMacCore

@MainActor
final class ConvRichUITests: XCTestCase {
    func testRichRowInSidebarList() {
        let row = DemoData.chats.first { $0.id == DemoData.richID }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.name, "Q3 Review Deck")
    }

    func testRichRowTracksThreadTail() {
        let now = Date()
        let row = DemoData.richChat(now: now)
        let tail = ConversationStore.richDemoMessages(now: now).last!
        XCTAssertEqual(row.last_message_time, tail.timestamp)
        XCTAssertEqual(row.last_message_sender, tail.sender)
        XCTAssertEqual(row.last_message_preview, tail.content)
        XCTAssertEqual(DemoData.name(for: DemoData.richID), "Q3 Review Deck")
    }

    func testRichThreadHasEveryRichState() {
        let msgs = DemoData.messages(for: DemoData.richID)
        XCTAssertEqual(MessageRender.daySections(msgs).count, 2)
        XCTAssertTrue(msgs.contains { $0.edited })
        XCTAssertTrue(msgs.contains { $0.raw?.contains("<at") ?? false })
        XCTAssertTrue(msgs.contains { $0.raw?.contains("<pre>") ?? false })
        XCTAssertTrue(msgs.contains { $0.content.contains("https://") })
    }

    func testShowDemoFailedPassthroughAndRetry() {
        let store = ConversationStore()
        store.showDemo(
            chatID: DemoData.richID, chatName: "Q3 Review Deck",
            messages: DemoData.messages(for: DemoData.richID),
            failed: DemoData.failedIDs(for: DemoData.richID))
        XCTAssertTrue(store.failedIDs.contains("rich-fail"))
        XCTAssertEqual(
            store.retry(id: "rich-fail"),
            "Sending the final deck to the client now.")
        XCTAssertFalse(store.failedIDs.contains("rich-fail"))
    }

    func testPlainDemoChatsHaveNoFailed() {
        for id in [DemoData.demoID, DemoData.avaID, DemoData.standupID, "unknown"] {
            XCTAssertTrue(DemoData.failedIDs(for: id).isEmpty, id)
        }
    }
}
