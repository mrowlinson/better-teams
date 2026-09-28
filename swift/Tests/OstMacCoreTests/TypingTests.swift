// TypingTests.swift — om-typing lane: envelope decode, feed dispatch,
// per-thread state, timeout expiry, multi-typer render.
import XCTest

@testable import OstMacCore

@MainActor
final class TypingTests: XCTestCase {
    private let chatA = "19:aaa@thread.v2"
    private let chatB = "19:bbb@thread.v2"

    private func pollWithTyping() throws -> RealtimePoll {
        let json = """
        {"ok":true,"resync":false,"skipped":0,"messages":[],
        "typing":[
        {"chat_id":"\(chatA)","sender":"Doe, Jane",
         "sender_id":"8:orgid:aaa","time":"2026-09-22T14:25:45Z"},
        {"chat_id":"\(chatA)","sender":"Bob",
         "time":"2026-09-22T14:25:46Z"}]}
        """
        return try decodeOrThrow(RealtimePoll.self, from: Data(json.utf8))
    }

    func testTypingEnvelopeDecode() throws {
        let p = try pollWithTyping()
        let typing = try XCTUnwrap(p.typing)
        XCTAssertEqual(typing.count, 2)
        XCTAssertEqual(typing[0].chatID, chatA)
        XCTAssertEqual(typing[0].sender, "Doe, Jane")
        XCTAssertEqual(typing[0].senderID, "8:orgid:aaa")
        XCTAssertNil(typing[1].senderID)
        XCTAssertTrue(typing[0].isFor(chatID: chatA))
        XCTAssertFalse(typing[0].isFor(chatID: chatB))
        XCTAssertFalse(typing[0].isFor(chatID: nil))
    }

    func testOldCoreWithoutTypingDecodesAsNil() throws {
        let json = #"{"ok":true,"resync":false,"skipped":0,"messages":[]}"#
        let p = try decodeOrThrow(RealtimePoll.self, from: Data(json.utf8))
        XCTAssertNil(p.typing)
        // No events, no crash: the feed simply has nothing to dispatch.
        let feed = RealtimeFeed(poll: { p })
        let n = LockedBox(0)
        feed.onTyping { _ in n.mutate { $0 += 1 } }
        _ = try feed.pollOnce()
        XCTAssertEqual(n.value, 0)
    }

    func testFeedDispatchesTypingWithoutDedupe() throws {
        let p = try pollWithTyping()
        let feed = RealtimeFeed(poll: { p })
        let got = LockedBox<[String]>([])
        feed.onTyping { t in got.mutate { $0.append(t.sender) } }
        _ = try feed.pollOnce()
        XCTAssertEqual(got.value, ["Doe, Jane", "Bob"])
        // Repeats are the keepalive: redelivery dispatches again.
        _ = try feed.pollOnce()
        XCTAssertEqual(got.value, ["Doe, Jane", "Bob", "Doe, Jane", "Bob"])
    }

    func testIngestDrivesPerThreadLine() {
        let store = TypingStore()
        let now = Date()
        XCTAssertNil(store.line(chatID: chatA, at: now))
        store.ingest(TypingEvent(chatID: chatA, sender: "Doe, Jane"), at: now)
        XCTAssertEqual(
            store.line(chatID: chatA, at: now), "Doe, Jane is typing…")
        // Other threads and nil (nothing open) stay quiet.
        XCTAssertNil(store.line(chatID: chatB, at: now))
        XCTAssertNil(store.line(chatID: nil, at: now))
    }

    func testExpiryDropsStaleIndicators() {
        let store = TypingStore()
        store.timeout = 10
        let t0 = Date()
        store.ingest(TypingEvent(chatID: chatA, sender: "Doe, Jane"), at: t0)
        XCTAssertEqual(store.typists(chatID: chatA, at: t0), ["Doe, Jane"])
        // Just before the timeout: still live; at/after: gone.
        XCTAssertEqual(
            store.typists(chatID: chatA, at: t0.addingTimeInterval(9.9)),
            ["Doe, Jane"])
        XCTAssertTrue(store.typists(
            chatID: chatA, at: t0.addingTimeInterval(10)).isEmpty)
        XCTAssertNil(store.line(
            chatID: chatA, at: t0.addingTimeInterval(60)))
        store.prune(at: t0.addingTimeInterval(60))
        XCTAssertTrue(store.byChat.isEmpty)
        XCTAssertEqual(store.activeCount, 0)
    }

