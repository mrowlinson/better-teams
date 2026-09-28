// TokenRefreshTests.swift — R13 token-store lane: refresh accepts.
//
// Injected fetchers only; zero live network. Fixture tokens ONLY.
import XCTest

@testable import OstMacCore

// MARK: - Stubs

private struct RefreshCall: Sendable {
    let url: String
    let headers: [String: String]
    let body: Data
}

private final class StubRefreshFetcher: TokenRefreshFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [RefreshCall] = []
    enum Outcome: Sendable {
        case ok(access: String, expiresIn: UInt64?, rotatedRT: String?)
        case http(Int)
    }
    /// scope -> grant outcome, or HTTP status to fail with.
    var grants: [String: Outcome] = [:]
    var authz: Outcome = .ok(
        access: "FIXTURE-SKYPE", expiresIn: 3_600,
        rotatedRT: "{\"chatService\":\"https://FIXTURE.chat/\"}"
    )

    var calls: [RefreshCall] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var tokenEndpointPosts: Int {
        calls.filter { $0.url == AuthEndpoints.tokenURL }.count
    }

    func grantScope(of call: RefreshCall) -> String {
        let body = String(data: call.body, encoding: .utf8) ?? ""
        let comps = URLComponents(string: "https://x.invalid/?" + body)
        return comps?.queryItems?.first(where: { $0.name == "scope" })?.value ?? ""
    }

    func post(url: URL, headers: [String: String], body: Data) async throws
        -> TokenHTTPResponse
    {
        lock.withLock {
            _calls.append(RefreshCall(
                url: url.absoluteString, headers: headers, body: body
            ))
        }
        if url.absoluteString == AuthEndpoints.authzWorkURL {
            switch authz {
            case let .ok(tok, exp, gtms):
                var tokens: [String: Any] = ["skypeToken": tok]
                if let exp { tokens["expiresIn"] = Int(exp) }
                var obj: [String: Any] = ["tokens": tokens]
                if let gtms, let gdata = gtms.data(using: .utf8),
                   let gobj = try? JSONSerialization.jsonObject(with: gdata)
                {
                    obj["regionGtms"] = gobj
                }
                let data = try! JSONSerialization.data(withJSONObject: obj)
                return TokenHTTPResponse(status: 200, data: data)
            case let .http(status):
                return TokenHTTPResponse(status: status, data: Data())
            }
        }
        let scope = grantScope(of: RefreshCall(
            url: url.absoluteString, headers: headers, body: body
        ))
        // Audience = scope minus the offline_access tail.
        let aud = scope.replacingOccurrences(of: " offline_access", with: "")
        let grant: Outcome = grants[aud] ?? .ok(access: "FIXTURE-\(aud.hashValue)", expiresIn: 3_600, rotatedRT: nil)
        switch grant {
        case let .ok(access, exp, rt):
            var obj: [String: Any] = ["access_token": access]
            if let exp { obj["expires_in"] = Int(exp) }
            if let rt { obj["refresh_token"] = rt }
            let data = try! JSONSerialization.data(withJSONObject: obj)
            return TokenHTTPResponse(status: 200, data: data)
        case let .http(status):
            return TokenHTTPResponse(
                status: status, data: Data("{\"error\":\"x\"}".utf8)
            )
        }
    }
}

/// Full-success stub with deterministic fixture tokens per audience.
private func successStub() -> StubRefreshFetcher {
    let s = StubRefreshFetcher()
    s.grants = [
        AuthEndpoints.scopeAAD: .ok(access: "FIXTURE-AAD-NEW", expiresIn: 3_600, rotatedRT: "FIXTURE-RT-NEW"),
        AuthEndpoints.scopeGraph: .ok(access: "FIXTURE-GRAPH-NEW", expiresIn: 3_600, rotatedRT: nil),
        AuthEndpoints.scopeIC3: .ok(access: "FIXTURE-IC3-NEW", expiresIn: 3_600, rotatedRT: nil),
        AuthEndpoints.scopeRecorder: .ok(access: "FIXTURE-REC-NEW", expiresIn: 3_600, rotatedRT: nil),
    ]
    return s
}

