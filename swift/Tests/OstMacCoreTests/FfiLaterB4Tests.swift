// FfiLaterB4Tests.swift — R14 om-later-b4: ports of the Rust tests for
// moved B4 symbols (red→green against CoreReads, no FFI, no network).
// Fixture tokens ONLY; injected stub fetchers.
import XCTest

@testable import OstMacCore

// MARK: - Stubs

struct B4ReadCall: Sendable {
    let url: String
    let headers: [String: String]
}

final class StubReadFetcher: ReadFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [B4ReadCall] = []
    /// url -> (status, body). Missing URL = test failure.
    var routes: [String: (Int, String)] = [:]
    var testCase: XCTestCase?

    var calls: [B4ReadCall] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var urls: [String] { calls.map(\.url) }

    func get(url: URL, headers: [String: String]) throws -> ReadHTTPResponse {
        lock.lock()
        _calls.append(B4ReadCall(url: url.absoluteString, headers: headers))
        lock.unlock()
        guard let (status, body) = routes[url.absoluteString] else {
            testCase?.record(XCTIssue(
                type: .assertionFailure,
                compactDescription: "unstubbed GET \(url.absoluteString)"
            ))
            throw CoreCallError.failed("unstubbed \(url.absoluteString)")
        }
        return ReadHTTPResponse(status: status, data: Data(body.utf8))
    }
}

final class StubGrantFetcher: TokenRefreshFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _posts = 0
    /// audience -> access token (absent = HTTP 400).
    var grants: [String: String] = [:]
    var posts: Int {
        lock.lock(); defer { lock.unlock() }
        return _posts
    }

    func post(url: URL, headers: [String: String], body: Data) async throws
        -> TokenHTTPResponse
    {
        lock.withLock { _posts += 1 }
        if url.absoluteString == AuthEndpoints.authzWorkURL {
            return TokenHTTPResponse(status: 400, data: Data())
        }
        let text = String(data: body, encoding: .utf8) ?? ""
        let comps = URLComponents(string: "https://x.invalid/?" + text)
        let scope = comps?.queryItems?.first(where: { $0.name == "scope" })?.value ?? ""
        let aud = scope.replacingOccurrences(of: " offline_access", with: "")
        guard let access = grants[aud] else {
            return TokenHTTPResponse(status: 400, data: Data())
        }
        let obj: [String: Any] = ["access_token": access, "expires_in": 3_600]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return TokenHTTPResponse(status: 200, data: data)
    }
}

final class FfiLaterB4Tests: XCTestCase {
    static let now: UInt64 = 1_760_000_000
    static let graph = "https://graph.microsoft.com/v1.0"

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

    /// Valid slots: fresh AAD + graph, RT present.
    func signIn(profile: String = "default") {
        try! store.save(TokenSlots(
            accessToken: StoredTokenValue(
                token: "FIXTURE-AAD", now: Self.now, expiresIn: 3_600
            ),
            refreshToken: "FIXTURE-RT",
            graphToken: StoredTokenValue(
                token: "FIXTURE-GRAPH", now: Self.now, expiresIn: 3_600
            )
        ), profile: profile)
    }

    func failedCode(_ error: Error) -> String? {
        guard case let CoreCallError.failed(msg) = error else { return nil }
        return msg.split(separator: ":").first.map(String.init)
    }

    // MARK: - whoami (port: whoami_envelope_shape)

