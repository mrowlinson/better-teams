// BotPostsTests.swift — om-botposts lane: attachment/card mining,
// bubble text + placeholder rules, demo thread shape, copy text.
import XCTest

@testable import OstMacCore

@MainActor
final class BotPostsTests: XCTestCase {
    private func msg(
        id: String = "m1", sender: String = "RSS Bot",
        content: String = "", raw: String? = nil,
        replyTo: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id, sender: sender, timestamp: "2026-09-23T08:02:00Z",
            content: content, raw: raw, reply_to: replyTo)
    }

    // MARK: - Attachment mining

    func testAttachmentRowsCarryTitleAndLink() {
        let posts = MessageRender.botPosts(fromRaw:
            #"<p>digest:</p><attachment><p><a href="https://h/a">Post A</a></p></attachment>"#
                + #"<attachment><p><a href="https://h/b">Post B</a></p></attachment>"#)
        XCTAssertEqual(posts, [
            MessageRender.BotPost(title: "Post A", url: "https://h/a"),
            MessageRender.BotPost(title: "Post B", url: "https://h/b"),
        ])
    }

    func testAttachmentMiningIsCaseInsensitiveAndTolerant() {
        // Uppercase tags, single-quoted href, bare anchor (no text).
        let posts = MessageRender.botPosts(fromRaw:
            #"<ATTACHMENT><P><A HREF='https://h/u'>Titled</A></P></ATTACHMENT>"#
                + #"<attachment><a href="https://h/bare"></a></attachment>"#)
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].title, "Titled")
        XCTAssertEqual(posts[0].url, "https://h/u")
        // Bare anchor falls back to the URL itself as the title.
        XCTAssertEqual(posts[1].title, "https://h/bare")
        XCTAssertEqual(posts[1].url, "https://h/bare")
    }

    func testLinkLessAttachmentFallsBackToText() {
        let posts = MessageRender.botPosts(fromRaw:
            "<attachment><p>Standup notes are up</p></attachment>")
        XCTAssertEqual(posts, [MessageRender.BotPost(title: "Standup notes are up")])
    }

    func testEmptyAttachmentYieldsNoRows() {
        XCTAssertEqual(
            MessageRender.botPosts(fromRaw: #"<attachment id="abc"></attachment>"#), [])
        XCTAssertEqual(MessageRender.botPosts(fromRaw: nil), [])
        XCTAssertEqual(MessageRender.botPosts(fromRaw: "  "), [])
        // Plain prose and image-only payloads are not bot posts.
        XCTAssertEqual(MessageRender.botPosts(fromRaw: "<p>hi</p>"), [])
        XCTAssertEqual(
            MessageRender.botPosts(fromRaw: #"<p><img src="demo://x"></p>"#), [])
    }

    func testAnchorMinerSkipsAttachmentAndMentionTags() {
        // `<a` boundary: attachment/at opens never parse as anchors.
        let links = MessageRender.links(in:
            #"<attachment id="x"><at id="8:t">Tom</at><a href="https://h/ok">go</a></attachment>"#)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].text, "go")
        XCTAssertEqual(links[0].href, "https://h/ok")
    }

    // MARK: - Card JSON mining

    func testCardJSONYieldsTitleAndKeyedURL() {
        // The @context URL must NOT win over the action target.
        let json = #"{"@type":"MessageCard","@context":"https://schema.org/extensions","title":"Build green","potentialAction":[{"@type":"OpenUri","targets":[{"os":"default","uri":"https://h/builds/7"}]}]}"#
        XCTAssertTrue(MessageRender.isCardPayload(json))
        XCTAssertEqual(
            MessageRender.botPosts(fromRaw: json),
            [MessageRender.BotPost(title: "Build green", url: "https://h/builds/7")])
    }

    func testCardJSONWithoutTitleOrURLYieldsNoRows() {
        let json = #"{"@type":"MessageCard","count":3,"flags":[true]}"#
        XCTAssertTrue(MessageRender.isCardPayload(json))
        XCTAssertEqual(MessageRender.botPosts(fromRaw: json), [])
        // Malformed JSON is not a payload and yields no rows.
        XCTAssertFalse(MessageRender.isCardPayload("{oops"))
        XCTAssertEqual(MessageRender.botPosts(fromRaw: "{oops"), [])
        // Plain JSON pasted by a user is not a card.
        XCTAssertFalse(MessageRender.isCardPayload(#"{"a": 1}"#))
    }

    // MARK: - Bubble text + placeholder

    func testBubbleTextDropsAttachmentProseKeepsOutside() {
        let m = msg(
            content: "digest:Post A",
            raw: #"<p>digest:</p><attachment><p><a href="https://h/a">Post A</a></p></attachment>"#)
        XCTAssertEqual(MessageRender.bubbleText(for: m), "digest:")
        XCTAssertFalse(MessageRender.showsPlaceholder(for: m))
    }

    func testBubbleTextSuppressesCardJSON() {
        let json = #"{"@type":"MessageCard","title":"T","uri":"https://h/t"}"#
        XCTAssertEqual(MessageRender.bubbleText(for: msg(content: json, raw: json)), "")
        XCTAssertFalse(MessageRender.showsPlaceholder(
            for: msg(content: json, raw: json)))
    }

    func testPlaceholderForUnparseablePayloadOnly() {
        // Server-held attachment: placeholder.
        XCTAssertTrue(MessageRender.showsPlaceholder(for: msg(
            content: "", raw: #"<attachment id="abc"></attachment>"#)))
        // Unparseable marked JSON: placeholder (no rows, text suppressed).
        XCTAssertTrue(MessageRender.showsPlaceholder(for: msg(
            content: #"{"@type":"MessageCard","n":1}"#,
            raw: #"{"@type":"MessageCard","n":1}"#)))
        // Plain text, image-only, and rows never placeholder.
        XCTAssertFalse(MessageRender.showsPlaceholder(for: msg(content: "hi")))
        XCTAssertFalse(MessageRender.showsPlaceholder(for: msg(
            content: "", raw: #"<p><img src="demo://x"></p>"#)))
        XCTAssertFalse(MessageRender.showsPlaceholder(for: msg(
            content: "d", raw: #"<attachment><a href="https://h/a">A</a></attachment>"#)))
        // Truly empty synthetic bubbles stay blank (no payload).
        XCTAssertFalse(MessageRender.showsPlaceholder(for: msg()))
    }

    func testRepliesKeepRenderText() {
        // A reply carrying attachments still renders its full content;
        // the quote block owns attribution.
        let m = msg(
            content: "answer", raw: #"<attachment><a href="https://h/a">A</a></attachment>"#,
            replyTo: "m0")
        XCTAssertEqual(MessageRender.bubbleText(for: m), "answer")
    }

    // MARK: - Title-dup dedupe (om-lt3-titlededupe)

    func testBubbleTextDedupesTitleDup() {
        // Live RSS Media_Card: body prose repeats the attachment title
        // ("Digest"/"Digest" glued into content by core strip). The row
        // carries the title, so the bubble text renders nothing (once).
        let m = msg(
            id: "td-1",
            content: "DigestDigest",
            raw: #"<p>Digest</p><attachment><p><a href="https://h/d">Digest</a></p></attachment>"#)
        XCTAssertEqual(
            MessageRender.botPosts(fromRaw: m.raw),
            [MessageRender.BotPost(title: "Digest", url: "https://h/d")])
        XCTAssertEqual(MessageRender.bubbleText(for: m), "")
        XCTAssertFalse(MessageRender.showsPlaceholder(for: m))
    }

    func testTitleDedupeIgnoresCaseAndWhitespace() {
        let m = msg(
            id: "td-2",
            content: "digest Digest",
            raw: "<p>  digest </p>" + #"<attachment><a href="https://h/d">Digest</a></attachment>"#)
        XCTAssertEqual(MessageRender.bubbleText(for: m), "")
    }

    func testTitleDedupeKeepsDistinctProse() {
        // Equality only: prose merely containing the title still shows.
        let m = msg(
            id: "td-3",
            content: "Today's Digest is outDigest",
            raw: "<p>Today's Digest is out</p>" + #"<attachment><a href="https://h/d">Digest</a></attachment>"#)
        XCTAssertEqual(MessageRender.bubbleText(for: m), "Today's Digest is out")
    }

    // MARK: - Rows view + copy text

    func testCopyTextAppendsRowLines() {
        let m = msg(
            content: "Deploy finished: release 42 notes",
            raw: #"<p>Deploy finished: </p><attachment><a href="https://h/d/42">release 42 notes</a></attachment>"#)
        XCTAssertEqual(
            MessageActions.copyText(for: m),
            "Deploy finished:\nrelease 42 notes — https://h/d/42")
        // Plain messages are unchanged (no rows appended).
        XCTAssertEqual(
            MessageActions.copyText(for: msg(content: "hi")),
            "hi")
    }

    // MARK: - Demo thread

    func testBotPostsThreadShape() {
        let msgs = DemoData.botPostsMessages()
        XCTAssertEqual(msgs.count, 4)
        // Digest: outside prose + two rows, no placeholder.
        XCTAssertEqual(MessageRender.bubbleText(for: msgs[0]), "Tech news digest — 2 new stories:")
        XCTAssertEqual(
            MessageRender.botPosts(fromRaw: msgs[0].raw).map(\.title),
            ["Accessible color palettes, explained", "Faster builds with smarter caching"])
        XCTAssertFalse(MessageRender.showsPlaceholder(for: msgs[0]))
        // Card: row only, JSON suppressed.
        XCTAssertEqual(MessageRender.bubbleText(for: msgs[1]), "")
        XCTAssertEqual(
            MessageRender.botPosts(fromRaw: msgs[1].raw),
            [MessageRender.BotPost(title: "Build green", url: "https://example.com/builds/7")])
        // Unparseable: placeholder.
        XCTAssertTrue(MessageRender.showsPlaceholder(for: msgs[2]))
        // Mixed: prose + one row.
        XCTAssertEqual(MessageRender.bubbleText(for: msgs[3]), "Deploy finished:")
        XCTAssertEqual(MessageRender.botPosts(fromRaw: msgs[3].raw).count, 1)
        // Every demo bubble renders something (never blank).
        for m in msgs {
            let textVisible = !MessageRender.bubbleText(for: m).isEmpty
            let rowsVisible = !MessageRender.botPosts(fromRaw: m.raw ?? m.content).isEmpty
            let imagesVisible = !MessageRender.images(fromRaw: m.raw).isEmpty
            XCTAssertTrue(
                textVisible || rowsVisible || imagesVisible
                    || MessageRender.showsPlaceholder(for: m),
                "blank bubble: \(m.id)")
        }
        // Sidebar row tracks the thread tail.
        let row = DemoData.botPostsChat()
        XCTAssertEqual(row.chatId, DemoData.botpostsID)
        XCTAssertEqual(row.last_message_preview, msgs.last?.content)
        XCTAssertEqual(DemoData.messages(for: DemoData.botpostsID).count, 4)
    }
}