private final class FailingSaveStore: TokenStore, @unchecked Sendable {
    private let inner = MemoryTokenStore()
    func load(profile: String) -> TokenSlots { inner.load(profile: profile) }
    func save(_ slots: TokenSlots, profile: String) throws {
        throw TokenStoreError.io("FIXTURE write failure")
    }

    func clear(profile: String) throws {}
    func status(profile: String) -> StatusResponse {
        inner.status(profile: profile)
    }

    func seed(_ slots: TokenSlots, profile: String) throws {
        try inner.save(slots, profile: profile)
    }
}

private final class StubAPIFetcher: TeamsAuthFetcher, @unchecked Sendable {
    struct Call: Sendable {
        let method: String
        let url: String
        let headers: [String: String]
        let body: Data?
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var response = AuthHTTPResponse(status: 200, data: Data("{}".utf8))

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func send(
        method: String, url: URL, headers: [String: String], body: Data?
    ) async throws -> AuthHTTPResponse {
        lock.withLock {
            _calls.append(Call(
                method: method, url: url.absoluteString, headers: headers,
                body: body
            ))
        }
        return response
    }
}

// MARK: - Tests

/// Fixed clock for all refresh tests (global = Sendable-safe).
private let fxNow: UInt64 = 1_800_000_000

final class TokenRefreshTests: XCTestCase {
    private let now: UInt64 = fxNow

    private func expiredWithRT() -> TokenSlots {
        var s = TokenSlots()
        s.accessToken = StoredTokenValue(
            token: "FIXTURE-AAD-OLD", expiresAt: now - 100
        )
        s.graphToken = StoredTokenValue(
            token: "FIXTURE-GRAPH-OLD", expiresAt: now - 100
        )
        s.refreshToken = "FIXTURE-RT-OLD"
        return s
    }

    // MARK: Endpoint literals (risk #5 pin)

    func testEndpointsMatchRust() {
        // Copied from rust/ost/src/auth/{mod,oauth,skype}.rs — change Rust
        // and Swift together or this fails.
        XCTAssertEqual(AuthEndpoints.clientID, "1fec8e78-bce4-4aaf-ab1b-5451cc387264")
        XCTAssertEqual(AuthEndpoints.tenant, "common")
        XCTAssertEqual(
            AuthEndpoints.tokenURL,
            "https://login.microsoftonline.com/common/oauth2/v2.0/token"
        )
        XCTAssertEqual(
            AuthEndpoints.deviceCodeURL,
            "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode"
        )
        XCTAssertEqual(
            AuthEndpoints.authzWorkURL,
            "https://teams.microsoft.com/api/authsvc/v1.0/authz"
        )
        XCTAssertEqual(
            AuthEndpoints.scopeAAD, "https://api.spaces.skype.com/.default"
        )
        XCTAssertEqual(
            AuthEndpoints.scopeGraph, "https://graph.microsoft.com/.default"
        )
        XCTAssertEqual(
            AuthEndpoints.scopeIC3, "https://ic3.teams.office.com/.default"
        )
        XCTAssertEqual(
            AuthEndpoints.scopeRecorder,
            "4580fd1d-e5a3-4f56-9ad1-aab0e3bf8f76/.default"
        )
        XCTAssertEqual(
            AuthEndpoints.grantScope(AuthEndpoints.scopeAAD),
            "https://api.spaces.skype.com/.default offline_access"
        )
    }

    // MARK: Rotation + fan-out (accept #3)

