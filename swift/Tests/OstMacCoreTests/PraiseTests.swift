// PraiseTests.swift — praise badges: catalog, card mining, wire shape.
//
// Covers: the 10-badge catalog (stable wire tokens), mining a real
// Praise-shaped Adaptive Card envelope into a PraisePost, and the
// outgoing envelope/content shape the send path posts.
import XCTest

@testable import OstMacCore

final class PraiseTests: XCTestCase {
    // MARK: - catalog

    func testCatalogHasTenBadgesWithUniqueTokensAndSymbols() {
        XCTAssertEqual(PraiseBadge.allCases.count, 10)
        let tokens = PraiseBadge.allCases.map(\.wireToken)
        XCTAssertEqual(Set(tokens).count, tokens.count, "wire tokens unique")
        for b in PraiseBadge.allCases {
            XCTAssertFalse(b.displayName.isEmpty, "\(b)")
            XCTAssertFalse(b.symbol.isEmpty, "\(b)")
            XCTAssertFalse(b.wireToken.isEmpty, "\(b)")
        }
        XCTAssertEqual(Set(PraiseBadge.allCases.map(\.symbol)).count, 10, "glyphs unique")
    }

    func testWireTokenRoundTrip() {
        for b in PraiseBadge.allCases {
            XCTAssertEqual(PraiseBadge(wireToken: b.wireToken), b, "\(b.wireToken)")
        }
        XCTAssertNil(PraiseBadge(wireToken: "Nope"))
        XCTAssertNil(PraiseBadge(wireToken: ""))
    }

    func testKnownBadgeNames() {
        // Real Teams Praise badge names (compose picker parity).
        let names = Set(PraiseBadge.allCases.map(\.displayName))
        for want in ["Thank You", "Awesome", "Achiever", "Coach", "Creative",
                     "Kind Heart", "Leadership", "Problem Solver", "Team Player", "Courage"] {
            XCTAssertTrue(names.contains(want), "missing badge \(want)")
        }
    }

    // MARK: - mining

    /// Real Praise card shape (captured from a Teams client): an
    /// attachment envelope carrying an AdaptiveCard whose ColumnSet
    /// holds the badge Image (altText = badge) plus the
    /// "<sender> sent praise to" / recipient / note TextBlocks.
    static let realPraiseEnvelope = """
    {"attachments":[{"contentType":"application/vnd.microsoft.card.adaptive","content":{"type":"AdaptiveCard","version":"1.0","body":[{"type":"ColumnSet","spacing":"large","separator":true,"columns":[{"type":"Column","width":2.6,"items":[{"type":"Image","horizontalAlignment":"center","size":"auto","altText":"Courage","url":"https://example.invalid/badge.png"}]},{"type":"Column","width":6,"spacing":"medium","items":[{"type":"TextBlock","wrap":true,"size":"small","isSubtle":true,"text":"Matti Paukkonen sent praise to"},{"type":"TextBlock","wrap":true,"spacing":"small","weight":"bolder","size":"medium","text":"Jane Doe"},{"type":"TextBlock","spacing":"small","wrap":true,"text":"Great work on the launch!"}]}]}]}}]}
    """

    func testMineRealPraiseEnvelope() {
        let post = PraiseCard.mine(fromRaw: Self.realPraiseEnvelope)
        XCTAssertNotNil(post)
        XCTAssertEqual(post?.badge, .courage)
        XCTAssertEqual(post?.recipient, "Jane Doe")
        XCTAssertEqual(post?.note, "Great work on the launch!")
        XCTAssertEqual(post?.sender, "Matti Paukkonen")
    }

    func testMineRejectsNonPraiseCards() {
        XCTAssertNil(PraiseCard.mine(fromRaw: nil))
        XCTAssertNil(PraiseCard.mine(fromRaw: ""))
        XCTAssertNil(PraiseCard.mine(fromRaw: "hello"))
        // Generic adaptive card with no praise marker.
        XCTAssertNil(PraiseCard.mine(fromRaw: """
        {"type":"AdaptiveCard","version":"1.0","body":[{"type":"TextBlock","text":" пищевар"}]}
        """))
        // Praise marker but no recipient: still a praise post (best effort).
        let noRecipient = """
        {"attachments":[{"contentType":"application/vnd.microsoft.card.adaptive","content":{"type":"AdaptiveCard","version":"1.0","body":[{"type":"ColumnSet","columns":[{"type":"Column","items":[{"type":"TextBlock","text":"Sam sent praise to"}]}]}]}}]}
        """
        let post = PraiseCard.mine(fromRaw: noRecipient)
        XCTAssertNotNil(post)
        XCTAssertEqual(post?.sender, "Sam")
    }

