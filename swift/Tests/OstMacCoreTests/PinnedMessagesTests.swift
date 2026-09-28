// PinnedMessagesTests.swift — om-pinmessages lane: store pin/unpin,
// per-thread persistence + restart, strip model, jump targets.
import XCTest

@testable import OstMacCore

@MainActor
final class PinnedMessagesTests: XCTestCase {
    private func msg(
        id: String = "m1", sender: String = "Ava Lindqvist",
        timestamp: String = "2026-09-22T08:41:02Z",
        content: String = "Morning! Can you review the empty-states mock?"
    ) -> ChatMessage {
        ChatMessage(id: id, sender: sender, timestamp: timestamp, content: content)
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-pins-\(UUID().uuidString)") ?? .standard
    }

    private func store(_ defaults: UserDefaults? = nil) -> PinnedMessageStore {
        PinnedMessageStore(defaults: defaults ?? isolatedDefaults())
    }

    // MARK: - Pin / unpin

    func testPinAddsAndIsPinned() {
        let s = store()
        XCTAssertFalse(s.isPinned(chatID: "demo-2", messageID: "m1"))
        s.pin(chatID: "demo-2", message: msg())
        XCTAssertTrue(s.isPinned(chatID: "demo-2", messageID: "m1"))
        XCTAssertEqual(s.pins(for: "demo-2").map(\.messageID), ["m1"])
    }

    func testPinIsIdempotent() {
        let s = store()
        s.pin(chatID: "demo-2", message: msg())
        s.pin(chatID: "demo-2", message: msg())
        XCTAssertEqual(s.pins(for: "demo-2").count, 1)
    }

    func testUnpinRemoves() {
        let s = store()
        s.pin(chatID: "demo-2", message: msg(id: "m1"))
        s.pin(chatID: "demo-2", message: msg(id: "m2"))
        s.unpin(chatID: "demo-2", messageID: "m1")
        XCTAssertFalse(s.isPinned(chatID: "demo-2", messageID: "m1"))
        XCTAssertTrue(s.isPinned(chatID: "demo-2", messageID: "m2"))
        XCTAssertEqual(s.pins(for: "demo-2").map(\.messageID), ["m2"])
    }

    func testUnpinUnknownNoop() {
        let s = store()
        s.pin(chatID: "demo-2", message: msg(id: "m1"))
        s.unpin(chatID: "demo-2", messageID: "nope")
        s.unpin(chatID: "other", messageID: "m1")
        XCTAssertEqual(s.pins(for: "demo-2").map(\.messageID), ["m1"])
        XCTAssertTrue(s.pins(for: "other").isEmpty)
    }

    func testBlankIDsNoop() {
        let s = store()
        s.pin(chatID: "   ", message: msg())
        s.pin(chatID: "demo-2", message: msg(id: "  "))
        s.pin(chatID: nil, message: msg())
        XCTAssertTrue(s.pins(for: "demo-2").isEmpty)
        XCTAssertTrue(s.pins(for: "   ").isEmpty)
        XCTAssertTrue(s.pins(for: nil).isEmpty)
        XCTAssertFalse(s.isPinned(chatID: "demo-2", messageID: "  "))
        s.unpin(chatID: "  ", messageID: "m1")
        s.unpin(chatID: "demo-2", messageID: " ")
    }

    func testTogglePinsAndUnpins() {
        let s = store()
        let m = msg()
        s.toggle(chatID: "demo-2", message: m)
        XCTAssertTrue(s.isPinned(chatID: "demo-2", messageID: "m1"))
        s.toggle(chatID: "demo-2", message: m)
        XCTAssertFalse(s.isPinned(chatID: "demo-2", messageID: "m1"))
    }

