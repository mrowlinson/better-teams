// FidMsgsTests.swift — fid-msgs lane: Teams-fidelity pins D11-D16 + D24
// (messages surfaces). Exact-copy literals + tombstone/menu behavior.
import XCTest

@testable import OstMacCore

@MainActor
final class FidMsgsTests: XCTestCase {
    private func msg(
        id: String = "m1", sender: String = "Ava Lindqvist",
        content: String = "Standup moved to ten.",
        isOwn: Bool = false, deleted: Bool = false
    ) -> ChatMessage {
        ChatMessage(
            id: id, sender: sender, timestamp: "2026-09-25T09:00:00Z",
            content: content, isOwn: isOwn, deleted: deleted)
    }

    // MARK: - D11 Edited label

    // MARK: - D12 Delete tombstone

    func testApplyingDeleteTombstonesInPlace() {
        let list = [
            msg(id: "m1", content: "hi"),
            msg(id: "m2", content: "yo"),
        ]
        let out = ConversationStore.applyingDelete(id: "m1", to: list)
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out[0].deleted)
        XCTAssertEqual(out[0].content, "")
        XCTAssertNil(out[0].raw)
        XCTAssertTrue(out[0].reactions.isEmpty)
        XCTAssertFalse(out[1].deleted)
        XCTAssertEqual(out[1].content, "yo")
    }

    func testApplyingDeleteUnknownIdNoop() {
        let list = [msg(id: "m1", content: "hi")]
        XCTAssertEqual(ConversationStore.applyingDelete(id: "nope", to: list), list)
    }

    func testDemoDeleteKeepsTombstoneRow() {
        let store = ConversationStore.demo()
        guard let own = store.messages.first(where: \.isOwn) else {
            XCTFail("demo has no own bubble")
            return
        }
        let count = store.messages.count
        store.deleteMessage(id: own.id)
        XCTAssertEqual(store.messages.count, count)
        XCTAssertTrue(store.messages.first(where: { $0.id == own.id })?.deleted ?? false)
    }

    func testIngestDeletedGroupTombstonesOneToOneDrops() {
        let store = ConversationStore()
        store.showDemo(
            chatID: "c1", chatName: "C",
            messages: [msg(id: "m1"), msg(id: "m2")])
        store.ingestDeleted(id: "m1")
        XCTAssertTrue(store.messages.first(where: { $0.id == "m1" })?.deleted ?? false)
        XCTAssertEqual(store.messages.count, 2)
        store.ingestDeleted(id: "m2", isOneToOne: true)
        XCTAssertNil(store.messages.first(where: { $0.id == "m2" }))
        XCTAssertEqual(store.messages.count, 1)
        store.ingestDeleted(id: "nope")
        XCTAssertEqual(store.messages.count, 1)
    }

    func testTombstoneFadeIntervalIsMinutes() {
        XCTAssertEqual(ConversationStore.tombstoneFadeSeconds, 5 * 60)
    }

    func testDecodedMessageDefaultsUndeleted() throws {
        let data = """
            {"id":"m1","sender":"A","timestamp":"t","content":"hi"}
            """.data(using: .utf8)!
        let m = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertFalse(m.deleted)
    }

    // MARK: - D13 Failed-send copy + retry

    func testRetryClearsFailedFlag() {
        let store = ConversationStore()
        store.showDemo(
            chatID: "c1", chatName: "C", messages: [msg(id: "m1")],
            failed: ["m1"])
        XCTAssertTrue(store.failedIDs.contains("m1"))
        store.retry(id: "m1")
        XCTAssertFalse(store.failedIDs.contains("m1"))
        XCTAssertNil(store.retry(id: "nope"))
    }

    // MARK: - D14 Composer placeholders

    func testComposerPlaceholderPerSurface() {
        XCTAssertEqual(
            ConversationStore.composerPlaceholder(chatID: "19:chat@thread.v2"),
            "Type a message...")
        XCTAssertEqual(
            ConversationStore.composerPlaceholder(chatID: nil), "Type a message...")
        XCTAssertEqual(
            ConversationStore.composerPlaceholder(chatID: "19:abc@thread.tacv2"),
            "Reply")
    }

    // MARK: - D16 Save labels

    func testSaveMenuTitlesAreTeamsLiterals() {
        XCTAssertEqual(SavedMessages.menuTitle(isSaved: false), "Save this message")
        XCTAssertEqual(SavedMessages.menuTitle(isSaved: true), "Unsave")
    }

    // MARK: - D24 Copy link

    // MARK: - D15 Bubble mark-as-unread

    /// Host contract: the bubble's onMarkUnread target pins the open
    /// thread unread (the shape the App passes down).
    func testMarkUnreadHostClosureMarksThreadUnread() {
        let unread = UnreadStore(dock: FakeDockBadge())
        let onMarkUnread: (ChatMessage) -> Void = {
            _ in unread.markUnread(chatID: "c1")
        }
        onMarkUnread(msg())
        XCTAssertTrue(unread.isUnread(chatID: "c1"))
        XCTAssertEqual(unread.count(for: "c1"), 1)
    }
}
