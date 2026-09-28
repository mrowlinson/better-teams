// RepliesTests.swift — om-replies lane: quote decode, store reply state,
// demo reply send, thread fixtures, live FFI reply validation.
import XCTest

@testable import OstMacCore

@MainActor
final class RepliesTests: XCTestCase {
    func testDecodeCarriesReplyTo() throws {
        let msg = try decodeOrThrow(
            ChatMessage.self,
            from: Data(
                #"{"id":"m2","sender":"B","timestamp":"t","content":"On it!","reply_to":"m1"}"#.utf8))
        XCTAssertEqual(msg.reply_to, "m1")
        XCTAssertEqual(msg.content, "On it!")
    }

    func testDecodeOldPayloadReplyToNil() throws {
        let msg = try decodeOrThrow(
            ChatMessage.self,
            from: Data(
                #"{"id":"m1","sender":"A","timestamp":"t","content":"hi"}"#.utf8))
        XCTAssertNil(msg.reply_to)
    }

    func testQuotePreviewCollapsesAndTruncates() {
        XCTAssertEqual(ConversationStore.quotePreview("hi"), "hi")
        XCTAssertEqual(
            ConversationStore.quotePreview("a  b\n\tc"), "a b c")
        let long = String(repeating: "w", count: 200)
        let prev = ConversationStore.quotePreview(long)
        XCTAssertEqual(prev.count, 121)
        XCTAssertTrue(prev.hasSuffix("…"))
    }

    func testBeginAndCancelReply() {
        let store = ConversationStore.demo()
        XCTAssertNil(store.replyTarget)
        let parent = store.messages[1]
        store.beginReply(to: parent)
        XCTAssertEqual(store.replyTarget, parent)
        store.cancelReply()
        XCTAssertNil(store.replyTarget)
    }

    func testQuotedParentLookup() {
        let store = ConversationStore.demo()
        let plain = store.messages[0]
        XCTAssertNil(store.quotedParent(for: plain))
        // Synthetic reply onto a known parent resolves.
        let reply = ChatMessage(
            id: "r1", sender: "Me", timestamp: "t",
            content: "echo", isOwn: true, reply_to: plain.id)
        XCTAssertEqual(store.quotedParent(for: reply)?.id, plain.id)
        // Evicted parent id → nil (bubble shows the fallback line).
        let orphan = ChatMessage(
            id: "r2", sender: "Me", timestamp: "t",
            content: "orphan", isOwn: true, reply_to: "gone")
        XCTAssertNil(store.quotedParent(for: orphan))
    }

    func testDemoSendWithArmedReplyStampsAndDisarms() {
        let store = ConversationStore.demo()
        let parent = store.messages[0]
        store.beginReply(to: parent)
        store.send(text: "inline answer")
        XCTAssertNil(store.replyTarget)
        XCTAssertEqual(store.messages.last?.content, "inline answer")
        XCTAssertEqual(store.messages.last?.reply_to, parent.id)
    }

    func testRepliesThreadShape() {
        let msgs = DemoData.repliesMessages()
        XCTAssertEqual(msgs.count, 6)
        // Nested reply-to-reply chain resolves end to end.
        let store = ConversationStore()
        store.showDemo(
            chatID: DemoData.repliesID, chatName: "replies", messages: msgs)
        let nested = msgs[2]
        XCTAssertEqual(nested.reply_to, "rep-2")
        XCTAssertEqual(store.quotedParent(for: nested)?.id, "rep-2")
        // Evicted parent stays linked but unresolvable.
        let orphan = msgs[5]
        XCTAssertEqual(orphan.reply_to, "rep-0-evicted")
        XCTAssertNil(store.quotedParent(for: orphan))
        // Sidebar row tracks the thread tail.
        let row = DemoData.repliesChat()
        XCTAssertEqual(row.chatId, DemoData.repliesID)
        XCTAssertEqual(row.last_message_preview, msgs.last?.content)
    }

    /// Live FFI round-trip: blank parent/text rejected pre-network.
    func testLiveFFIReplyValidationThrows() {
        XCTAssertThrowsError(try RustCore.reply(
            chatID: "19:x", parentID: "", parentSender: "A", parentText: "hi", text: "yo"))
        XCTAssertThrowsError(try RustCore.reply(
            chatID: "19:x", parentID: "m1", parentSender: "A", parentText: "hi", text: "  "))
        XCTAssertThrowsError(try RustCore.reply(
            chatID: "", parentID: "m1", parentSender: "A", parentText: "hi", text: "yo"))
    }
}
