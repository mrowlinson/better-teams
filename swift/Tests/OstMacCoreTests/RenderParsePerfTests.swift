// RenderParsePerfTests.swift — om-s6-renderparse: perf guards.
// Counts and caps only, never timings: memoization hit/miss counts,
// cache-cap bounds, and indexed-vs-linear equivalence.
import Combine
import XCTest

@testable import OstMacCore

@MainActor
final class RenderParsePerfTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MessageRender.resetRenderCaches()
    }

    override func tearDown() {
        MessageRender.resetRenderCaches()
        super.tearDown()
    }

    private static func msg(
        _ id: String, content: String = "hello @Megan check `x` https://example.com",
        raw: String? = "<p>hello <at>@Megan</at> check `x` <a href=\"https://example.com\">l</a></p>",
        ts: String = "2026-09-22T10:00:00Z", reply: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id, sender: "Tom", timestamp: ts, content: content,
            raw: raw, reply_to: reply)
    }

    // MARK: - Bubble-parse memo

    func testBubbleTextMemoizedPerID() {
        let m = Self.msg("p1")
        XCTAssertEqual(MessageRender.bubbleText(for: m), MessageRender.bubbleText(for: m))
        XCTAssertEqual(MessageRender.renderStats().0, 1)
    }

    func testBubbleTextInvalidatesOnContentChange() {
        var m = Self.msg("p2")
        _ = MessageRender.bubbleText(for: m)
        m.content += " more"
        let again = MessageRender.bubbleText(for: m)
        XCTAssertEqual(MessageRender.renderStats().0, 2)
        XCTAssertTrue(again.hasSuffix("more"))
    }

    func testBubbleTextInvalidatesOnRawChange() {
        var m = Self.msg("p3")
        let first = MessageRender.bubbleText(for: m)
        m.raw = "<attachment><a href=\"https://example.com/s\">T</a></attachment>"
        let second = MessageRender.bubbleText(for: m)
        XCTAssertEqual(MessageRender.renderStats().0, 2)
        XCTAssertNotEqual(first, second)
    }

    func testImagesAndPostsMemoized() {
        let m = Self.msg("p4", raw: "<p>t</p><img src=\"https://example.com/a.jpg\"/>")
        _ = MessageRender.images(fromRaw: m.raw)
        _ = MessageRender.images(fromRaw: m.raw)
        _ = MessageRender.botPosts(fromRaw: m.raw)
        _ = MessageRender.botPosts(fromRaw: m.raw)
        let s = MessageRender.renderStats()
        XCTAssertEqual(s.1, 1)
        XCTAssertEqual(s.2, 1)
    }

    func testStyledMemoizedPerInputs() {
        let m = Self.msg("p5")
        let t = MessageRender.bubbleText(for: m)
        let a = MessageRender.attributedBody(text: t, raw: m.raw, highlighting: "Me")
        let b = MessageRender.attributedBody(text: t, raw: m.raw, highlighting: "Me")
        XCTAssertEqual(a, b)
        XCTAssertEqual(MessageRender.renderStats().3, 1)
        _ = MessageRender.attributedBody(text: t, raw: m.raw, highlighting: "Tom")
        XCTAssertEqual(MessageRender.renderStats().3, 2)
    }

    func testRenderCacheCapped() {
        for i in 0 ..< (MessageRender.maxRenderCacheEntries + 200) {
            _ = MessageRender.bubbleText(for: Self.msg("cap-\(i)"))
        }
        XCTAssertLessThanOrEqual(
            MessageRender.renderCacheCount(), MessageRender.maxRenderCacheEntries)
    }

    // MARK: - Section memo

    func testSectionsMemoized() {
        let msgs = [Self.msg("s1"), Self.msg("s2", ts: "2026-09-23T10:00:00Z")]
        let a = MessageRender.daySections(msgs)
        let b = MessageRender.daySections(msgs)
        XCTAssertEqual(a.map(\.key), b.map(\.key))
        XCTAssertEqual(MessageRender.renderStats().4, 1)
        _ = MessageRender.daySections(msgs + [Self.msg("s3")])
        XCTAssertEqual(MessageRender.renderStats().4, 2)
    }

    func testSectionsGrouping() {
        let msgs = [
            Self.msg("g1", ts: "2026-09-22T09:00:00Z"),
            Self.msg("g2", ts: "2026-09-22T10:00:00Z"),
            Self.msg("g3", ts: "2026-09-23T10:00:00Z"),
        ]
        let out = MessageRender.daySections(msgs)
        XCTAssertEqual(out.map(\.key), ["2026-09-22", "2026-09-23"])
        XCTAssertEqual(out[0].messages.map(\.id), ["g1", "g2"])
        XCTAssertEqual(out[1].messages.map(\.id), ["g3"])
        XCTAssertEqual(
            out.map(\.label),
            [MessageRender.dayLabel("2026-09-22"), MessageRender.dayLabel("2026-09-23")])
    }

    // MARK: - Indexed lookups match linear scans

    func testMessageIndexMatchesLinear() {
        let msgs = (0 ..< 20).map {
            Self.msg("m-\($0)", reply: $0 % 4 == 3 ? "m-\($0 - 3)" : nil)
        }
        let store = ConversationStore()
        store.showDemo(chatID: "c", chatName: "c", messages: msgs)
        let index = MessageIndex(msgs)
        for m in msgs {
            XCTAssertEqual(
                store.quotedParent(for: m, in: index)?.id,
                store.quotedParent(for: m)?.id)
        }
        let peers: Set<String> = ["m-19"]
        for m in msgs {
            XCTAssertEqual(
                ReceiptStore.isRead(messageID: m.id, position: index.position, peerIDs: peers),
                ReceiptStore.isRead(messageID: m.id, messages: msgs, peerIDs: peers))
        }
        let pins = (0 ..< 4).map {
            PinnedMessage(
                messageID: "m-\($0 * 5)", sender: "s",
                preview: "p", timestamp: "t", pinnedAt: Double($0))
        }
        XCTAssertEqual(
            PinnedMessages.rows(pins: pins, messages: msgs, index: index),
            PinnedMessages.rows(pins: pins, messages: msgs))
    }

    func testChatIndexMatchesLinear() {
        let chats = (0 ..< 30).map {
            ChatItem(chatId: "c\($0)", name: "Chat \($0)", is_group: $0 % 2 == 0)
        }
        let model = ChatListViewModel(fetcher: { _ in
            ChatsResponse(ok: true, chats: chats)
        })
        let exp = expectation(description: "load")
        Task { await model.load(); exp.fulfill() }
        wait(for: [exp], timeout: 5)
        for c in chats {
            XCTAssertEqual(model.chat(id: c.id)?.name, c.name)
        }
        XCTAssertNil(model.chat(id: "missing"))
    }

    func testBatchIngestEqualsSequentialFold() {
        let list = (0 ..< 10).map {
            ChatItem(chatId: "c\($0)", name: "Chat \($0)")
        }
        let burst = (0 ..< 25).map { i in
            RealtimeMessage(
                chatID: "c\(i % 10)", msgId: "m\(i)", sender: "S\(i)",
                text: "burst \(i)", time: "2026-09-22T10:00:00Z",
                isEdit: i % 7 == 6)
        }
        let want = burst.reduce(list) { ChatListViewModel.ingested($1, into: $0) }
        XCTAssertEqual(ChatListViewModel.ingested(burst, into: list), want)
    }

    // MARK: - Typing publish-on-change

    func testTypingSkipsIdenticalRedelivery() {
        let t = TypingStore()
        var publishes = 0
        var bag = Set<AnyCancellable>()
        t.objectWillChange.sink { publishes += 1 }.store(in: &bag)
        let now = Date()
        let ev = TypingEvent(chatID: "c", sender: "Megan", senderID: "mri")
        t.ingest(ev, at: now)
        t.ingest(ev, at: now)
        XCTAssertEqual(publishes, 1)
        t.prune(at: now)
        XCTAssertEqual(publishes, 1)
        t.noteMessage(chatID: "c", sender: "Nobody", senderID: "ghost")
        XCTAssertEqual(publishes, 1)
        t.noteMessage(chatID: "c", sender: "Megan", senderID: "mri")
        XCTAssertEqual(publishes, 2)
        t.clear()
        XCTAssertEqual(publishes, 2)
        _ = bag
    }
}
