// ReactionsTests.swift — om-reactions lane: counts math, store
// add/remove/toggle, realtime patches, wire decoding, FFI validation.
import AppKit
import XCTest

@testable import OstMacCore

@MainActor
final class ReactionsTests: XCTestCase {
    // MARK: - Pure counts math

    func testAddBumpsAndAppendsInPickerOrder() {
        let one = ConversationStore.withReactionAdded([], emoji: "😂")
        XCTAssertEqual(one, [ReactionCount(emoji: "😂", count: 1)])
        let two = ConversationStore.withReactionAdded(one, emoji: "😂")
        XCTAssertEqual(two, [ReactionCount(emoji: "😂", count: 2)])
        // New buckets sort into canonical picker order, not append order.
        let mixed = ConversationStore.withReactionAdded(two, emoji: "👍")
        XCTAssertEqual(
            mixed,
            [ReactionCount(emoji: "👍", count: 1), ReactionCount(emoji: "😂", count: 2)])
    }

    func testRemoveDecrementsAndDropsAtZero() {
        let start = [
            ReactionCount(emoji: "👍", count: 2),
            ReactionCount(emoji: "❤️", count: 1),
        ]
        let dec = ConversationStore.withReactionRemoved(start, emoji: "👍")
        XCTAssertEqual(dec[0].count, 1)
        XCTAssertEqual(dec.count, 2)
        let dropped = ConversationStore.withReactionRemoved(dec, emoji: "👍")
        XCTAssertEqual(dropped, [ReactionCount(emoji: "❤️", count: 1)])
        // Missing emoji leaves the list untouched.
        XCTAssertEqual(
            ConversationStore.withReactionRemoved(dropped, emoji: "😂"), dropped)
    }

    // MARK: - Store add/remove/toggle (demo = local, no core)

    func testToggleAddsThenRemoves() {
        let store = ConversationStore.demo()
        let id = store.messages[0].id
        XCTAssertTrue(store.messages[0].reactions.isEmpty)
        store.toggleReaction(messageID: id, emoji: "👍")
        XCTAssertEqual(
            store.messages[0].reactions, [ReactionCount(emoji: "👍", count: 1)])
        store.toggleReaction(messageID: id, emoji: "👍")
        XCTAssertTrue(store.messages[0].reactions.isEmpty)
    }

    func testReactRejectsBadEmojiAndUnknownID() {
        // CONTRACT CHANGE (om-react-polish): the more-picker accepts any
        // single emoji (🎉 now reacts in demo — see ReactionPickerTests),
        // so rejection pins empty/multi-char strings instead of 🎉.
        let store = ConversationStore.demo()
        let id = store.messages[0].id
        store.react(messageID: id, emoji: "")
        store.toggleReaction(messageID: id, emoji: "")
        store.toggleReaction(messageID: id, emoji: "ab")
        store.toggleReaction(messageID: id, emoji: "👍👍")
        XCTAssertTrue(store.messages[0].reactions.isEmpty)
        store.toggleReaction(messageID: "nope", emoji: "👍")
        XCTAssertEqual(store.messages.count, ConversationStore.demoMessages.count)
    }

    func testApplyReactionsPatchesKnownOnly() {
        let store = ConversationStore.demo()
        let id = store.messages[1].id
        let counts = [ReactionCount(emoji: "❤️", count: 4)]
        store.applyReactions(id: id, reactions: counts)
        XCTAssertEqual(store.messages[1].reactions, counts)
        // Unknown ids never conjure a bubble.
        store.applyReactions(id: "nope", reactions: counts)
        XCTAssertEqual(store.messages.count, ConversationStore.demoMessages.count)
    }

    // MARK: - Realtime patches

    func testIngestRealtimeReactionOnlyPatchesCounts() {
        let store = ConversationStore.demo()
        let id = store.messages[0].id
        let before = store.messages.count
        store.ingest(realtime: RealtimeMessage(
            chatID: "demo", msgId: id, sender: "Megan Harper",
            text: "", time: "t", isEdit: false,
            reactions: [ReactionCount(emoji: "👍", count: 5)]))
        XCTAssertEqual(store.messages.count, before)
        XCTAssertEqual(
            store.messages[0].reactions, [ReactionCount(emoji: "👍", count: 5)])
        XCTAssertFalse(store.messages[0].content.isEmpty)
    }