    func testWhoamiDecodesMe() throws {
        signIn()
        http.routes[Self.graph + "/me"] = (200, #"{"id":"gid-1","displayName":"Doe, Jane","mail":"j@x.example"}"#)
        let me = try CoreReads.whoami(profile: "default", ctx: ctx())
        XCTAssertEqual(me.id, "gid-1")
        XCTAssertEqual(me.display_name, "Doe, Jane")
        XCTAssertEqual(me.mail, "j@x.example")
    }

    func testWhoamiMailNull() throws {
        signIn()
        http.routes[Self.graph + "/me"] = (200, #"{"id":"gid-2","displayName":"No Mail","mail":null}"#)
        let me = try CoreReads.whoami(profile: "default", ctx: ctx())
        XCTAssertEqual(me.id, "gid-2")
        XCTAssertNil(me.mail)
    }

    func testWhoamiDisplayNameDefaultsToUser() throws {
        signIn()
        http.routes[Self.graph + "/me"] = (200, #"{"id":"gid-3"}"#)
        let me = try CoreReads.whoami(profile: "default", ctx: ctx())
        XCTAssertEqual(me.display_name, "User")
    }

    func testWhoamiUsesGraphBearer() throws {
        signIn()
        http.routes[Self.graph + "/me"] = (200, #"{"id":"gid-1","displayName":"N"}"#)
        _ = try CoreReads.whoami(profile: "default", ctx: ctx())
        XCTAssertEqual(http.calls.count, 1)
        XCTAssertEqual(
            http.calls[0].headers["Authorization"], "Bearer FIXTURE-GRAPH"
        )
    }

    // MARK: - whoami cache (port: whoami_cache_hit_serves_without_network)

    func testWhoamiCacheHitServesWithoutNetwork() throws {
        // Unsigned + unstubbed: any network attempt fails the test.
        CoreReads.whoamiCacheStore(
            profile: "default",
            value: WhoamiResponse(ok: true, id: "gid-9", display_name: "Cached User", mail: nil)
        )
        let me = try CoreReads.whoami(profile: "default", ctx: ctx())
        XCTAssertEqual(me.id, "gid-9")
        XCTAssertEqual(me.display_name, "Cached User")
        XCTAssertTrue(http.urls.isEmpty)
    }

    func testWhoamiForUsesOwnSlot() throws {
        CoreReads.whoamiCacheStore(
            profile: "acct-a",
            value: WhoamiResponse(ok: true, id: "gid-a", display_name: "A", mail: nil)
        )
        CoreReads.whoamiCacheStore(
            profile: "acct-b",
            value: WhoamiResponse(ok: true, id: "gid-b", display_name: "B", mail: nil)
        )
        let a = try CoreReads.whoami(profile: "acct-a", ctx: ctx())
        // Profiles are case-sensitive (trim-only normalize, Rust parity).
        let b = try CoreReads.whoami(profile: "  acct-b ", ctx: ctx())
        XCTAssertEqual(a.id, "gid-a")
        XCTAssertEqual(b.id, "gid-b")
        XCTAssertTrue(http.urls.isEmpty)
    }

    func testWhoamiCacheClearIsPerProfile() throws {
        CoreReads.whoamiCacheStore(
            profile: "acct-a",
            value: WhoamiResponse(ok: true, id: "gid-a", display_name: "A", mail: nil)
        )
        CoreReads.whoamiCacheStore(
            profile: "acct-b",
            value: WhoamiResponse(ok: true, id: "gid-b", display_name: "B", mail: nil)
        )
        CoreReads.whoamiCacheClear(profile: "acct-a")
        // acct-b still cached (no network); acct-a refetches.
        let b = try CoreReads.whoami(profile: "acct-b", ctx: ctx())
        XCTAssertEqual(b.id, "gid-b")
        signIn(profile: "acct-a")
        http.routes[Self.graph + "/me"] = (200, #"{"id":"gid-a2","displayName":"A2"}"#)
        let a = try CoreReads.whoami(profile: "acct-a", ctx: ctx())
        XCTAssertEqual(a.id, "gid-a2")
        XCTAssertEqual(http.urls, [Self.graph + "/me"])
    }

    func testUnsignedFailsWithoutNetwork() {
        // Empty store, no RT: Rust yields {ok:false}; Swift throws failed.
        http.routes[Self.graph + "/me"] = (200, #"{"id":"x"}"#)
        XCTAssertThrowsError(try CoreReads.whoami(profile: "default", ctx: ctx())) { e in
            XCTAssertEqual(failedCode(e), "whoami")
        }
        XCTAssertTrue(http.urls.isEmpty)
        XCTAssertEqual(grants.posts, 0)
    }

    func testExpiredGraphTriggersRefresh() throws {
        try! store.save(TokenSlots(
            accessToken: StoredTokenValue(
                token: "FIXTURE-OLD", now: Self.now - 7_200, expiresIn: 3_600
            ),
            refreshToken: "FIXTURE-RT",
            graphToken: StoredTokenValue(
                token: "FIXTURE-OLD", now: Self.now - 7_200, expiresIn: 3_600
            )
        ), profile: "default")
        grants.grants = [
            AuthEndpoints.scopeAAD: "FIXTURE-AAD2",
            AuthEndpoints.scopeGraph: "FIXTURE-GRAPH2",
        ]
        http.routes[Self.graph + "/me"] = (200, #"{"id":"gid-1","displayName":"N"}"#)
        let me = try CoreReads.whoami(profile: "default", ctx: ctx())
        XCTAssertEqual(me.id, "gid-1")
        XCTAssertGreaterThanOrEqual(grants.posts, 2)
        XCTAssertEqual(http.calls[0].headers["Authorization"], "Bearer FIXTURE-GRAPH2")
    }

    // MARK: - presence (port: presence_envelope_shape)

    func testPresenceDecodes() throws {
        signIn()
        http.routes[Self.graph + "/me/presence"] = (200, #"{"availability":"Available","activity":"Available"}"#)
        let p = try CoreReads.presence(ctx: ctx())
        XCTAssertTrue(p.ok)
        XCTAssertEqual(p.availability, "Available")
        XCTAssertEqual(p.activity, "Available")
    }

    func testPresence401Message() {
        signIn()
        http.routes[Self.graph + "/me/presence"] = (401, "")
        XCTAssertThrowsError(try CoreReads.presence(ctx: ctx())) { e in
            guard case let CoreCallError.failed(msg) = e else {
                return XCTFail("wrong error \(e)")
            }
            XCTAssertTrue(msg.hasPrefix("presence: 401 Unauthorized for "), msg)
        }
    }

    func testPresenceServerErrorCarriesBody() {
        signIn()
        http.routes[Self.graph + "/me/presence"] = (503, "try later")
        XCTAssertThrowsError(try CoreReads.presence(ctx: ctx())) { e in
            guard case let CoreCallError.failed(msg) = e else {
                return XCTFail("wrong error \(e)")
            }
            XCTAssertEqual(
                msg,
                "presence: HTTP 503 for \(Self.graph)/me/presence: try later"
            )
        }
    }

    // MARK: - teams (ports: team_json_shape, channel_json_detail_shape, team_json_empty_channels)

    func testTeamsDecodeWithChannels() throws {
        signIn()
        http.routes[Self.graph + "/me/joinedTeams"] = (200, #"{"value":[{"id":"team-1","displayName":"Engineering"}]}"#)
        http.routes[Self.graph + "/teams/team-1/channels"] = (200, #"{"value":[{"id":"19:general@thread.tacv2","displayName":"General"},{"id":"19:random@thread.tacv2","displayName":"Random"}]}"#)
        let t = try CoreReads.teams(ctx: ctx())
        XCTAssertTrue(t.ok)
        XCTAssertEqual(t.teams.count, 1)
        XCTAssertEqual(t.teams[0].teamId, "team-1")
        XCTAssertEqual(t.teams[0].name, "Engineering")
        XCTAssertEqual(t.teams[0].channels.count, 2)
        XCTAssertEqual(t.teams[0].channels[0].channelId, "19:general@thread.tacv2")
        XCTAssertEqual(t.teams[0].channels[0].name, "General")
        XCTAssertEqual(t.teams[0].channels[1].name, "Random")
        XCTAssertNil(t.teams[0].channels[0].description)
        XCTAssertNil(t.teams[0].channels[0].membershipType)
        XCTAssertNil(t.teams[0].channels[0].webUrl)
    }

    func testChannelDetailShape() throws {
        signIn()
        http.routes[Self.graph + "/me/joinedTeams"] = (200, #"{"value":[{"id":"team-1","displayName":"Engineering"}]}"#)
        http.routes[Self.graph + "/teams/team-1/channels"] = (200, #"{"value":[{"id":"19:general@thread.tacv2","displayName":"General","description":"Team-wide announcements","membershipType":"standard","webUrl":"https://teams.cloud.microsoft/l/channel/abc"}]}"#)
        let t = try CoreReads.teams(ctx: ctx())
        let ch = t.teams[0].channels[0]
        XCTAssertEqual(ch.description, "Team-wide announcements")
        XCTAssertEqual(ch.membershipType, "standard")
        XCTAssertEqual(ch.webUrl, "https://teams.cloud.microsoft/l/channel/abc")
    }

    func testTeamsChannelsFailureYieldsEmpty() throws {
        signIn()
        http.routes[Self.graph + "/me/joinedTeams"] = (200, #"{"value":[{"id":"team-2","displayName":"Lonely"}]}"#)
        http.routes[Self.graph + "/teams/team-2/channels"] = (500, "boom")
        let t = try CoreReads.teams(ctx: ctx())
        XCTAssertEqual(t.teams[0].name, "Lonely")
        XCTAssertTrue(t.teams[0].channels.isEmpty)
    }

    func testTeamsNameFallsBackToId() throws {
        signIn()
        http.routes[Self.graph + "/me/joinedTeams"] = (200, #"{"value":[{"id":"team-9"}]}"#)
        http.routes[Self.graph + "/teams/team-9/channels"] = (200, #"{"value":[{"id":"ch-1"}]}"#)
        let t = try CoreReads.teams(ctx: ctx())
        XCTAssertEqual(t.teams[0].name, "team-9")
        XCTAssertEqual(t.teams[0].channels[0].name, "ch-1")
    }

    // MARK: - meetings (port: meeting_to_json_shape)

    func testMeetingsDecode() throws {
        signIn()
        let path = CoreReads.calendarViewPath(now: Self.now, days: 7, limit: 20)
        http.routes[Self.graph + path] = (200, #"{"value":[{"id":"E1","subject":"Standup","start":{"dateTime":"2026-09-24T09:00:00.0000000"},"end":null,"isOnlineMeeting":true,"onlineMeeting":{"joinUrl":"https://teams.microsoft.com/l/meetup-join/x"},"organizer":{"emailAddress":{"name":"Doe, Jane"}}}]}"#)
        let m = try CoreReads.meetings(limit: 20, ctx: ctx())
        XCTAssertTrue(m.ok)
        XCTAssertEqual(m.meetings.count, 1)
        let e = m.meetings[0]
        XCTAssertEqual(e.meetingId, "E1")
        XCTAssertEqual(e.subject, "Standup")
        XCTAssertEqual(e.start, "2026-09-24T09:00:00.0000000")
        XCTAssertNil(e.end)
        XCTAssertEqual(e.joinURL, "https://teams.microsoft.com/l/meetup-join/x")
        XCTAssertEqual(e.organizer, "Doe, Jane")
        XCTAssertTrue(e.isOnline)
    }

    func testMeetingsLimitDefault() throws {
        signIn()
        let path = CoreReads.calendarViewPath(now: Self.now, days: 7, limit: 20)
        http.routes[Self.graph + path] = (200, #"{"value":[]}"#)
        let m = try CoreReads.meetings(limit: 0, ctx: ctx())
        XCTAssertTrue(m.meetings.isEmpty)
        XCTAssertEqual(http.urls, [Self.graph + path])
    }

    func testCalendarViewPathShape() throws {
        let path = CoreReads.calendarViewPath(now: Self.now, days: 7, limit: 20)
        XCTAssertTrue(path.hasPrefix("/me/calendar/calendarView?"), path)
        XCTAssertTrue(path.contains("$top=20"), path)
        XCTAssertTrue(path.contains("$orderby=start/dateTime"), path)
        XCTAssertTrue(
            path.contains("$select=id,subject,isOnlineMeeting,onlineMeeting,start,end,organizer,webLink"),
            path
        )
        // 7-day window: start/end decode to datetimes exactly 604800s apart.
        let comps = URLComponents(string: "https://x.invalid" + path)!
        let items = comps.queryItems!
        let start = items.first(where: { $0.name == "startDateTime" })!.value!
        let end = items.first(where: { $0.name == "endDateTime" })!.value!
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let delta = fmt.date(from: end)!.timeIntervalSince(fmt.date(from: start)!)
        XCTAssertEqual(delta, 604_800)
    }

    func testUnixToISO8601KnownValues() {
        XCTAssertEqual(CoreReads.unixToISO8601(0), "1970-01-01T00:00:00Z")
        XCTAssertEqual(CoreReads.unixToISO8601(86_400), "1970-01-02T00:00:00Z")
        XCTAssertEqual(CoreReads.unixToISO8601(946_684_800), "2000-01-01T00:00:00Z")
    }

    func testParseCalendarViewFallbacks() throws {
        let items = try CoreReads.parseCalendarView(Data(#"{"value":[{"id":"E2","subject":"  ","onlineMeeting":{"joinUrl":"  "}}]}"#.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].subject, "(no subject)")
        XCTAssertNil(items[0].joinURL)
        XCTAssertNil(items[0].organizer)
        XCTAssertFalse(items[0].isOnline)
    }
}
