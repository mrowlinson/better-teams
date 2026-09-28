// AdaptiveCardsTests.swift — om-jc-cards lane: Adaptive Card model,
// envelope mining, fallback gating, bubble wiring, copy text.
import XCTest

@testable import OstMacCore

@MainActor
final class AdaptiveCardsTests: XCTestCase {
    private func msg(
        id: String = "m1", sender: String = "Card Bot",
        content: String = "", raw: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id, sender: sender, timestamp: "2026-09-23T08:02:00Z",
            content: content, raw: raw)
    }

    // MARK: - Fixtures (real payload shapes)

    /// Bare Adaptive Card JSON (Bot Framework / webhook shape).
    static let bareCard = """
        {"type":"AdaptiveCard","$schema":"http://adaptivecards.io/schemas/adaptive-card.json",\
        "version":"1.4","body":[\
        {"type":"TextBlock","text":"Build green","size":"Large","weight":"Bolder"},\
        {"type":"TextBlock","text":"main passed all checks","isSubtle":true,"wrap":true},\
        {"type":"FactSet","facts":[\
        {"title":"Branch","value":"main"},\
        {"title":"Run","value":"#7"}]},\
        {"type":"Image","url":"https://example.com/badge.png","altText":"build badge"}\
        ],"actions":[{"type":"Action.OpenUrl","title":"View run","url":"https://example.com/builds/7"}]}
        """

    /// Teams attachment envelope: contentType + content (Graph
    /// chatMessage attachments[] element shape).
    static let envelopeCard = """
        {"id":"att-1","contentType":"application/vnd.microsoft.card.adaptive",\
        "contentUrl":null,"content":\(bareCard)}
        """

    /// Full message envelope carrying attachments[] (Graph shape).
    static let messageEnvelope = """
        {"id":"msg-9","body":{"contentType":"html","content":""},\
        "attachments":[\(envelopeCard),\
        {"id":"att-2","contentType":"application/vnd.microsoft.card.adaptive",\
        "content":{"type":"AdaptiveCard","version":"1.2",\
        "body":[{"type":"TextBlock","text":"Second card"}]}}]}
        """

    /// ColumnSet + Container nesting (shallow: one level).
    static let nestedCard = """
        {"type":"AdaptiveCard","version":"1.3","body":[\
        {"type":"Container","items":[\
        {"type":"TextBlock","text":"Inside container","weight":"Bolder"}]},\
        {"type":"ColumnSet","columns":[\
        {"type":"Column","items":[{"type":"TextBlock","text":"Left col"}]},\
        {"type":"Column","items":[{"type":"TextBlock","text":"Right col"},\
        {"type":"Image","url":"https://example.com/r.png"}]}]}]}
        """

    /// Unsupported surface: Submit + inputs + Execute stay fallback-only.
    static let submitCard = """
        {"type":"AdaptiveCard","version":"1.4","body":[\
        {"type":"TextBlock","text":"Pick a slot"},\
        {"type":"Input.ChoiceSet","id":"slot","choices":[{"title":"AM","value":"am"}]}],\
        "actions":[{"type":"Action.Submit","title":"Book","data":{"x":1}}]}
        """

    // MARK: - Envelope mining

    func testBareCardParses() {
        let cards = AdaptiveCard.cards(fromRaw: Self.bareCard)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].body.count, 4)
        XCTAssertEqual(cards[0].actions.count, 1)
        XCTAssertEqual(cards[0].actions[0].title, "View run")
        XCTAssertEqual(cards[0].actions[0].url, "https://example.com/builds/7")
        XCTAssertFalse(cards[0].needsFallback)
    }

    func testEnvelopeAndMessageShapesMineContent() {
        let one = AdaptiveCard.cards(fromRaw: Self.envelopeCard)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0].actions.count, 1)
        let two = AdaptiveCard.cards(fromRaw: Self.messageEnvelope)
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(two[1].body.count, 1)
    }

    func testElementKindsParse() {
        let cards = AdaptiveCard.cards(fromRaw: Self.bareCard)
        XCTAssertEqual(cards.count, 1)
        let body = cards[0].body
        guard case let .text(head) = body[0] else {
            return XCTFail("body[0] is \(body[0])")
        }
        XCTAssertEqual(head.text, "Build green")
        XCTAssertEqual(head.size, .large)
        XCTAssertEqual(head.weight, .bolder)
        guard case let .text(sub) = body[1] else {
            return XCTFail("body[1] is \(body[1])")
        }
        XCTAssertTrue(sub.isSubtle)
        guard case let .facts(facts) = body[2] else {
            return XCTFail("body[2] is \(body[2])")
        }
        XCTAssertEqual(facts, [
            AdaptiveCard.Fact(title: "Branch", value: "main"),
            AdaptiveCard.Fact(title: "Run", value: "#7"),
        ])
        guard case let .image(img) = body[3] else {
            return XCTFail("body[3] is \(body[3])")
        }
        XCTAssertEqual(img.url, "https://example.com/badge.png")
        XCTAssertEqual(img.altText, "build badge")
    }

    func testNestedContainersParseShallow() {
        let cards = AdaptiveCard.cards(fromRaw: Self.nestedCard)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].body.count, 2)
        guard case let .container(items) = cards[0].body[0] else {
            return XCTFail("body[0] is \(cards[0].body[0])")
        }
        XCTAssertEqual(items.count, 1)
        guard case let .columns(cols) = cards[0].body[1] else {
            return XCTFail("body[1] is \(cards[0].body[1])")
        }
        XCTAssertEqual(cols.count, 2)
        XCTAssertEqual(cols[0].count, 1)
        XCTAssertEqual(cols[1].count, 2)
        XCTAssertFalse(cards[0].needsFallback)
    }

    func testDeepNestingDropsPastOneLevel() {
        // Container-in-Container: the inner container's leaf survives
        // only as fallback signal, never as rendered depth.
        let json = """
            {"type":"AdaptiveCard","version":"1.4","body":[\
            {"type":"Container","items":[\
            {"type":"Container","items":[{"type":"TextBlock","text":"deep"}]}]}]}
            """
        let cards = AdaptiveCard.cards(fromRaw: json)
        XCTAssertEqual(cards.count, 1)
        guard case let .container(items) = cards[0].body[0] else {
            return XCTFail("body[0] is \(cards[0].body[0])")
        }
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - Actions: OpenUrl only

    func testNonHTTPOpenUrlDropped() {
        let json = """
            {"type":"AdaptiveCard","version":"1.2","body":[\
            {"type":"TextBlock","text":"Hi"}],\
            "actions":[{"type":"Action.OpenUrl","title":"Evil","url":"file:///etc/passwd"},\
            {"type":"Action.OpenUrl","title":"OK","url":"https://example.com/ok"}]}
            """
        let cards = AdaptiveCard.cards(fromRaw: json)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].actions.map(\.url), ["https://example.com/ok"])
        // A dropped unsafe URL is not fallback-worthy on its own.
        XCTAssertFalse(cards[0].needsFallback)
        XCTAssertNil(AdaptiveCard.linkTarget(for: "file:///etc/passwd"))
        XCTAssertNotNil(AdaptiveCard.linkTarget(for: "https://example.com/ok"))
    }

    func testSubmitInputsExecuteNeedFallback() {
        let cards = AdaptiveCard.cards(fromRaw: Self.submitCard)
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards[0].needsFallback)
        // Input leaf itself never renders.
        XCTAssertEqual(cards[0].body.count, 1)
        let exec = """
            {"type":"AdaptiveCard","version":"1.4",\
            "body":[{"type":"TextBlock","text":"T"}],\
            "actions":[{"type":"Action.Execute","title":"Go","verb":"go"}]}
            """
        XCTAssertTrue(AdaptiveCard.cards(fromRaw: exec)[0].needsFallback)
    }

    func testUnknownActionNeedsFallback() {
        let json = """
            {"type":"AdaptiveCard","version":"1.4",\
            "body":[{"type":"TextBlock","text":"T"}],\
            "actions":[{"type":"Action.ToggleVisibility","title":"T"}]}
            """
        XCTAssertTrue(AdaptiveCard.cards(fromRaw: json)[0].needsFallback)
    }

    // MARK: - Non-cards

    func testNonCardPayloadsYieldNoCards() {
        XCTAssertEqual(AdaptiveCard.cards(fromRaw: nil), [])
        XCTAssertEqual(AdaptiveCard.cards(fromRaw: "  "), [])
        XCTAssertEqual(AdaptiveCard.cards(fromRaw: "<p>hi</p>"), [])
        // MessageCard is not an Adaptive Card (stays on the row path).
        XCTAssertEqual(
            AdaptiveCard.cards(fromRaw: #"{"@type":"MessageCard","title":"T"}"#), [])
        // Plain user JSON is not a card.
        XCTAssertEqual(AdaptiveCard.cards(fromRaw: #"{"a": 1}"#), [])
        // Malformed JSON is not a card.
        XCTAssertEqual(AdaptiveCard.cards(fromRaw: "{oops"), [])
        // Envelope with a foreign content type is not a card.
        XCTAssertEqual(
            AdaptiveCard.cards(fromRaw: #"{"contentType":"text/plain","content":{}}"#), [])
    }

    func testEmptyCardYieldsNoCard() {
        // No renderable body/actions: not a card (placeholder owns it).
        XCTAssertEqual(
            AdaptiveCard.cards(fromRaw: #"{"type":"AdaptiveCard","version":"1.2"}"#), [])
    }

    // MARK: - Bubble wiring

    func testRenderedCardSuppressesFallbackRows() {
        // Pure OpenUrl card: card view owns the bubble, rows hidden.
        XCTAssertTrue(MessageBubbleState.shouldShowCards(for: msg(
            content: Self.bareCard, raw: Self.bareCard)))
        XCTAssertFalse(MessageBubbleState.shouldShowFallbackRows(for: msg(
            content: Self.bareCard, raw: Self.bareCard)))
        // Submit card: card view AND fallback rows coexist.
        XCTAssertTrue(MessageBubbleState.shouldShowCards(for: msg(
            content: Self.submitCard, raw: Self.submitCard)))
        XCTAssertTrue(MessageBubbleState.shouldShowFallbackRows(for: msg(
            content: Self.submitCard, raw: Self.submitCard)))
        // MessageCard: rows only, no card view.
        let mc = #"{"@type":"MessageCard","title":"T","uri":"https://h/t"}"#
        XCTAssertFalse(MessageBubbleState.shouldShowCards(for: msg(content: mc, raw: mc)))
        XCTAssertTrue(MessageBubbleState.shouldShowFallbackRows(for: msg(content: mc, raw: mc)))
    }

    func testCardCopyTextCarriesCardLines() {
        let text = MessageActions.copyText(for: msg(
            content: Self.bareCard, raw: Self.bareCard))
        XCTAssertTrue(text.contains("Build green"), text)
        XCTAssertTrue(text.contains("Branch — main"), text)
        XCTAssertTrue(text.contains("View run — https://example.com/builds/7"), text)
        // No raw JSON leaks into the copy.
        XCTAssertFalse(text.contains("AdaptiveCard"), text)
    }
}
