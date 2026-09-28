// EditDeleteTests.swift — om-editdel lane: edit/delete pure helpers + demo e2e + FFI guards.
import XCTest

@testable import OstMacCore

@MainActor
final class EditDeleteTests: XCTestCase {
    func testApplyingEditMarksEdited() {
        let list = [
            ChatMessage(id: "m1", sender: "Me", timestamp: "t", content: "hi", isOwn: true),
            ChatMessage(id: "m2", sender: "B", timestamp: "t", content: "yo"),
        ]
        let out = ConversationStore.applyingEdit(id: "m1", content: "EDITED", to: list)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].content, "EDITED")
        XCTAssertTrue(out[0].edited)
        XCTAssertEqual(out[1].content, "yo")
        XCTAssertFalse(out[1].edited)
    }

    func testApplyingEditUnknownIdNoop() {
        let list = [ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "hi")]
        let out = ConversationStore.applyingEdit(id: "nope", content: "x", to: list)
        XCTAssertEqual(out, list)
    }

    func testRemovingDropsBubble() {
        let list = [
            ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "hi"),
            ChatMessage(id: "m2", sender: "B", timestamp: "t", content: "yo"),
        ]
        let out = ConversationStore.removing(id: "m1", from: list)
        XCTAssertEqual(out.map(\.id), ["m2"])
        XCTAssertEqual(ConversationStore.removing(id: "nope", from: list).count, 2)
    }

    func testDemoEditDeleteEndToEnd() {
        let store = ConversationStore.demo()
        guard let own = store.messages.first(where: \.isOwn) else {
            XCTFail("demo has no own bubble")
            return
        }
        let count = store.messages.count
        store.edit(messageID: own.id, text: "edited via sheet")
        XCTAssertEqual(store.messages.first(where: { $0.id == own.id })?.content, "edited via sheet")
        XCTAssertTrue(store.messages.first(where: { $0.id == own.id })?.edited ?? false)
        // Empty + unknown edits are no-ops.
        store.edit(messageID: own.id, text: "  ")
        store.edit(messageID: "nope", text: "x")
        XCTAssertEqual(store.messages.count, count)
        store.deleteMessage(id: own.id)
        // fid-msgs D12: delete tombstones (row stays, content cleared).
        XCTAssertEqual(store.messages.count, count)
        let tomb = store.messages.first(where: { $0.id == own.id })
        XCTAssertNotNil(tomb)
        XCTAssertTrue(tomb?.deleted ?? false)
        XCTAssertEqual(tomb?.content, "")
        // Unknown delete is a no-op.
        store.deleteMessage(id: "nope")
        XCTAssertEqual(store.messages.count, count)
    }

    /// Live FFI round-trip: empty ids/text rejected by core before network.
    func testLiveFFIEditDeleteGuardsThrow() {
        XCTAssertThrowsError(try RustCore.edit(chatID: "", messageID: "m1", text: "hi"))
        XCTAssertThrowsError(try RustCore.edit(chatID: "19:x", messageID: "", text: "hi"))
        XCTAssertThrowsError(try RustCore.edit(chatID: "19:x", messageID: "m1", text: "  "))
        XCTAssertThrowsError(try RustCore.deleteMessage(chatID: "", messageID: "m1"))
        XCTAssertThrowsError(try RustCore.deleteMessage(chatID: "19:x", messageID: ""))
    }
}
