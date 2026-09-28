// MessageActionsTests.swift — om-msgactions lane: copy/forward/save pure
// helpers + ConversationStore.forward demo/no-op semantics.
import XCTest

@testable import OstMacCore

@MainActor
final class MessageActionsTests: XCTestCase {
    private func msg(
        id: String = "m1", sender: String = "Tom Becker",
        timestamp: String = "2026-09-22T09:04:47Z",
        content: String = "Pushed new mocks last night."
    ) -> ChatMessage {
        ChatMessage(id: id, sender: sender, timestamp: timestamp, content: content)
    }

    // MARK: - Copy / forward text

    func testCopyTextIsBubbleDisplay() {
        XCTAssertEqual(MessageActions.copyText(for: msg()), "Pushed new mocks last night.")
        // Shortcodes expand, exactly as the bubble renders.
        XCTAssertEqual(
            MessageActions.copyText(for: msg(content: "(thumbsup) ok (party)")),
            "👍 ok 🥳")
        // Unknown codes pass through untouched.
        XCTAssertEqual(
            MessageActions.copyText(for: msg(content: "(see note)")),
            "(see note)")
    }

    func testForwardBodyCarriesAttribution() {
        let m = msg(content: "(clap) Gorgeous")
        XCTAssertEqual(
            MessageActions.forwardBody(for: m),
            "Forwarded from Tom Becker:\n👏 Gorgeous")
    }

    func testForwardPreviewCollapsesAndTruncates() {
        XCTAssertEqual(
            MessageActions.forwardPreview(for: msg(content: "a  b\n\tc")), "a b c")
        XCTAssertEqual(
            MessageActions.forwardPreview(for: msg(content: "")),
            "(no text)")
        XCTAssertEqual(
            MessageActions.forwardPreview(for: msg(content: "   ")),
            "(no text)")
        let long = String(repeating: "w", count: 200)
        let prev = MessageActions.forwardPreview(for: msg(content: long))
        XCTAssertEqual(prev.count, 121)
        XCTAssertTrue(prev.hasSuffix("…"))
    }

    // MARK: - Save body / filename

    func testSaveBodyCarriesHeaderAndText() {
        let body = MessageActions.saveBody(for: msg())
        XCTAssertTrue(body.hasPrefix(
            "From: Tom Becker\nDate: 2026-09-22T09:04:47Z\n\n"))
        XCTAssertTrue(body.contains("Pushed new mocks last night."))
        XCTAssertTrue(body.hasSuffix("\n"))
    }

    func testSaveBodyUsesRawTimestampVerbatim() {
        let odd = msg(timestamp: "not-a-date")
        XCTAssertTrue(MessageActions.saveBody(for: odd).contains("Date: not-a-date\n"))
    }

    func testSaveFilenameSimpleID() {
        XCTAssertEqual(MessageActions.saveFilename(for: msg(id: "demo-1")), "message-demo-1.txt")
    }

    func testSaveFilenameSanitizesHostileID() {
        let name = MessageActions.saveFilename(for: msg(id: "19:abc/def@thread.tacv2"))
        XCTAssertTrue(name.hasSuffix(".txt"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains("@"))
        XCTAssertEqual(name, "message-19-abc-def-thread.tacv2.txt")
    }

    func testSanitizedFilenameEdges() {
        XCTAssertEqual(MessageActions.sanitizedFilename(""), "")
        XCTAssertEqual(MessageActions.sanitizedFilename("..."), "")
        XCTAssertEqual(MessageActions.sanitizedFilename("a/b\\c:d"), "a-b-c-d")
        XCTAssertEqual(MessageActions.sanitizedFilename("--x--"), "x")
        let long = String(repeating: "a", count: 100)
        XCTAssertEqual(MessageActions.sanitizedFilename(long).count, 60)
    }

    // MARK: - ConversationStore.forward

    func testForwardDemoRecords() {
        let store = ConversationStore.demo()
        XCTAssertNil(store.lastForward)
        let m = store.messages[1]
        store.forward(m, toChatID: "demo-2", destName: "Ava Lindqvist")
        XCTAssertEqual(
            store.lastForward,
            MessageActions.ForwardRecord(
                messageID: m.id, destChatID: "demo-2",
                body: "Forwarded from Tom Becker:\n\(m.content)"))
        XCTAssertEqual(store.lastForwardDestName, "Ava Lindqvist")
        // Forwarding never mutates the open thread.
        XCTAssertEqual(store.messages.count, ConversationStore.demoMessages.count)
    }

    func testForwardTrimsDestination() {
        let store = ConversationStore.demo()
        store.forward(store.messages[0], toChatID: "  demo-3\n")
        XCTAssertEqual(store.lastForward?.destChatID, "demo-3")
    }

    func testForwardEmptyDestNoop() {
        let store = ConversationStore.demo()
        store.forward(store.messages[0], toChatID: "   ")
        XCTAssertNil(store.lastForward)
        XCTAssertNil(store.lastForwardDestName)
    }

    func testForwardEmptyBodyNoop() {
        let store = ConversationStore.demo()
        let imageOnly = msg(id: "img", content: "")
        store.forward(imageOnly, toChatID: "demo-2")
        XCTAssertNil(store.lastForward)
    }

    func testForwardEmptyDestNoopLiveWithoutError() {
        // Live (non-demo) store: the empty-dest guard fires before any
        // core call, so no error surfaces and nothing records.
        let store = ConversationStore()
        store.forward(msg(), toChatID: "")
        XCTAssertNil(store.lastForward)
        XCTAssertNil(store.error)
    }

    /// Forward reuses the plain send path: core rejects blank
    /// destinations pre-network (same guard the live forward relies on).
    func testLiveFFIForwardSendGuardThrows() {
        XCTAssertThrowsError(try RustCore.send(chatID: "", text: "hi"))
        XCTAssertThrowsError(try RustCore.send(chatID: "19:x", text: "  "))
    }
}