    func testIngestRealtimeMessageCarriesCounts() {
        let store = ConversationStore.demo()
        let counts = [ReactionCount(emoji: "😂", count: 2)]
        store.ingest(realtime: RealtimeMessage(
            chatID: "demo", msgId: "live-1", sender: "Tom Becker",
            text: "fresh", time: "t", isEdit: false, reactions: counts))
        XCTAssertEqual(store.messages.last?.reactions, counts)
        // Events without counts leave the bubble's counts alone.
        store.ingest(realtime: RealtimeMessage(
            chatID: "demo", msgId: "live-1", sender: "Tom Becker",
            text: "fresh v2", time: "t", isEdit: true, editedID: "live-1"))
        XCTAssertEqual(store.messages.last?.content, "fresh v2")
        XCTAssertEqual(store.messages.last?.reactions, counts)
    }

    // MARK: - Wire decoding

    func testChatMessageDecodesReactions() throws {
        let data = Data("""
        {"id":"m1","sender":"A","timestamp":"t","content":"hi",
         "reactions":[{"emoji":"👍","count":2},{"emoji":"❤️","count":1}]}
        """.utf8)
        let m = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(m.reactions.count, 2)
        XCTAssertEqual(m.reactions[0], ReactionCount(emoji: "👍", count: 2))
        // Old payloads (no reactions key) decode to empty.
        let bare = try JSONDecoder().decode(
            ChatMessage.self,
            from: Data(#"{"id":"m1","sender":"A","timestamp":"t","content":"hi"}"#.utf8))
        XCTAssertTrue(bare.reactions.isEmpty)
    }

    func testRealtimeMessageDecodesReactions() throws {
        let data = Data("""
        {"chat_id":"c","id":"m1","sender":"A","text":"hi","time":"t",
         "is_edit":false,"reactions":[{"emoji":"😮","count":1}]}
        """.utf8)
        let m = try JSONDecoder().decode(RealtimeMessage.self, from: data)
        XCTAssertEqual(m.reactions, [ReactionCount(emoji: "😮", count: 1)])
        XCTAssertEqual(m.asChatMessage.reactions, m.reactions)
    }

    // MARK: - Picker help + demo thread

    func testReactionsDemoThread() {
        let msgs = DemoData.reactionsMessages()
        XCTAssertEqual(msgs.count, 3)
        XCTAssertFalse(msgs[0].reactions.isEmpty)
        XCTAssertEqual(msgs[0].reactions[0].emoji, "👍")
        XCTAssertEqual(msgs[0].reactions[0].count, 3)
        // core-a: demo thread carries canned reactors (who-reacted).
        XCTAssertEqual(msgs[0].reactions[0].reactorNames(), ["Tom Becker", "Ava Lindqvist", "Me"])
        XCTAssertTrue(msgs[2].reactions.isEmpty)
        XCTAssertEqual(DemoData.messages(for: DemoData.reactionsID).count, 3)
    }

    // MARK: - Menu anchor geometry

    // MARK: - Picker crash (om-p0-pickercrash)

    // MARK: - Picker dismiss (om-react-picker: Esc path)

    // MARK: - Live FFI validation (arg rejection, no network)

    func testLiveFFIReactRejectsBadArgs() {
        XCTAssertThrowsError(try RustCore.react(chatID: "", messageID: "m1", emoji: "👍"))
        XCTAssertThrowsError(try RustCore.react(chatID: "19:x", messageID: "", emoji: "👍"))
        XCTAssertThrowsError(try RustCore.react(chatID: "19:x", messageID: "m1", emoji: "🎉"))
        XCTAssertThrowsError(try RustCore.removeReaction(chatID: "19:x", messageID: "m1", emoji: ""))
    }
}
