// RichConversationTests.swift — om-convrich: render spans, sections,
// paging prepend, edited + failed states.
import XCTest

@testable import OstMacCore

@MainActor
final class RichConversationTests: XCTestCase {
    // MARK: - Raw mining

    func testMentionMining() {
        let raw = #"<p>Hi <at id="8:x">Doe, Jane</at> &amp; <at id="8:y">Bo</at>!</p>"#
        XCTAssertEqual(MessageRender.mentions(fromRaw: raw), ["Doe, Jane", "Bo"])
        XCTAssertEqual(MessageRender.mentions(fromRaw: nil), [])
        XCTAssertEqual(MessageRender.mentions(fromRaw: "<p>no tags</p>"), [])
    }

    func testCodeBlockMining() {
        let raw = "<p>run it</p><pre><code>let x = 1 &amp; 2</code></pre>"
        XCTAssertEqual(MessageRender.codeBlocks(fromRaw: raw), ["let x = 1 & 2"])
        XCTAssertEqual(MessageRender.codeBlocks(fromRaw: nil), [])
    }

    func testBacktickSpans() {
        let spans = MessageRender.backtickSpans(in: "run `a b` then `c` end")
        XCTAssertEqual(spans.count, 2)
        // Unbalanced backtick: no span.
        XCTAssertEqual(MessageRender.backtickSpans(in: "oops `x end").count, 0)
    }

    func testMentionTokenFallback() {
        XCTAssertEqual(MessageRender.mentionTokens(in: "hi @Doe, Jane ok"), ["Doe, Jane ok"])
        XCTAssertEqual(MessageRender.mentionTokens(in: "no mention"), [])
    }

    func testEntityDecode() {
        XCTAssertEqual(MessageRender.decodeEntities("a &amp; b &lt;x&gt;"), "a & b <x>")
    }

    // MARK: - Tag stripping (om-chatnames: block-boundary spacing)

    func testStripTagsBlockBoundaries() {
        XCTAssertEqual(MessageRender.stripTags("<p>hi</p>"), "hi")
        XCTAssertEqual(MessageRender.stripTags("<p>Hello</p><p>World</p>"), "Hello World")
        XCTAssertEqual(MessageRender.stripTags("a<br>b"), "a b")
        XCTAssertEqual(MessageRender.stripTags("a<b>x</b>b"), "axb")
        XCTAssertEqual(MessageRender.stripTags("<P>a</P><p>b</p>"), "a b")
    }

    // MARK: - Attributed body styling

    /// Bold range lands exactly on the mined mention name.
    func testAttributedBodyBoldMention() {
        let m = ChatMessage(
            id: "m", sender: "A", timestamp: "t",
            content: "Hi @Bo, ship it",
            raw: #"<p>Hi <at id="8:b">@Bo</at>, ship it</p>"#)
        let a = MessageRender.attributedBody(for: m)
        let styled = a.runs.filter { $0.isStyledSpan }
        XCTAssertEqual(styled.count, 1)
        let want = Range(m.content.range(of: "@Bo")!, in: a)!
        XCTAssertEqual(styled[0].range, want)
    }

    /// Ticks are markup: stripped from display, mono on the inner text.
    func testAttributedBodyMonoBacktick() {
        let m = ChatMessage(id: "m", sender: "A", timestamp: "t", content: "run `go build` now")
        let a = MessageRender.attributedBody(for: m)
        XCTAssertEqual(String(a.characters), "run go build now")
        let mono = a.runs.filter { $0.isStyledSpan }
        XCTAssertEqual(mono.count, 1)
        let want = Range("run go build now".range(of: "go build")!, in: a)!
        XCTAssertEqual(mono[0].range, want)
        XCTAssertEqual(mono[0].codeRole, .inline)
    }

    /// stripBackticks: valid spans lose ticks; strays stay literal.
    func testStripBackticks() {
        let two = MessageRender.stripBackticks("run `a b` then `c` end")
        XCTAssertEqual(two.clean, "run a b then c end")
        XCTAssertEqual(two.spans.count, 2)
        XCTAssertEqual(String(two.clean[two.spans[0]]), "a b")
        XCTAssertEqual(String(two.clean[two.spans[1]]), "c")
        // Unbalanced / empty / newline ticks are user text, kept.
        XCTAssertEqual(MessageRender.stripBackticks("oops `x end").clean, "oops `x end")
        XCTAssertEqual(MessageRender.stripBackticks("a `` b").clean, "a `` b")
        XCTAssertEqual(MessageRender.stripBackticks("a `x\ny` b").clean, "a `x\ny` b")
    }

    func testAttributedBodyLink() {
        let m = ChatMessage(id: "m", sender: "A", timestamp: "t", content: "see https://example.com/x now")
        let a = MessageRender.attributedBody(for: m)
        let linked = a.runs.filter { $0.link != nil }
        XCTAssertEqual(linked.count, 1)
        XCTAssertEqual(linked[0].link?.absoluteString, "https://example.com/x")
    }

    // MARK: - Day sections

    func testDaySectionsSplit() {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        let now = Date()
        let iso: (Int) -> String = { d in
            f.string(from: Calendar.current.date(byAdding: .day, value: d, to: now)!)
        }
        let msgs = [
            ChatMessage(id: "a", sender: "A", timestamp: iso(-1), content: "y"),
            ChatMessage(id: "b", sender: "A", timestamp: iso(-1), content: "y2"),
            ChatMessage(id: "c", sender: "A", timestamp: iso(0), content: "t"),
        ]
        let secs = MessageRender.daySections(msgs)
        XCTAssertEqual(secs.count, 2)
        XCTAssertEqual(secs[0].messages.map(\.id), ["a", "b"])
        XCTAssertEqual(secs[0].label, "Yesterday")
        XCTAssertEqual(secs[1].label, "Today")
    }

    func testDayLabelGarbage() {
        XCTAssertEqual(MessageRender.dayLabel(""), "Unknown date")
        XCTAssertEqual(MessageRender.dayLabel("not-a-date"), "not-a-date")
    }

    // MARK: - Store: prepend / edited / failed

    func testPrependDedupes() {
        let list = [ChatMessage(id: "m2", sender: "A", timestamp: "t", content: "new")]
        let older = [
            ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "old"),
            ChatMessage(id: "m2", sender: "A", timestamp: "t", content: "STALE"),
        ]
        let out = ConversationStore.prepend(older, to: list)
        XCTAssertEqual(out.map(\.id), ["m1", "m2"])
        XCTAssertEqual(out[1].content, "new") // existing wins
    }