    func testRotationAndFanOutSaved() async throws {
        let store = MemoryTokenStore(now: { fxNow })
        try store.save(expiredWithRT(), profile: "p")
        let fetcher = successStub()
        let ok = try await TokenRefresh.refresh(
            profile: "p", store: store, fetcher: fetcher, now: { fxNow }
        )
        XCTAssertTrue(ok)
        let slots = store.load(profile: "p")
        XCTAssertEqual(slots.accessToken?.token, "FIXTURE-AAD-NEW")
        XCTAssertEqual(slots.accessToken?.expiresAt, now + 3_600)
        XCTAssertEqual(slots.refreshToken, "FIXTURE-RT-NEW") // rotation kept
        XCTAssertEqual(slots.graphToken?.token, "FIXTURE-GRAPH-NEW")
        XCTAssertEqual(slots.ic3Token?.token, "FIXTURE-IC3-NEW")
        XCTAssertEqual(slots.recorderToken?.token, "FIXTURE-REC-NEW")
        XCTAssertEqual(slots.skypeToken?.token, "FIXTURE-SKYPE")
        XCTAssertEqual(
            slots.regionGtms, "{\"chatService\":\"https://FIXTURE.chat/\"}"
        )
        XCTAssertEqual(fetcher.tokenEndpointPosts, 4) // aad+graph+ic3+rec
        XCTAssertEqual(fetcher.calls.count, 5) // + authsvc
    }

    func testDerivedFailureIsBestEffort() async throws {
        let store = MemoryTokenStore(now: { fxNow })
        try store.save(expiredWithRT(), profile: "p")
        let fetcher = successStub()
        fetcher.grants[AuthEndpoints.scopeGraph] = StubRefreshFetcher.Outcome.http(500)
        fetcher.authz = StubRefreshFetcher.Outcome.http(500)
        let ok = try await TokenRefresh.refresh(
            profile: "p", store: store, fetcher: fetcher, now: { fxNow }
        )
        XCTAssertTrue(ok) // still refreshed
        let slots = store.load(profile: "p")
        XCTAssertEqual(slots.accessToken?.token, "FIXTURE-AAD-NEW")
        XCTAssertEqual(slots.ic3Token?.token, "FIXTURE-IC3-NEW")
        // Failed legs keep their old values, never blanked.
        XCTAssertEqual(slots.graphToken?.token, "FIXTURE-GRAPH-OLD")
        XCTAssertNil(slots.skypeToken)
    }

    func testNoRefreshTokenIsSilent() async throws {
        let store = MemoryTokenStore(now: { fxNow })
        var s = TokenSlots()
        s.accessToken = StoredTokenValue(
            token: "FIXTURE-AAD-OLD", expiresAt: now - 100
        )
        try store.save(s, profile: "p")
        let fetcher = successStub()
        let refreshed = try await TokenRefresh.refresh(
            profile: "p", store: store, fetcher: fetcher, now: { fxNow }
        )
        XCTAssertFalse(refreshed)
        XCTAssertEqual(fetcher.calls.count, 0)
    }

    func testAADGrantFailureThrowsAndKeepsOld() async throws {
        let store = MemoryTokenStore(now: { fxNow })
        let old = expiredWithRT()
        try store.save(old, profile: "p")
        let fetcher = successStub()
        fetcher.grants[AuthEndpoints.scopeAAD] = StubRefreshFetcher.Outcome.http(400)
        await XCTAssertThrowsErrorAsync {
            _ = try await TokenRefresh.refresh(
                profile: "p", store: store, fetcher: fetcher, now: { fxNow }
            )
        }
        XCTAssertEqual(store.load(profile: "p"), old)
    }

    func testWriteThroughFailureFailsRefresh() async throws {
        let store = FailingSaveStore()
        try store.seed(expiredWithRT(), profile: "p")
        let fetcher = successStub()
        do {
            _ = try await TokenRefresh.refresh(
                profile: "p", store: store, fetcher: fetcher, now: { fxNow }
            )
            XCTFail("expected persist throw")
        } catch let e as TokenRefreshError {
            if case .persist = e {} else {
                XCTFail("expected .persist, got \(e)")
            }
        }
    }

