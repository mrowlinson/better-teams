// IntegrationTests.swift — om-integrate lane: realtime→conversation glue.
import XCTest

@testable import OstMacCore

@MainActor
final class IntegrationTests: XCTestCase {
    func realtime(
        chat: String = "19:a@thread.v2",
        id: String = "m1",
        text: String = "hi",
        edit: Bool = false,
        edited: String? = nil
    ) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chat, msgId: id, sender: "S",
            text: text, time: "2026-09-22T10:00:00Z",
            isEdit: edit, editedID: edited)
    }

    func testIsForMatchesOpenChatOnly() {
        let m = realtime(chat: "19:a")
        XCTAssertTrue(m.isFor(chatID: "19:a"))
        XCTAssertFalse(m.isFor(chatID: "19:b"))
        XCTAssertFalse(m.isFor(chatID: nil))
    }

    func testAsChatMessageNewKeepsID() {
        let c = realtime(id: "m9", text: "hello").asChatMessage
        XCTAssertEqual(c.id, "m9")
        XCTAssertEqual(c.content, "hello")
        XCTAssertEqual(c.sender, "S")
        XCTAssertEqual(c.timestamp, "2026-09-22T10:00:00Z")
    }

    func testAsChatMessageEditCollapsesOntoEditedID() {
        let c = realtime(id: "m2", text: "fixed", edit: true, edited: "m1").asChatMessage
        XCTAssertEqual(c.id, "m1")
        XCTAssertEqual(c.content, "fixed")
    }

    func testIngestRealtimeNewAppends() {
        let store = ConversationStore()
        store.ingest(realtime: realtime(id: "m1", text: "hi"))
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages[0].id, "m1")
    }

    func testIngestRealtimeEditUpdatesInPlace() {
        let store = ConversationStore()
        store.ingest(realtime: realtime(id: "m1", text: "hi"))
        store.ingest(realtime: realtime(id: "m2", text: "yo"))
        store.ingest(realtime: realtime(id: "m9", text: "EDITED", edit: true, edited: "m1"))
        XCTAssertEqual(store.messages.count, 2)
        XCTAssertEqual(store.messages[0].id, "m1")
        XCTAssertEqual(store.messages[0].content, "EDITED")
        XCTAssertEqual(store.messages[1].content, "yo")
    }

    func testIngestRealtimeUnknownEditAppends() {
        let store = ConversationStore()
        store.ingest(realtime: realtime(id: "m9", text: "late edit", edit: true, edited: "m7"))
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages[0].id, "m7")
        XCTAssertEqual(store.messages[0].content, "late edit")
    }

    func testShowDemoThenLocalSend() {
        let store = ConversationStore()
        store.showDemo(
            chatID: "d", chatName: "Demo",
            messages: [ChatMessage(
                id: "d1", sender: "A", timestamp: "t", content: "canned")])
        XCTAssertTrue(store.isDemo)
        XCTAssertTrue(store.didLoad)
        XCTAssertEqual(store.chatID, "d")
        store.send(text: "local echo")
        XCTAssertEqual(store.messages.last?.content, "local echo")
        XCTAssertTrue(store.messages.last?.isOwn ?? false)
    }

    func testFeedCountsPollsAndClearsError() throws {
        let ok = try decodeOrThrow(
            RealtimePoll.self,
            from: Data(#"{"ok":true,"resync":false,"skipped":0,"messages":[]}"#.utf8))
        let feed = RealtimeFeed(poll: { ok })
        XCTAssertEqual(feed.pollCount, 0)
        XCTAssertNil(feed.lastError)
        _ = try feed.pollOnce()
        _ = try feed.pollOnce()
        XCTAssertEqual(feed.pollCount, 2)
        XCTAssertNil(feed.lastError)
    }

    func testFeedRecordsLastError() {
        let feed = RealtimeFeed(poll: { throw CoreCallError.failed("nope") })
        XCTAssertThrowsError(try feed.pollOnce())
        XCTAssertEqual(feed.pollCount, 0)
        XCTAssertNotNil(feed.lastError)
    }
}