    func testUpsertMarksEditedOnlyOnChange() {
        let list = [ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "hi")]
        let same = ConversationStore.upsert(
            ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "hi"), into: list)
        XCTAssertFalse(same[0].edited)
        let changed = ConversationStore.upsert(
            ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "EDIT"), into: list)
        XCTAssertTrue(changed[0].edited)
    }

    func testIngestEditedMarksBubble() {
        let store = ConversationStore()
        store.ingest(ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "hi"))
        XCTAssertFalse(store.messages[0].edited)
        store.ingestEdited(id: "m1", content: "EDIT")
        XCTAssertTrue(store.messages[0].edited)
        // Same-content edit event: no marker.
        store.ingestEdited(id: "m1", content: "EDIT")
        XCTAssertEqual(store.messages[0].content, "EDIT")
    }

    func testFailedAndRetry() {
        let store = ConversationStore.demoRich()
        XCTAssertTrue(store.failedIDs.contains("rich-fail"))
        // Unknown id: no-op.
        XCTAssertNil(store.retry(id: "nope"))
        // Demo retry re-sends locally, clears flag.
        let text = store.retry(id: "rich-fail")
        XCTAssertEqual(text, "Sending the final deck to the client now.")
        XCTAssertFalse(store.failedIDs.contains("rich-fail"))
        XCTAssertEqual(store.messages.last?.content, text)
    }

    func testDemoRichStates() {
        let store = ConversationStore.demoRich()
        XCTAssertEqual(MessageRender.daySections(store.messages).count, 2)
        XCTAssertTrue(store.messages.contains { $0.edited })
        XCTAssertTrue(store.messages.contains { $0.raw?.contains("<at") ?? false })
        XCTAssertTrue(store.messages.contains { $0.raw?.contains("<pre>") ?? false })
        XCTAssertTrue(store.messages.contains { $0.content.contains("https://") })
    }

    func testCanLoadMoreGating() {
        let store = ConversationStore()
        XCTAssertFalse(store.canLoadMore) // no token yet
        XCTAssertFalse(ConversationStore.demo().canLoadMore)
        XCTAssertFalse(ConversationStore.demoRich().canLoadMore)
    }

    // MARK: - Wire decode

    func testMessagesResponseDecodesTokenAndRaw() throws {
        let json = """
        {"ok":true,"chat_id":"c","page_token":"https://h/x",
         "messages":[{"id":"m","sender":"A","timestamp":"t",
                      "content":"hi","raw":"<p>hi</p>"}]}
        """
        let r = try JSONDecoder().decode(MessagesResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.page_token, "https://h/x")
        XCTAssertEqual(r.messages[0].raw, "<p>hi</p>")
        XCTAssertFalse(r.messages[0].edited)
    }

    func testMessagesResponseOldCoreWithoutToken() throws {
        let json = """
        {"ok":true,"messages":[{"id":"m","sender":"A","timestamp":"t","content":"hi"}]}
        """
        let r = try JSONDecoder().decode(MessagesResponse.self, from: Data(json.utf8))
        XCTAssertNil(r.page_token)
        XCTAssertNil(r.messages[0].raw)
    }

    /// Live FFI: bad page token rejected before network, Swift sees error.
    func testLiveFFIBadPageTokenThrows() {
        XCTAssertThrowsError(try RustCore.messagesPage(chatID: "19:x", pageToken: "junk"))
    }
}