    func testMineMatchesBadgeByImageAltText() {
        // Badge name carried by the badge Image altText (real layout),
        // not by a text line.
        let raw = """
        {"attachments":[{"contentType":"application/vnd.microsoft.card.adaptive","content":{"type":"AdaptiveCard","version":"1.0","body":[{"type":"ColumnSet","columns":[{"type":"Column","items":[{"type":"Image","altText":"Kind Heart","url":"https://example.invalid/x.png"}]},{"type":"Column","items":[{"type":"TextBlock","text":"A sent praise to"},{"type":"TextBlock","weight":"bolder","text":"B"},{"type":"TextBlock","text":"Quarterly hero"}]}]}]}}]}
        """
        XCTAssertEqual(PraiseCard.mine(fromRaw: raw)?.badge, .kindHeart)
    }

    // MARK: - outgoing shape

    func testOutgoingEnvelopeShape() {
        let id = "11111111-2222-3333-4444-555555555555"
        let env = PraiseCard.envelope(badge: .awesome, recipient: "Jane",
                                      note: "Nice work", sender: "Sam", attachmentID: id)
        XCTAssertEqual(env["contentType"] as? String, "html")
        XCTAssertEqual(env["content"] as? String, "<attachment id=\"\(id)\"></attachment>")
        let atts = env["attachments"] as? [String: Any]
        XCTAssertNotNil(atts)
        XCTAssertEqual(atts?["id"] as? String, id)
        XCTAssertEqual(atts?["contentType"] as? String, "application/vnd.microsoft.card.adaptive")
        let card = atts?["content"] as? [String: Any]
        XCTAssertEqual(card?["type"] as? String, "AdaptiveCard")
        // Round trip: the miner reads the envelope back.
        guard let data = try? JSONSerialization.data(withJSONObject: ["attachments": [atts as Any]]),
              let json = String(data: data, encoding: .utf8)
        else { return XCTFail("envelope not serializable") }
        let texts = PraiseCard.cardTexts(fromRaw: json)
        for want in ["Awesome", "Jane", "Nice work", "Sam sent praise to"] {
            XCTAssertTrue(texts.contains(want), "\(texts)")
        }
        let post = PraiseCard.mine(fromRaw: json)
        XCTAssertEqual(post?.badge, .awesome)
        XCTAssertEqual(post?.recipient, "Jane")
        XCTAssertEqual(post?.note, "Nice work")
        XCTAssertEqual(post?.sender, "Sam")
    }

    func testRecipientSuggestionPrefersOtherSpeaker() {
        let msgs = [
            ChatMessage(id: "1", sender: "Me", timestamp: "", content: "hi", isOwn: true),
            ChatMessage(id: "2", sender: "Jane Doe", timestamp: "", content: "hey", isOwn: false),
            ChatMessage(id: "3", sender: "Me", timestamp: "", content: "yo", isOwn: true),
        ]
        XCTAssertEqual(PraiseCard.suggestRecipient(messages: msgs, ownName: "Me"), "Jane Doe")
        XCTAssertEqual(PraiseCard.suggestRecipient(messages: [], ownName: "Me"), "")
    }

    // MARK: - store send

    @MainActor
    func testSendPraisePostsPraiseRouteAndSettles() async {
        var posted: [OutgoingSend] = []
        let s = ConversationStore()
        s.attachLiveForTesting(chatID: "19:chat@thread.v2", ownName: "Sam")
        s.sendTransport = SendTransport(
            post: { r in posted.append(r); return "S1" },
            find: { _, _ in nil })
        s.sendPraise(badge: .awesome, recipient: "Jane", note: "Nice work")
        XCTAssertEqual(s.messages.count, 1)
        // The optimistic bubble already mines as praise (renders now).
        let bubble = s.messages[0]
        XCTAssertNotNil(PraiseCard.mine(fromRaw: bubble.raw), "optimistic bubble mines")
        XCTAssertEqual(PraiseCard.mine(fromRaw: bubble.raw)?.recipient, "Jane")
        await TestWait.until { posted.count == 1 }
        XCTAssertEqual(posted.count, 1)
        guard case .praise(let badge, let recipient, let note, let sender) = posted[0].route else {
            return XCTFail("expected praise route, got \(posted[0].route)")
        }
        XCTAssertEqual(badge, PraiseBadge.awesome.wireToken)
        XCTAssertEqual(recipient, "Jane")
        XCTAssertEqual(note, "Nice work")
        XCTAssertEqual(sender, "Sam")
        await TestWait.until { !s.messages[0].id.hasPrefix("pending-") }
        XCTAssertEqual(s.messages.map(\.id), ["S1"])
    }

    @MainActor
    func testSendPraiseEmptyRecipientSendsNothing() {
        let s = ConversationStore()
        s.attachLiveForTesting(chatID: "19:chat@thread.v2", ownName: "Sam")
        var posts = 0
        s.sendTransport = SendTransport(
            post: { _ in posts += 1; return "S1" },
            find: { _, _ in nil })
        s.sendPraise(badge: .awesome, recipient: "  ", note: "x")
        XCTAssertTrue(s.messages.isEmpty)
        XCTAssertEqual(posts, 0)
    }
}