    func testPinsArePerThread() {
        let s = store()
        // Same message id in two threads pins independently.
        s.pin(chatID: "demo-2", message: msg(id: "m1"))
        XCTAssertTrue(s.isPinned(chatID: "demo-2", messageID: "m1"))
        XCTAssertFalse(s.isPinned(chatID: "demo-3", messageID: "m1"))
        s.pin(chatID: "demo-3", message: msg(id: "m1"))
        XCTAssertTrue(s.isPinned(chatID: "demo-3", messageID: "m1"))
        s.unpin(chatID: "demo-2", messageID: "m1")
        XCTAssertFalse(s.isPinned(chatID: "demo-2", messageID: "m1"))
        XCTAssertTrue(s.isPinned(chatID: "demo-3", messageID: "m1"))
    }

    func testMenuTitle() {
        XCTAssertEqual(PinnedMessages.menuTitle(isPinned: false), "Pin")
        XCTAssertEqual(PinnedMessages.menuTitle(isPinned: true), "Unpin")
    }

    // MARK: - Persist / restart

    func testPersistSurvivesRestart() {
        let defaults = isolatedDefaults()
        let first = PinnedMessageStore(defaults: defaults)
        first.pin(chatID: "demo-2", message: msg(id: "ava-1"))
        first.pin(chatID: "demo-2", message: msg(id: "ava-2", content: "Second"))
        XCTAssertEqual(first.pins(for: "demo-2").count, 2)
        // Restart = a fresh instance over the same defaults.
        let second = PinnedMessageStore(defaults: defaults)
        XCTAssertEqual(
            second.pins(for: "demo-2").map(\.messageID), ["ava-1", "ava-2"])
        XCTAssertTrue(second.isPinned(chatID: "demo-2", messageID: "ava-1"))
    }

    func testUnpinPersistsAcrossRestart() {
        let defaults = isolatedDefaults()
        let first = PinnedMessageStore(defaults: defaults)
        first.pin(chatID: "demo-2", message: msg(id: "m1"))
        first.pin(chatID: "demo-2", message: msg(id: "m2"))
        first.unpin(chatID: "demo-2", messageID: "m1")
        let second = PinnedMessageStore(defaults: defaults)
        XCTAssertEqual(second.pins(for: "demo-2").map(\.messageID), ["m2"])
    }

    func testCorruptPayloadYieldsEmpty() {
        let defaults = isolatedDefaults()
        defaults.set(Data("not-json".utf8), forKey: PinnedMessages.defaultsKey)
        let s = PinnedMessageStore(defaults: defaults)
        XCTAssertTrue(s.pins(for: "demo-2").isEmpty)
    }

    func testMissingPayloadYieldsEmpty() {
        let s = store()
        XCTAssertTrue(s.pins(for: "demo-2").isEmpty)
        XCTAssertTrue(s.rows(for: "demo-2", messages: [msg()]).isEmpty)
    }

    func testPinsSurviveNewMessages() {
        let s = store()
        s.pin(chatID: "demo-2", message: msg(id: "ava-1"))
        let before = s.rows(for: "demo-2", messages: [msg(id: "ava-1")])
        XCTAssertEqual(before.count, 1)
        // New mail lands: the pin stays, still resolving to its bubble.
        let after = s.rows(
            for: "demo-2",
            messages: [msg(id: "ava-1"), msg(id: "ava-2"), msg(id: "ava-3")])
        XCTAssertEqual(after.map(\.messageID), ["ava-1"])
        XCTAssertTrue(after[0].isAvailable)
    }

    // MARK: - Strip model

    func testRowsEmptyWhenNone() {
        XCTAssertTrue(PinnedMessages.rows(pins: [], messages: [msg()]).isEmpty)
    }