    // MARK: Request shapes

    func testGrantAndAuthzShapes() async throws {
        let store = MemoryTokenStore(now: { fxNow })
        try store.save(expiredWithRT(), profile: "p")
        let fetcher = successStub()
        _ = try await TokenRefresh.refresh(
            profile: "p", store: store, fetcher: fetcher, now: { fxNow }
        )
        let aadCall = fetcher.calls.first(where: {
            $0.url == AuthEndpoints.tokenURL
                && fetcher.grantScope(of: $0).hasPrefix(AuthEndpoints.scopeAAD)
        })
        XCTAssertNotNil(aadCall)
        let body = String(data: aadCall!.body, encoding: .utf8) ?? ""
        let comps = URLComponents(string: "https://x.invalid/?" + body)
        let params = Dictionary(
            uniqueKeysWithValues: (comps?.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }
        )
        XCTAssertEqual(params["grant_type"], "refresh_token")
        XCTAssertEqual(params["client_id"], AuthEndpoints.clientID)
        XCTAssertEqual(params["refresh_token"], "FIXTURE-RT-OLD")
        XCTAssertEqual(
            params["scope"], "\(AuthEndpoints.scopeAAD) offline_access"
        )
        XCTAssertEqual(
            aadCall!.headers["Content-Type"],
            "application/x-www-form-urlencoded"
        )
        let authz = fetcher.calls.first(where: {
            $0.url == AuthEndpoints.authzWorkURL
        })
        XCTAssertNotNil(authz)
        XCTAssertEqual(
            authz!.headers["Authorization"], "Bearer FIXTURE-AAD-NEW"
        )
        XCTAssertEqual(authz!.headers["Content-Length"], "0")
    }

    // MARK: Backfill (accept #3)

    func testBackfillRule() {
        var full = TokenSlots()
        full.accessToken = StoredTokenValue(
            token: "FIXTURE-AAD", expiresAt: now + 3_600
        )
        full.refreshToken = "FIXTURE-RT"
        full.ic3Token = StoredTokenValue(token: "FIXTURE-IC3", expiresAt: now + 3_600)
        full.recorderToken = StoredTokenValue(
            token: "FIXTURE-REC", expiresAt: now + 3_600
        )
        XCTAssertFalse(TokenRefresh.loginNeedsRefresh(full, now: now))
        var missingIC3 = full
        missingIC3.ic3Token = nil
        XCTAssertTrue(TokenRefresh.loginNeedsRefresh(missingIC3, now: now))
        var missingRec = full
        missingRec.recorderToken = nil
        XCTAssertTrue(TokenRefresh.loginNeedsRefresh(missingRec, now: now))
        var stale = missingIC3
        stale.accessToken = StoredTokenValue(
            token: "FIXTURE-AAD", expiresAt: now - 1
        )
        XCTAssertFalse(TokenRefresh.loginNeedsRefresh(stale, now: now))
        var noRT = missingIC3
        noRT.refreshToken = nil
        XCTAssertFalse(TokenRefresh.loginNeedsRefresh(noRT, now: now))
    }

    // MARK: Singleflight (accept #4)

    func testSingleflightTenWay() async throws {
        let store = MemoryTokenStore(now: { fxNow })
        try store.save(expiredWithRT(), profile: "p")
        let fetcher = successStub()
        let gate = RefreshSingleflight()
        let results = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 10 {
                group.addTask {
                    try await gate.refresh(
                        profile: "p", store: store, fetcher: fetcher,
                        now: { fxNow }
                    )
                }
            }
            var out: [Bool] = []
            for try await r in group { out.append(r) }
            return out
        }
        XCTAssertEqual(results, Array(repeating: true, count: 10))
        XCTAssertEqual(
            fetcher.tokenEndpointPosts, 4,
            "one flow = 4 token-endpoint POSTs, not 40"
        )
        XCTAssertEqual(fetcher.calls.count, 5)
        // Second wave sees fresh AAD only if it re-checks; refresh itself
        // always runs — singleflight covers the overlap window.
    }

