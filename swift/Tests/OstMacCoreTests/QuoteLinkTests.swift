// QuoteLinkTests.swift — om-lt2-quotelink: channel reply quote-link target.
import XCTest

@testable import OstMacCore

@MainActor
final class QuoteLinkTests: XCTestCase {
    func testJumpIDLinksResolvableParentOnly() {
        let store = ConversationStore.demo()
        let parent = store.messages[0]
        let index = MessageIndex(store.messages)
        let reply = ChatMessage(
            id: "q1", sender: "Me", timestamp: "t",
            content: "ans", isOwn: true, reply_to: parent.id)
        XCTAssertEqual(store.quoteJumpID(for: reply, in: index), parent.id)
    }

    func testJumpIDNilWhenMissingOrEvicted() {
        let store = ConversationStore.demo()
        let index = MessageIndex(store.messages)
        let plain = store.messages[0]
        XCTAssertNil(store.quoteJumpID(for: plain, in: index))
        let orphan = ChatMessage(
            id: "q2", sender: "Me", timestamp: "t",
            content: "orphan", isOwn: true, reply_to: "gone")
        XCTAssertNil(store.quoteJumpID(for: orphan, in: index))
        let blank = ChatMessage(
            id: "q3", sender: "Me", timestamp: "t",
            content: "blank", isOwn: true, reply_to: "  ")
        XCTAssertNil(store.quoteJumpID(for: blank, in: index))
    }
}