    func testRowsSortByPinTime() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = Date(timeIntervalSince1970: 2000)
        let late = PinnedMessage.from(message: msg(id: "late"), at: t1)
        let early = PinnedMessage.from(message: msg(id: "early"), at: t0)
        let rows = PinnedMessages.rows(
            pins: [late, early], messages: [msg(id: "late"), msg(id: "early")])
        XCTAssertEqual(rows.map(\.messageID), ["early", "late"])
    }

    func testRowsPreferLiveContent() {
        let s = store()
        s.pin(chatID: "demo-2", message: msg(id: "m1", content: "original"))
        // The bubble edited after pinning: the strip tracks the live text.
        let rows = s.rows(
            for: "demo-2", messages: [msg(id: "m1", content: "edited text")])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].preview, "edited text")
        XCTAssertTrue(rows[0].isAvailable)
    }

    func testRowsFallBackToSnapshotWhenMissing() {
        let pin = PinnedMessage(
            messageID: "old-1", sender: "Ava Lindqvist",
            preview: "aged out", timestamp: "2026-09-20T08:00:00Z",
            pinnedAt: 1000)
        let rows = PinnedMessages.rows(pins: [pin], messages: [msg(id: "m1")])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].preview, "aged out")
        XCTAssertEqual(rows[0].sender, "Ava Lindqvist")
        XCTAssertFalse(rows[0].isAvailable)
    }

    func testPreviewCollapsesAndTruncates() {
        XCTAssertEqual(
            PinnedMessages.preview(for: msg(content: "a  b\n\tc")), "a b c")
        XCTAssertEqual(PinnedMessages.preview(for: msg(content: "")), "(no text)")
        XCTAssertEqual(PinnedMessages.preview(for: msg(content: "   ")), "(no text)")
        // Shortcodes expand, exactly as the bubble renders.
        XCTAssertEqual(
            PinnedMessages.preview(for: msg(content: "(thumbsup) ok")), "👍 ok")
        let long = String(repeating: "w", count: 200)
        let prev = PinnedMessages.preview(for: msg(content: long))
        XCTAssertEqual(prev.count, PinnedMessages.previewMax + 1)
        XCTAssertTrue(prev.hasSuffix("…"))
    }

    // MARK: - Jump target

    func testJumpTargetHit() {
        let messages = [msg(id: "a"), msg(id: "b")]
        XCTAssertEqual(PinnedMessages.jumpTarget(pinID: "b", messages: messages), "b")
    }

    func testJumpTargetMiss() {
        let messages = [msg(id: "a")]
        XCTAssertNil(PinnedMessages.jumpTarget(pinID: "missing", messages: messages))
        XCTAssertNil(PinnedMessages.jumpTarget(pinID: "  ", messages: messages))
        XCTAssertNil(PinnedMessages.jumpTarget(pinID: "", messages: messages))
        XCTAssertNil(PinnedMessages.jumpTarget(pinID: "a", messages: []))
    }

    // MARK: - Sanitize / adopt

    func testSanitizeDropsBlanksAndDedupes() {
        let clean = PinnedMessages.sanitize([
            "  ": [PinnedMessage(
                messageID: "m1", sender: "A", preview: "p",
                timestamp: "t", pinnedAt: 1)],
            "demo-2": [
                PinnedMessage(
                    messageID: "  ", sender: "A", preview: "p",
                    timestamp: "t", pinnedAt: 1),
                PinnedMessage(
                    messageID: "m1", sender: "A", preview: "first",
                    timestamp: "t", pinnedAt: 2),
                PinnedMessage(
                    messageID: "m1", sender: "A", preview: "second",
                    timestamp: "t", pinnedAt: 1),
            ],
        ])
        XCTAssertNil(clean["  "])
        XCTAssertEqual(clean["demo-2"]?.count, 1)
        // Earliest pin wins the dedupe.
        XCTAssertEqual(clean["demo-2"]?.first?.preview, "second")
    }

    func testAdoptReplacesThread() {
        let s = store()
        s.pin(chatID: "demo-2", message: msg(id: "m1"))
        s.adopt(chatID: "demo-2", pins: [
            PinnedMessage(
                messageID: "n1", sender: "Ava", preview: "hello",
                timestamp: "t", pinnedAt: 5),
        ])
        XCTAssertEqual(s.pins(for: "demo-2").map(\.messageID), ["n1"])
        s.adopt(chatID: "demo-2", pins: [])
        XCTAssertTrue(s.pins(for: "demo-2").isEmpty)
    }
}