    func testSingleflightIsPerProfile() async throws {
        let store = MemoryTokenStore(now: { fxNow })
        try store.save(expiredWithRT(), profile: "p1")
        try store.save(expiredWithRT(), profile: "p2")
        let fetcher = successStub()
        let gate = RefreshSingleflight()
        async let r1: Bool = gate.refresh(
            profile: "p1", store: store, fetcher: fetcher, now: { fxNow }
        )
        async let r2: Bool = gate.refresh(
            profile: "p2", store: store, fetcher: fetcher, now: { fxNow }
        )
        let pair = try await [r1, r2]
        XCTAssertEqual(pair, [true, true])
        XCTAssertEqual(fetcher.tokenEndpointPosts, 8) // 2 flows
    }

    // MARK: Auto-refresh trigger on build (accept #3)

    private func buildClient(
        slots: TokenSlots, api: StubAPIFetcher,
        refreshFetcher: StubRefreshFetcher? = nil
    ) async throws -> TeamsAuthClient.Client {
        let store = MemoryTokenStore(now: { fxNow })
        try store.save(slots, profile: "p")
        return try await TeamsAuthClient.build(
            profile: "p", store: store,
            refreshFetcher: refreshFetcher ?? successStub(),
            apiFetcher: api, now: { fxNow }
        )
    }

    func testBuildFreshMakesZeroRefreshCalls() async throws {
        var s = TokenSlots()
        s.accessToken = StoredTokenValue(
            token: "FIXTURE-AAD", expiresAt: now + 3_600
        )
        s.graphToken = StoredTokenValue(
            token: "FIXTURE-GRAPH", expiresAt: now + 3_600
        )
        s.skypeToken = StoredTokenValue(
            token: "FIXTURE-SKYPE", expiresAt: now + 3_600
        )
        s.refreshToken = "FIXTURE-RT"
        let api = StubAPIFetcher()
        let rf = successStub()
        _ = try await buildClient(slots: s, api: api, refreshFetcher: rf)
        XCTAssertEqual(rf.calls.count, 0)
    }

    func testBuildExpiredAADRefreshesOnce() async throws {
        let api = StubAPIFetcher()
        let rf = successStub()
        let client = try await buildClient(
            slots: expiredWithRT(), api: api, refreshFetcher: rf
        )
        XCTAssertEqual(rf.tokenEndpointPosts, 4) // exactly 1 refresh flow
        _ = try await client.graphGet("/me") // works on fresh tokens
        XCTAssertEqual(api.calls.count, 1)
    }

    func testBuildMissingGraphRefreshesOnce() async throws {
        var s = TokenSlots()
        s.accessToken = StoredTokenValue(
            token: "FIXTURE-AAD", expiresAt: now + 3_600
        )
        s.refreshToken = "FIXTURE-RT" // graph missing → refresh
        let api = StubAPIFetcher()
        let rf = successStub()
        _ = try await buildClient(slots: s, api: api, refreshFetcher: rf)
        XCTAssertEqual(rf.tokenEndpointPosts, 4)
    }

    func testBuildExpiredWithoutRTThrowsSilently() async throws {
        var s = TokenSlots()
        s.accessToken = StoredTokenValue(
            token: "FIXTURE-AAD", expiresAt: now - 100
        )
        let api = StubAPIFetcher()
        let rf = successStub()
        await XCTAssertThrowsErrorAsync {
            _ = try await buildClient(slots: s, api: api, refreshFetcher: rf)
        }
        XCTAssertEqual(rf.calls.count, 0)
        XCTAssertEqual(api.calls.count, 0)
    }
}

// MARK: - Client header/URL port (client.rs parity)