    func testRefreshExtendsTimeout() {
        let store = TypingStore()
        store.timeout = 10
        let t0 = Date()
        store.ingest(TypingEvent(chatID: chatA, sender: "Doe, Jane"), at: t0)
        store.ingest(
            TypingEvent(chatID: chatA, sender: "Doe, Jane"),
            at: t0.addingTimeInterval(9))
        // Alive 9s after the refresh (would have expired on t0 alone).
        XCTAssertEqual(
            store.typists(chatID: chatA, at: t0.addingTimeInterval(18)),
            ["Doe, Jane"])
        XCTAssertTrue(store.typists(
            chatID: chatA, at: t0.addingTimeInterval(19.1)).isEmpty)
    }

    func testMultiTyperRender() {
        XCTAssertNil(TypingFormat.line(names: []))
        XCTAssertEqual(
            TypingFormat.line(names: ["Amy"]), "Amy is typing…")
        XCTAssertEqual(
            TypingFormat.line(names: ["Amy", "Bob"]),
            "Amy and Bob are typing…")
        XCTAssertEqual(
            TypingFormat.line(names: ["Amy", "Bob", "Cy"]),
            "Amy, Bob and Cy are typing…")
        XCTAssertEqual(
            TypingFormat.line(names: ["Amy", "Bob", "Cy", "Dee"]),
            "Amy, Bob and 2 others are typing…")
    }

    func testStoreSortsTypistsForStableLine() {
        let store = TypingStore()
        let now = Date()
        store.ingest(TypingEvent(chatID: chatA, sender: "Zed"), at: now)
        store.ingest(TypingEvent(chatID: chatA, sender: "Amy"), at: now)
        XCTAssertEqual(
            store.line(chatID: chatA, at: now), "Amy and Zed are typing…")
    }

    func testMessageSupersedesIndicator() {
        let store = TypingStore()
        let now = Date()
        store.ingest(TypingEvent(
            chatID: chatA, sender: "Doe, Jane", senderID: "8:orgid:aaa"),
            at: now)
        store.ingest(TypingEvent(chatID: chatA, sender: "Bob"), at: now)
        // MRI-keyed entry clears by id…
        store.noteMessage(
            chatID: chatA, sender: "Doe, Jane", senderID: "8:orgid:aaa")
        XCTAssertEqual(store.typists(chatID: chatA, at: now), ["Bob"])
        // …name-keyed entry clears by display name.
        store.noteMessage(chatID: chatA, sender: "Bob")
        XCTAssertNil(store.line(chatID: chatA, at: now))
        // Unknown senders and chats are a no-op.
        store.noteMessage(chatID: chatA, sender: "Ghost")
        store.noteMessage(chatID: chatB, sender: "Bob")
    }

    func testIngestIgnoresUnattributableEvents() {
        let store = TypingStore()
        let now = Date()
        store.ingest(TypingEvent(chatID: "", sender: "Amy"), at: now)
        store.ingest(TypingEvent(chatID: chatA, sender: ""), at: now)
        XCTAssertTrue(store.byChat.isEmpty)
        XCTAssertNil(store.line(chatID: chatA, at: now))
    }

    func testClearDropsEverything() {
        let store = TypingStore()
        store.ingest(TypingEvent(chatID: chatA, sender: "Amy"))
        store.ingest(TypingEvent(chatID: chatB, sender: "Bob"))
        store.clear()
        XCTAssertTrue(store.byChat.isEmpty)
    }

    func testTypingLineCounters() {
        XCTAssertEqual(
            DiagnosticsFormat.typingLine(events: 0, active: 0),
            "0 events · 0 active")
        XCTAssertEqual(
            DiagnosticsFormat.typingLine(events: 12, active: 2),
            "12 events · 2 active")
    }

}
