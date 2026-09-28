// CardParseMemoTests.swift — om-perf-swift-render: perf guards.
// Counts and caps only, never timings: card/action/refs memoization
// hit/miss counts, cache-cap bounds, and overload equivalence.
import XCTest

@testable import OstMacCore

@MainActor
final class CardParseMemoTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AdaptiveCard.resetCardsCache()
        CardActions.resetActionsCache()
        InlineDocs.resetRefsCache()
    }

    override func tearDown() {
        AdaptiveCard.resetCardsCache()
        CardActions.resetActionsCache()
        InlineDocs.resetRefsCache()
        super.tearDown()
    }

    static let card = """
        {"type":"AdaptiveCard","version":"1.4","body":[\
        {"type":"TextBlock","text":"Build green","size":"Large"},\
        {"type":"FactSet","facts":[{"title":"Branch","value":"main"}]}],\
        "actions":[{"type":"Action.OpenUrl","title":"View","url":"https://example.com/b/7"}]}
        """

    static let submitCard = """
        {"type":"AdaptiveCard","version":"1.0","body":[\
        {"type":"TextBlock","text":"Approve?"}],\
        "actions":[{"type":"Action.Submit","title":"Yes"}]}
        """

    static let attachRaw = """
        <p>see attached</p><attachment id="a1"></attachment><attachment id="a2"></attachment>
        """

    private func file(_ id: String, attachmentID: String?) -> SharedFile {
        SharedFile(id: id, name: "\(id).pdf", attachment_id: attachmentID)
    }

    // MARK: - Card memo

    func testCardsMemoizedPerRaw() {
        let a = AdaptiveCard.cards(fromRaw: Self.card)
        let b = AdaptiveCard.cards(fromRaw: Self.card)
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(AdaptiveCard.cardsComputes, 1)
    }

    func testCardsMissOnNewRaw() {
        _ = AdaptiveCard.cards(fromRaw: Self.card)
        _ = AdaptiveCard.cards(fromRaw: Self.submitCard)
        XCTAssertEqual(AdaptiveCard.cardsComputes, 2)
    }

    func testCardsNilAndProseAreFree() {
        XCTAssertEqual(AdaptiveCard.cards(fromRaw: nil), [])
        XCTAssertEqual(AdaptiveCard.cards(fromRaw: "<p>hi</p>"), [])
        XCTAssertEqual(AdaptiveCard.cards(fromRaw: "<p>hi</p>"), [])
        // nil short-circuits; prose parses (miss) once, then hits.
        XCTAssertEqual(AdaptiveCard.cardsComputes, 1)
    }

    func testCardsCapBounded() {
        for i in 0 ..< (AdaptiveCard.maxCardCacheEntries + 50) {
            _ = AdaptiveCard.cards(fromRaw: "{\"n\":\(i)}")
        }
        // Overflow drops everything: a re-parse of the first raw misses.
        _ = AdaptiveCard.cards(fromRaw: "{\"n\":0}")
        XCTAssertEqual(
            AdaptiveCard.cardsComputes, AdaptiveCard.maxCardCacheEntries + 51)
    }

    // MARK: - Card-action memo

    func testActionsMemoizedPerRaw() {
        let a = CardActions.actions(fromRaw: Self.card)
        let b = CardActions.actions(fromRaw: Self.card)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.openURLs.count, 1)
        XCTAssertEqual(CardActions.actionsComputes, 1)
    }

    func testActionsNilIsFree() {
        XCTAssertEqual(CardActions.actions(fromRaw: nil), CardActionSet.empty)
        XCTAssertEqual(CardActions.actionsComputes, 0)
    }

    // MARK: - Refs memo + indexed resolve

    func testRefsMemoizedPerRaw() {
        let a = InlineDocs.refs(fromRaw: Self.attachRaw)
        let b = InlineDocs.refs(fromRaw: Self.attachRaw)
        XCTAssertEqual(a, ["a1", "a2"])
        XCTAssertEqual(a, b)
        XCTAssertEqual(InlineDocs.refsComputes, 1)
    }

    func testRefsNilAndEmptyAreFree() {
        XCTAssertEqual(InlineDocs.refs(fromRaw: nil), [])
        XCTAssertEqual(InlineDocs.refs(fromRaw: ""), [])
        XCTAssertEqual(InlineDocs.refsComputes, 0)
    }

    func testIndexedResolveMatchesLinear() {
        let files = [
            file("f1", attachmentID: "a1"),
            file("f2", attachmentID: nil),
            file("f3", attachmentID: "a1"),
            file("f4", attachmentID: "a2"),
        ]
        let refs = ["a1", "missing", "a2", "a1"]
        XCTAssertEqual(
            InlineDocs.resolve(refs: refs, files: files),
            InlineDocs.resolve(
                refs: refs,
                filesByAttachmentID: InlineDocs.index(files: files)))
        // First file wins per id (linear first(where:) parity).
        XCTAssertEqual(
            InlineDocs.resolve(refs: ["a1"], files: files).map(\.id), ["f1"])
        // Cap honored on the indexed path too.
        let many = (0 ..< 30).map { "a\($0)" }
        XCTAssertEqual(
            InlineDocs.resolve(refs: many, files: files).count,
            min(InlineDocs.maxRows, 2))
    }

    func testDocsSkipsIndexWithoutRefs() {
        let m = ChatMessage(
            id: "d1", sender: "Tom", timestamp: "2026-09-23T08:04:00Z",
            content: "plain", raw: "<p>plain</p>")
        XCTAssertEqual(InlineDocs.docs(for: m, files: [file("f1", attachmentID: "a1")]), [])
    }

    // MARK: - Gating overload equivalence

    func testFallbackGatingOverloadMatchesMessageForm() {
        let raws: [String?] = [
            nil, "<p>plain</p>", Self.card, Self.submitCard,
            "<attachment><a href=\"https://example.com/s\">T</a></attachment>",
        ]
        for (i, raw) in raws.enumerated() {
            let m = ChatMessage(
                id: "g\(i)", sender: "B", timestamp: "2026-09-23T08:02:00Z",
                content: raw ?? "", raw: raw)
            let posts = MessageRender.botPosts(fromRaw: raw ?? "")
            let cards = MessageBubbleState.cards(for: m)
            XCTAssertEqual(
                MessageBubbleState.shouldShowFallbackRows(posts: posts, cards: cards),
                MessageBubbleState.shouldShowFallbackRows(for: m),
                "raw index \(i)")
        }
    }

    func testSingleCardParsePerBubbleEval() {
        let m = ChatMessage(
            id: "e1", sender: "Card Bot", timestamp: "2026-09-23T08:02:00Z",
            content: "", raw: Self.card)
        // The bubble's old sequence parsed cards 3x (cards + gating +
        // placeholder); the new path parses once, then hits cache.
        for _ in 0 ..< 5 {
            let cards = MessageBubbleState.cards(for: m)
            let posts = MessageRender.botPosts(fromRaw: m.raw ?? m.content)
            _ = MessageBubbleState.shouldShowFallbackRows(posts: posts, cards: cards)
            _ = MessageRender.showsPlaceholder(for: m)
        }
        XCTAssertEqual(AdaptiveCard.cardsComputes, 1)
    }
}
