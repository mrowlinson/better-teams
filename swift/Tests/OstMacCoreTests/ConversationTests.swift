// ConversationTests.swift — om-conv lane: upsert/edit semantics + FFI round-trip.
import XCTest

@testable import OstMacCore

@MainActor
final class ConversationTests: XCTestCase {
    func testUpsertAppendsNew() {
        let list = [ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "hi")]
        let out = ConversationStore.upsert(
            ChatMessage(id: "m2", sender: "B", timestamp: "t", content: "yo"), into: list)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[1].id, "m2")
    }

    func testUpsertUpdatesInPlace() {
        let list = [
            ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "hi"),
            ChatMessage(id: "m2", sender: "B", timestamp: "t", content: "yo"),
        ]
        let out = ConversationStore.upsert(
            ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "EDITED"), into: list)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].content, "EDITED")
        XCTAssertEqual(out[1].content, "yo")
    }

    func testIngestEditedUnknownIdNoop() {
        let store = ConversationStore()
        store.ingest(ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "hi"))
        store.ingestEdited(id: "nope", content: "x")
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages[0].content, "hi")
        store.ingestEdited(id: "m1", content: "EDITED")
        XCTAssertEqual(store.messages[0].content, "EDITED")
    }

    func testDemoMode() {
        let store = ConversationStore.demo()
        XCTAssertTrue(store.messages.count >= 5)
        XCTAssertTrue(store.messages.contains { $0.isOwn })
        store.send(text: "local echo")
        XCTAssertEqual(store.messages.last?.content, "local echo")
        XCTAssertTrue(store.messages.last?.isOwn ?? false)
    }

    /// Live FFI round-trip through the linked staticlib: empty chat id is
    /// rejected by core before any network, Swift decodes the error envelope.
    func testLiveFFIEmptyChatIDThrows() {
        XCTAssertThrowsError(try RustCore.messages(chatID: ""))
        XCTAssertThrowsError(try RustCore.send(chatID: "19:x", text: "  "))
    }

    /// Header title (om-chatnames): resolved name, else the generic
    /// label — never the raw chat id.
    func testHeaderTitleNeverRawID() {
        let fresh = ConversationStore()
        XCTAssertEqual(fresh.headerTitle, "Conversation")
        let named = ConversationStore()
        named.showDemo(chatID: "19:abc@thread.v2", chatName: "Ship it", messages: [])
        XCTAssertEqual(named.headerTitle, "Ship it")
        let blank = ConversationStore()
        blank.showDemo(chatID: "19:abc@thread.v2", chatName: "  ", messages: [])
        XCTAssertEqual(blank.headerTitle, "Conversation")
    }

    // MARK: - Index taps (gap-g6g7)

    func testShowDemoFiresOnHistory() {
        let store = ConversationStore()
        var fired: [(String, [ChatMessage])] = []
        store.onHistory = { fired.append(($0, $1)) }
        let msgs = [ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "hi")]
        store.showDemo(chatID: "c1", chatName: "C", messages: msgs)
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired[0].0, "c1")
        XCTAssertEqual(fired[0].1.map(\.id), ["m1"])
    }

    func testDemoDeleteFiresOnDelete() {
        let store = ConversationStore()
        var fired: [(String, String)] = []
        store.onDelete = { fired.append(($0, $1)) }
        store.showDemo(
            chatID: "c1", chatName: "C",
            messages: [ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "hi")])
        store.deleteMessage(id: "m1")
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired[0].0, "c1")
        XCTAssertEqual(fired[0].1, "m1")
        // Unknown id: no fire.
        store.deleteMessage(id: "nope")
        XCTAssertEqual(fired.count, 1)
    }
}
