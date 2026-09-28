// FfiLaterB4ChatsTests.swift — R14 om-later-b4 B4 chats: native chat
// stack moved to Swift (CoreReads). Stub fetchers only; zero network.
// Fixture tokens ONLY.
import XCTest

@testable import OstMacCore

final class FfiLaterB4ChatsTests: XCTestCase {
    static let now: UInt64 = 1_760_000_000
    static let csaBase = "https://teams.microsoft.com/api/csa/api/v1"
    static let aggBase = "https://chatsvcagg.teams.microsoft.com"
    static let svcBase = "https://amer.ng.msg.teams.microsoft.com"

    var store: MemoryTokenStore!
    var http: StubReadFetcher!
    var grants: StubGrantFetcher!

    override func setUp() {
        super.setUp()
        CoreReads.whoamiCacheClearAll()
        store = MemoryTokenStore(now: { Self.now })
        http = StubReadFetcher()
        http.testCase = self
        grants = StubGrantFetcher()
    }

    override func tearDown() {
        CoreReads.whoamiCacheClearAll()
        super.tearDown()
    }

    func ctx() -> ReadContext {
        ReadContext(
            store: store, http: http, refresher: grants,
            now: { Self.now }
        )
    }

    func signIn(skypeExpired: Bool = false) {
        try! store.save(TokenSlots(
            accessToken: StoredTokenValue(
                token: "FIXTURE-AAD", now: Self.now, expiresIn: 3_600
            ),
            refreshToken: "FIXTURE-RT",
            skypeToken: StoredTokenValue(
                token: "FIXTURE-SKYPE",
                now: skypeExpired ? Self.now - 7_200 : Self.now,
                expiresIn: 3_600
            ),
            graphToken: StoredTokenValue(
                token: "FIXTURE-GRAPH", now: Self.now, expiresIn: 3_600
            )
        ), profile: "default")
    }

    func csaURL(_ limit: Int = 20) -> String {
        "\(Self.csaBase)/teams/users/ME/conversations?view=mychats&pageSize=\(limit)"
    }

    func aggURL(_ limit: Int = 20) -> String {
        "\(Self.aggBase)/api/v2/users/ME/conversations?view=mychats&pageSize=\(limit)"
    }

    func svcURL(_ limit: Int = 20) -> String {
        "\(Self.svcBase)/v1/users/ME/conversations?view=mychats&pageSize=\(limit)"
    }

    // MARK: - list (port: chat_json_shape)

    func testChatsDecodeCSA() throws {
        signIn()
        http.routes[csaURL()] = (200, #"{"conversations":[{"id":"19:abc@thread","threadProperties":{"topic":"Grp"},"lastMessage":{"composetime":"t","imdisplayname":"s","content":"p"}},{"id":"","threadProperties":{"topic":"skip"}}]}"#)
        let r = try CoreReads.chats(limit: 20, ctx: ctx())
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.chats.count, 1)
        XCTAssertEqual(r.chats[0].chatId, "19:abc@thread")
        XCTAssertEqual(r.chats[0].name, "Grp")
        XCTAssertTrue(r.chats[0].is_group)
        XCTAssertEqual(r.chats[0].last_message_time, "t")
        XCTAssertEqual(r.chats[0].last_message_sender, "s")
        XCTAssertEqual(r.chats[0].last_message_preview, "p")
    }