final class TeamsAuthClientTests: XCTestCase {
    private let now: UInt64 = fxNow

    private func client(
        api: StubAPIFetcher, region: String? = nil,
        skypeExp: UInt64? = nil, graphExp: UInt64? = nil
    ) async throws -> TeamsAuthClient.Client {
        var s = TokenSlots()
        s.accessToken = StoredTokenValue(
            token: "FIXTURE-AAD", expiresAt: now + 3_600
        )
        s.graphToken = StoredTokenValue(
            token: "FIXTURE-GRAPH", expiresAt: graphExp ?? now + 3_600
        )
        s.skypeToken = StoredTokenValue(
            token: "FIXTURE-SKYPE", expiresAt: skypeExp ?? now + 3_600
        )
        s.refreshToken = "FIXTURE-RT"
        s.regionGtms = region
        let store = MemoryTokenStore(now: { fxNow })
        try store.save(s, profile: "p")
        // Fresh tokens → build performs zero refresh.
        let rf = successStub()
        let c = try await TeamsAuthClient.build(
            profile: "p", store: store, refreshFetcher: rf,
            apiFetcher: api, now: { fxNow }
        )
        XCTAssertEqual(rf.calls.count, 0)
        return c
    }

    func testGraphHelpers() async throws {
        let api = StubAPIFetcher()
        let c = try await client(api: api)
        _ = try await c.graphGet("/me")
        _ = try await c.graphGetConsistent("/users?$search=x")
        _ = try await c.graphGetURL("https://graph.microsoft.com/v1.0/$batch")
        _ = try await c.graphPost("/chats", body: ["a": 1])
        _ = try await c.graphDelete("/chats/1")
        _ = try await c.graphPutBytes(
            "/drive/items/1/content", bytes: Data([1, 2]),
            contentType: "application/octet-stream"
        )
        _ = try await c.graphPatch("/me/todo/x", body: ["status": "done"])
        let calls = api.calls
        XCTAssertEqual(calls.count, 7)
        XCTAssertEqual(calls[0].method, "GET")
        XCTAssertEqual(
            calls[0].url, "https://graph.microsoft.com/v1.0/me"
        )
        XCTAssertEqual(
            calls[0].headers["Authorization"], "Bearer FIXTURE-GRAPH"
        )
        XCTAssertEqual(calls[1].headers["ConsistencyLevel"], "eventual")
        XCTAssertEqual(
            calls[2].url, "https://graph.microsoft.com/v1.0/$batch"
        )
        let postBody = try JSONSerialization.jsonObject(
            with: calls[3].body ?? Data()
        ) as? [String: Any]
        XCTAssertEqual(postBody?["a"] as? Int, 1)
        XCTAssertEqual(calls[3].headers["Content-Type"], "application/json")
        XCTAssertEqual(calls[4].method, "DELETE")
        XCTAssertEqual(calls[5].headers["Content-Type"], "application/octet-stream")
        XCTAssertEqual(calls[5].body, Data([1, 2]))
        XCTAssertEqual(calls[6].method, "PATCH")
    }

    func testDriveSessionPutHasNoAuth() async throws {
        let api = StubAPIFetcher()
        let c = try await client(api: api)
        _ = try await c.driveSessionPut(
            uploadURL: "https://FIXTURE.upload/session", chunk: Data([9]),
            start: 0, end: 0, total: 1
        )
        let call = api.calls.first!
        XCTAssertNil(call.headers["Authorization"])
        XCTAssertEqual(call.headers["Content-Range"], "bytes 0-0/1")
        XCTAssertEqual(call.headers["Content-Length"], "1")
    }

