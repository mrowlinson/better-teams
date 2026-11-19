// LoopComponentTests.swift — Loop mining, gate, send route, shapes.
//
// Covers: the 11-kind catalog, mining fluidEmbedCard/fluid cards
// from `cards` JSON, the live gate default, the loop send route +
// optimistic bubble, the placeholder exemption, and the pure
// core shapes call (offline).
import XCTest

@testable import OstMacCore

final class LoopComponentTests: XCTestCase {
    // MARK: - catalog

    func testCatalogHasElevenKindsWithUniqueIDs() {
        XCTAssertEqual(LoopComponent.kinds.count, 11)
        let ids = LoopComponent.kinds.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "kind ids unique")
        for k in LoopComponent.kinds {
            XCTAssertFalse(k.displayName.isEmpty, "\(k.id)")
            XCTAssertFalse(k.symbol.isEmpty, "\(k.id)")
        }
    }

    func testKnownKindIDs() {
        // Mined composeEnabledComponents (reloop/REPORT.md §2.8).
        let ids = Set(LoopComponent.kinds.map(\.id))
        for want in ["bulletedList", "checklist", "FFX-KanbanBoard", "numberedList",
                     "paragraph", "FFX-ProgressTracker", "questionAnswer", "FFX-RetroBoard",
                     "table", "votingTable", "actionItems"] {
            XCTAssertTrue(ids.contains(want), "missing kind \(want)")
        }
    }

    // MARK: - mining

    static let embedCards = """
    [{"contentType":"application/vnd.microsoft.card.fluidEmbedCard",\
    "content":{"componentUrl":"https://t-my.sharepoint.com/x?nav=abc"}}]
    """

    static let mixedCards = """
    [{"contentType":"application/vnd.microsoft.card.fluidEmbedCard",\
    "content":{"componentUrl":"E"}},\
    {"contentType":"application/vnd.microsoft.card.fluid",\
    "content":{"componentUrl":"C"}},\
    {"contentType":"application/vnd.microsoft.card.adaptive","content":{}},\
    {"contentType":"application/vnd.microsoft.card.fluidEmbedCard","content":{}}]
    """

    func testMineEmbedAndCollaborateOnly() {
        let found = LoopComponent.mine(fromCards: Self.mixedCards)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found[0], LoopEmbed(componentURL: "E", mode: .embed))
        XCTAssertEqual(found[1], LoopEmbed(componentURL: "C", mode: .collaborate))
        XCTAssertEqual(LoopComponent.first(fromCards: Self.mixedCards)?.componentURL, "E")
    }

    func testMineRejectsNonLoop() {
        XCTAssertTrue(LoopComponent.mine(fromCards: nil).isEmpty)
        XCTAssertTrue(LoopComponent.mine(fromCards: "").isEmpty)
        XCTAssertTrue(LoopComponent.mine(fromCards: "not json").isEmpty)
        XCTAssertTrue(LoopComponent.mine(fromCards: "[]").isEmpty)
        XCTAssertNil(LoopComponent.first(fromCards: "[]"))
    }

    func testCardsJSONRoundTrips() {
        let cards = LoopComponent.cardsJSON(componentURL: "https://t/x")
        let found = LoopComponent.mine(fromCards: cards)
        XCTAssertEqual(found, [LoopEmbed(componentURL: "https://t/x", mode: .embed)])
    }

    func testReadCoordsParsesNav() {
        let payload = "s=%2Fpersonal%2Fu&d=DRIVE&f=ITEM&c=%40fluidx%2Floop-page-container&fluid=1&a=Teams&p=%40fluidx%2Floop-page-container"
        let nav = Data(payload.utf8).base64EncodedString()
        let url = "https://t-my.sharepoint.com/x?nav=\(nav)"
        let coords = LoopComponent.readCoords(componentURL: url)
        XCTAssertEqual(coords?.host, "t-my.sharepoint.com")
        XCTAssertEqual(coords?.drive, "DRIVE")
        XCTAssertEqual(coords?.item, "ITEM")
        XCTAssertNil(LoopComponent.readCoords(componentURL: "https://t/x"))
        XCTAssertNil(LoopComponent.readCoords(componentURL: "not a url"))
    }

    // MARK: - gate

    func testGateDefaultsDisabledWithReason() {
        let saved = LoopGate.probe
        defer { LoopGate.probe = saved }
        LoopGate.probe = { .disabled(reason: LoopGate.defaultReason) }
        XCTAssertFalse(LoopGate.isLive)
        guard case .disabled(let reason) = LoopGate.state else {
            return XCTFail("expected disabled gate")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testGateReadyFlipsLive() {
        let saved = LoopGate.probe
        defer { LoopGate.probe = saved }
        LoopGate.probe = { .ready }
        XCTAssertTrue(LoopGate.isLive)
    }

    // MARK: - model + placeholder

    func testMessageDecodesCards() throws {
        let json = """
        {"id":"m1","sender":"A","timestamp":"t","content":"hi","cards":\(Self.jsonEscape(Self.embedCards))}
        """
        let m = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertEqual(m.loopCards, Self.embedCards)
        let bare = try JSONDecoder().decode(
            ChatMessage.self,
            from: Data(#"{"id":"m2","sender":"A","timestamp":"t","content":"hi"}"#.utf8))
        XCTAssertNil(bare.loopCards)
    }

    func testLoopMessageSkipsPlaceholder() {
        let m = ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "",
                            isOwn: false, loopCards: Self.embedCards)
        XCTAssertFalse(MessageRender.showsPlaceholder(for: m))
    }

    // MARK: - store send

    @MainActor
    func testSendLoopPostsLoopRouteAndSettles() async {
        var posted: [OutgoingSend] = []
        let s = ConversationStore()
        s.attachLiveForTesting(chatID: "19:chat@thread.v2", ownName: "Sam")
        s.sendTransport = SendTransport(
            post: { r in posted.append(r); return "S1" },
            find: { _, _ in nil })
        s.sendLoop(componentURL: "https://t/x?nav=abc", text: "see this")
        XCTAssertEqual(s.messages.count, 1)
        // The optimistic bubble already mines as loop (renders now).
        let bubble = s.messages[0]
        XCTAssertEqual(
            LoopComponent.first(fromCards: bubble.loopCards)?.componentURL, "https://t/x?nav=abc")
        await TestWait.until { posted.count == 1 }
        XCTAssertEqual(posted.count, 1)
        guard case .loopComponent(let url, let text) = posted[0].route else {
            return XCTFail("expected loop route, got \(posted[0].route)")
        }
        XCTAssertEqual(url, "https://t/x?nav=abc")
        XCTAssertEqual(text, "see this")
        await TestWait.until { !s.messages[0].id.hasPrefix("pending-") }
        XCTAssertEqual(s.messages.map(\.id), ["S1"])
    }

    @MainActor
    func testSendLoopEmptyURLSendsNothing() {
        let s = ConversationStore()
        s.attachLiveForTesting(chatID: "19:chat@thread.v2", ownName: "Sam")
        var posts = 0
        s.sendTransport = SendTransport(
            post: { _ in posts += 1; return "S1" },
            find: { _, _ in nil })
        s.sendLoop(componentURL: "  ", text: "x")
        XCTAssertTrue(s.messages.isEmpty)
        XCTAssertEqual(posts, 0)
    }

    // MARK: - shapes (pure core, offline)

    func testLoopShapesPinsE1Request() throws {
        let r = try RustCore.loopShapes(componentURL: "https://t/x?nav=abc", text: "hi")
        XCTAssertTrue(r.ok)
        let cards = try XCTUnwrap(r.cards)
        XCTAssertTrue(cards.contains("fluidEmbedCard"))
        let raw = try XCTUnwrap(r.body_string)
        let body = try JSONSerialization.jsonObject(with: raw.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(body["messagetype"] as? String, "RichText/Html")
        XCTAssertEqual(body["cards"] as? String, cards)
    }

    /// Quote one JSON string for embedding in a test payload.
    private static func jsonEscape(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [])
        var list = String(data: data, encoding: .utf8)!
        list.removeFirst()
        list.removeLast()
        return list
    }
}