    func testChatsCSAHeaders() throws {
        signIn()
        http.routes[csaURL()] = (200, #"{"conversations":[]}"#)
        _ = try CoreReads.chats(limit: 20, ctx: ctx())
        XCTAssertEqual(http.calls.count, 1)
        XCTAssertEqual(
            http.calls[0].headers["Authorization"], "Bearer FIXTURE-SKYPE"
        )
        XCTAssertEqual(
            http.calls[0].headers["x-ms-client-version"],
            "1416/1.0.0.2024050301"
        )
    }

    func testChatsFallbackToAgg() throws {
        signIn()
        http.routes[csaURL()] = (500, "csa down")
        http.routes[aggURL()] = (200, #"{"conversations":[{"id":"19:abc@thread","threadProperties":{"topic":"Grp"}}]}"#)
        let r = try CoreReads.chats(limit: 20, ctx: ctx())
        XCTAssertEqual(r.chats.count, 1)
        XCTAssertEqual(r.chats[0].name, "Grp")
        XCTAssertEqual(http.urls, [csaURL(), aggURL()])
        XCTAssertEqual(
            http.calls[1].headers["Authentication"], "skypetoken=FIXTURE-SKYPE"
        )
    }

    func testChatsFallbackToService() throws {
        signIn()
        http.routes[csaURL()] = (500, "csa down")
        http.routes[aggURL()] = (500, "agg down")
        http.routes[svcURL()] = (200, #"{"conversations":[]}"#)
        let r = try CoreReads.chats(limit: 20, ctx: ctx())
        XCTAssertTrue(r.chats.isEmpty)
        XCTAssertEqual(http.urls, [csaURL(), aggURL(), svcURL()])
    }

    func testChatsAllFailReportsLast() {
        signIn()
        http.routes[csaURL()] = (500, "csa down")
        http.routes[aggURL()] = (500, "agg down")
        http.routes[svcURL()] = (503, "svc down")
        XCTAssertThrowsError(try CoreReads.chats(limit: 20, ctx: ctx())) { e in
            guard case let CoreCallError.failed(msg) = e else {
                return XCTFail("wrong error \(e)")
            }
            XCTAssertEqual(
                msg, "chats: HTTP 503 for \(svcURL()): svc down"
            )
        }
    }

    func testChatsLimitDefault() throws {
        signIn()
        http.routes[csaURL(20)] = (200, #"{"conversations":[]}"#)
        _ = try CoreReads.chats(limit: 0, ctx: ctx())
        XCTAssertEqual(http.urls, [csaURL(20)])
    }

    func testChatsIsGroup() throws {
        signIn()
        http.routes[csaURL()] = (200, #"{"conversations":[{"id":"19:a@thread.v2","threadProperties":{"topic":"G"}},{"id":"19:meeting_xyz","threadProperties":{"topic":"M"}},{"id":"19:abc@unq.one","threadProperties":{"topic":"D"}}]}"#)
        let r = try CoreReads.chats(limit: 20, ctx: ctx())
        XCTAssertEqual(r.chats.map(\.is_group), [true, true, false])
    }

    func testExpiredSkypeFails() {
        // Rust parity wart: skype expiry alone never triggers a refresh;
        // the read fails (needs_refresh only watches AAD/graph).
        signIn(skypeExpired: true)
        http.routes[csaURL()] = (200, #"{"conversations":[]}"#)
        XCTAssertThrowsError(try CoreReads.chats(limit: 20, ctx: ctx())) { e in
            guard case let CoreCallError.failed(msg) = e else {
                return XCTFail("wrong error \(e)")
            }
            XCTAssertTrue(msg.hasPrefix("chats: Skype token expired"), msg)
        }
        XCTAssertTrue(http.urls.isEmpty)
    }

    // MARK: - region URLs

    func testRegionURLsFromGtms() throws {
        signIn()
        var slots = store.load(profile: "default")
        slots.regionGtms = #"{"chatService":"https://FIXTURE.svc","chatServiceAggregator":"https://FIXTURE.agg"}"#
        try! store.save(slots, profile: "default")
        http.routes[csaURL()] = (500, "csa down")
        let agg = "https://FIXTURE.agg/api/v2/users/ME/conversations?view=mychats&pageSize=20"
        http.routes[agg] = (200, #"{"conversations":[]}"#)
        _ = try CoreReads.chats(limit: 20, ctx: ctx())
        XCTAssertEqual(http.urls, [csaURL(), agg])
    }

    // MARK: - mate resolve

    func testMateResolve() throws {
        signIn()
        http.routes[csaURL()] = (200, #"{"conversations":[{"id":"19:pair@unq.one","lastMessage":{"imdisplayname":"Fallback Sender"}}]}"#)
        http.routes["https://graph.microsoft.com/v1.0/me"] = (200, #"{"id":"OID-SELF","displayName":"Self"}"#)
        http.routes["\(Self.svcBase)/v1/threads/19:pair@unq.one/members"] = (200, #"{"members":[{"id":"8:orgid:OID-SELF"},{"id":"8:orgid:OID-MATE"}]}"#)
        http.routes["\(Self.svcBase)/v1/users/ME/conversations/19:pair@unq.one/messages?pageSize=25"] = (200, #"{"messages":[{"from":"https://x/v1/users/ME/contacts/8:orgid:OID-MATE","imdisplayname":"Mate Name","messagetype":"Text","content":"hi"}]}"#)
        let r = try CoreReads.chats(limit: 20, ctx: ctx())
        XCTAssertEqual(r.chats.count, 1)
        XCTAssertEqual(r.chats[0].name, "Mate Name")
    }

    func testMateResolveAmbiguousKeepsSender() throws {
        signIn()
        http.routes[csaURL()] = (200, #"{"conversations":[{"id":"19:pair@unq.one","lastMessage":{"imdisplayname":"Fallback Sender"}}]}"#)
        http.routes["https://graph.microsoft.com/v1.0/me"] = (200, #"{"id":"OID-SELF","displayName":"Self"}"#)
        // Two non-self MRIs: no unique mate.
        http.routes["\(Self.svcBase)/v1/threads/19:pair@unq.one/members"] = (200, #"{"members":[{"id":"8:orgid:OID-SELF"},{"id":"8:orgid:OID-A"},{"id":"8:orgid:OID-B"}]}"#)
        let r = try CoreReads.chats(limit: 20, ctx: ctx())
        XCTAssertEqual(r.chats[0].name, "Fallback Sender")
    }

    func testMateResolveMembersFailureKeepsSender() throws {
        signIn()
        http.routes[csaURL()] = (200, #"{"conversations":[{"id":"19:pair@unq.one","lastMessage":{"imdisplayname":"Fallback Sender"}}]}"#)
        http.routes["https://graph.microsoft.com/v1.0/me"] = (200, #"{"id":"OID-SELF","displayName":"Self"}"#)
        http.routes["\(Self.svcBase)/v1/threads/19:pair@unq.one/members"] = (404, "nope")
        let r = try CoreReads.chats(limit: 20, ctx: ctx())
        XCTAssertEqual(r.chats[0].name, "Fallback Sender")
    }

    // MARK: - pure helpers

    func testStripHTML() {
        XCTAssertEqual(CoreReads.stripHTML("<p>hi</p>"), "hi")
        XCTAssertEqual(CoreReads.stripHTML("a</p><p>b"), "a b")
        XCTAssertEqual(CoreReads.stripHTML("a<b>x</b>b"), "axb")
        XCTAssertEqual(
            CoreReads.stripHTML("a &amp; b&lt;c&gt; &quot;q&quot; &#39;e&#39;&nbsp;x"),
            "a & b<c> \"q\" 'e' x"
        )
    }

    func testPreviewTruncation() {
        let long = String(repeating: "w", count: 90)
        let cut = CoreReads.truncatePreview(long)
        XCTAssertEqual(cut.count, 80)
        XCTAssertTrue(cut.hasSuffix("..."))
        XCTAssertEqual(CoreReads.truncatePreview(String(repeating: "w", count: 80)), String(repeating: "w", count: 80))
    }

    func testSystemLabels() {
        XCTAssertEqual(CoreReads.systemLabelFor("48:notifications"), "Notifications")
        XCTAssertEqual(CoreReads.systemLabelFor("48:"), "[System chat]")
        XCTAssertEqual(CoreReads.systemLabelFor("19:meeting_abc"), "[Meeting chat]")
        XCTAssertEqual(CoreReads.systemLabelFor("19:a@thread.v2"), "[Group chat]")
        XCTAssertEqual(CoreReads.systemLabelFor("19:abc@unq.one"), "[Direct message]")
        XCTAssertEqual(CoreReads.systemLabelFor("8:xyz"), "[Chat]")
    }

    func testIsOneToOneID() {
        XCTAssertTrue(CoreReads.isOneToOneID("19:abc@unq.one"))
        XCTAssertFalse(CoreReads.isOneToOneID("19:a@thread.v2"))
        XCTAssertFalse(CoreReads.isOneToOneID("19:meeting_x"))
        XCTAssertFalse(CoreReads.isOneToOneID("48:notes"))
    }
}