    func testSkypeChatCsaHelpers() async throws {
        let api = StubAPIFetcher()
        let c = try await client(api: api)
        _ = try await c.teamsGet("https://FIXTURE.teams/x")
        _ = try await c.teamsPost("https://FIXTURE.teams/x", body: ["b": 2])
        _ = try await c.csaGet("https://FIXTURE.csa/x")
        _ = try await c.chatGet("https://FIXTURE.chat/x")
        _ = try await c.chatPost("https://FIXTURE.chat/x", body: ["c": 3])
        _ = try await c.chatPut("https://FIXTURE.chat/x", body: ["c": 4])
        _ = try await c.chatDelete("https://FIXTURE.chat/x")
        let calls = api.calls
        XCTAssertEqual(calls[0].headers["X-SkypeToken"], "FIXTURE-SKYPE")
        XCTAssertEqual(calls[1].headers["X-SkypeToken"], "FIXTURE-SKYPE")
        XCTAssertEqual(
            calls[2].headers["Authorization"], "Bearer FIXTURE-SKYPE"
        )
        XCTAssertEqual(
            calls[2].headers["x-ms-client-version"],
            TeamsAuthClient.csaClientVersion
        )
        for i in 3 ..< 7 {
            XCTAssertEqual(
                calls[i].headers["Authentication"], "skypetoken=FIXTURE-SKYPE",
                "call \(i)"
            )
        }
        XCTAssertNil(calls[6].body)
    }

    func testRegionURLs() async throws {
        let api = StubAPIFetcher()
        let plain = try await client(api: api)
        XCTAssertEqual(
            plain.chatServiceURL, TeamsAuthClient.defaultChatService
        )
        XCTAssertEqual(plain.chatsvcaggURL, TeamsAuthClient.chatsvcagg)
        let regional = try await client(
            api: api,
            region: "{\"chatService\":\"https://FIXTURE.cs/\",\"chatServiceAggregator\":\"https://FIXTURE.csa/\"}"
        )
        XCTAssertEqual(regional.chatServiceURL, "https://FIXTURE.cs/")
        XCTAssertEqual(regional.chatsvcaggURL, "https://FIXTURE.csa/")
    }

    func testCheckResponseMessages() {
        let r401 = AuthHTTPResponse(status: 401, data: Data("d".utf8))
        XCTAssertThrowsError(
            try TeamsAuthClient.checked(r401, url: "https://x.invalid/u")
        ) { e in
            XCTAssertEqual(
                e as? TeamsAuthError,
                .http(
                    "401 Unauthorized for https://x.invalid/u. " +
                        "Token may be invalid -- run 'teams-cli login'."
                )
            )
        }
        let r500 = AuthHTTPResponse(status: 500, data: Data("boom".utf8))
        XCTAssertThrowsError(
            try TeamsAuthClient.checked(r500, url: "https://x.invalid/u")
        ) { e in
            XCTAssertEqual(
                e as? TeamsAuthError,
                .http("HTTP 500 for https://x.invalid/u: boom")
            )
        }
        XCTAssertNoThrow(
            try TeamsAuthClient.checked(
                AuthHTTPResponse(status: 200, data: Data()), url: "u"
            )
        )
    }

    func testExpiredTokensThrowWithoutNetwork() async throws {
        let api = StubAPIFetcher()
        // Graph expired → build itself throws (auto-trigger, no RT-less
        // path): use missing-RT expired slots to prove zero network.
        var s = TokenSlots()
        s.graphToken = StoredTokenValue(
            token: "FIXTURE-GRAPH", expiresAt: now - 100
        )
        let store = MemoryTokenStore(now: { fxNow })
        try store.save(s, profile: "p")
        await XCTAssertThrowsErrorAsync {
            _ = try await TeamsAuthClient.build(
                profile: "p", store: store, refreshFetcher: successStub(),
                apiFetcher: api, now: { fxNow }
            )
        }
        XCTAssertEqual(api.calls.count, 0)
    }
}

// MARK: - Async throw assertion (XCTest has no built-in)

private func XCTAssertThrowsErrorAsync(
    _ work: () async throws -> Void,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await work()
        XCTFail("expected throw \(message)", file: file, line: line)
    } catch {}
}
