// FfiLaterB18Tests.swift — R14 om-later-b18: device-code flow in Swift.
//
// Stub fetcher + memory store only; zero live network. Fixture tokens ONLY.
// Ports the Rust `device_poll_unknown_session_is_error` R-arg test plus the
// full start/poll matrix (pending/fatal/complete/expiry/save/fan-out).
import XCTest

@testable import OstMacCore

private struct DeviceCall: Sendable {
    let url: String
    let body: String
}

private final class StubDeviceFetcher: TokenRefreshFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [DeviceCall] = []
    var handler: @Sendable (URL, Data) -> TokenHTTPResponse

    init(handler: @escaping @Sendable (URL, Data) -> TokenHTTPResponse) {
        self.handler = handler
    }

    func post(url: URL, headers _: [String: String], body: Data) async throws
        -> TokenHTTPResponse
    {
        lock.withLock {
            calls.append(DeviceCall(
                url: url.absoluteString,
                body: String(data: body, encoding: .utf8) ?? ""
            ))
        }
        return handler(url, body)
    }
}

private struct ThrowingDeviceFetcher: TokenRefreshFetcher {
    func post(url _: URL, headers _: [String: String], body _: Data) async throws
        -> TokenHTTPResponse
    {
        throw TokenRefreshError.network("boom")
    }
}

private struct FailingDeviceStore: TokenStore {
    func load(profile _: String) -> TokenSlots { TokenSlots() }
    func save(_: TokenSlots, profile _: String) throws {
        throw TokenRefreshError.persist("disk gone")
    }
    func clear(profile _: String) throws {}
    func status(profile _: String) -> StatusResponse {
        TokenStatus.summarize(TokenSlots(), now: 0)
    }
}

final class FfiLaterB18Tests: XCTestCase {
    private var now: UInt64 = 1_700_000_000

    private func clock() -> UInt64 { now }

    private func json(_ s: String) -> TokenHTTPResponse {
        TokenHTTPResponse(status: 200, data: Data(s.utf8))
    }

    private func startBody(
        deviceCode: String = "dc-code-1",
        extra: String = "",
        omit: Set<String> = []
    ) -> String {
        var parts = [
            "\"device_code\": \"\(deviceCode)\"",
            "\"user_code\": \"ABCD-1234\"",
            "\"verification_uri\": \"https://microsoft.com/devicelogin\"",
            "\"message\": \"open the page\"",
            "\"expires_in\": 900",
            "\"interval\": 5",
        ]
        parts = parts.filter { part in
            !omit.contains(where: { part.contains("\"" + $0 + "\"") })
        }
        if !extra.isEmpty { parts.append(extra) }
        return "{" + parts.joined(separator: ", ") + "}"
    }

    private func start(
        profile: String = "b18",
        store: any TokenStore,
        fetcher: any TokenRefreshFetcher
    ) async throws -> DeviceStart {
        try await DeviceAuth.deviceStart(
            profile: profile, store: store, fetcher: fetcher,
            now: { [self] in self.clock() }
        )
    }

    private func poll(
        session: String,
        store: any TokenStore,
        fetcher: any TokenRefreshFetcher
    ) async throws -> DevicePoll {
        try await DeviceAuth.devicePoll(
            session: session, store: store, fetcher: fetcher,
            now: { [self] in self.clock() }
        )
    }

    private func failedMessage(_ error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return "WRONG-TYPE: \(error)"
    }

    // MARK: - Start

    func testStartPostsFormAndParses() async throws {
        let store = MemoryTokenStore()
        let fetcher = StubDeviceFetcher { [self] _, _ in self.json(self.startBody()) }
        let d = try await start(store: store, fetcher: fetcher)
        XCTAssertTrue(d.ok)
        XCTAssertTrue(d.session.hasPrefix("dc-1700000000-"))
        XCTAssertEqual(d.user_code, "ABCD-1234")
        XCTAssertEqual(
            d.verification_uri, "https://microsoft.com/devicelogin"
        )
        XCTAssertEqual(d.message, "open the page")
        XCTAssertEqual(d.expires_in, 900)
        XCTAssertEqual(d.interval, 5)
        XCTAssertEqual(fetcher.calls.count, 1)
        XCTAssertEqual(fetcher.calls[0].url, AuthEndpoints.deviceCodeURL)
        // Form params pinned (Rust `.form(&[client_id, scope])`).
        let form = fetcher.calls[0].body
        XCTAssertTrue(form.contains("client_id=1fec8e78-bce4-4aaf-ab1b-5451cc387264"))
        XCTAssertTrue(form.contains("scope="))
        XCTAssertTrue(form.contains("api.spaces.skype.com"))
        XCTAssertTrue(form.contains("offline_access"))
        DeviceAuth.Sessions.drop(profile: "b18")
    }

    func testStartDefaultsExpiryAndInterval() async throws {
        let store = MemoryTokenStore()
        let fetcher = StubDeviceFetcher { [self] _, _ in
            self.json(self.startBody(omit: ["expires_in", "interval"]))
        }
        let d = try await start(profile: "b18-def", store: store, fetcher: fetcher)
        XCTAssertEqual(d.expires_in, 900)
        XCTAssertEqual(d.interval, 5)
        DeviceAuth.Sessions.drop(profile: "b18-def")
    }

    func testStartMissingKeyIsFatal() async throws {
        let store = MemoryTokenStore()
        let fetcher = StubDeviceFetcher { [self] _, _ in
            self.json(self.startBody(omit: ["device_code"]))
        }
        do {
            _ = try await start(profile: "b18-miss", store: store, fetcher: fetcher)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(
                failedMessage(error),
                "device_start: devicecode missing device_code"
            )
        }
    }

    func testStartNonJSONBodyIsParseError() async throws {
        let store = MemoryTokenStore()
        let fetcher = StubDeviceFetcher { _, _ in
            TokenHTTPResponse(status: 500, data: Data("oops".utf8))
        }
        do {
            _ = try await start(profile: "b18-parse", store: store, fetcher: fetcher)
            XCTFail("expected throw")
        } catch {
            // Parse checked before status (Rust order).
            XCTAssertTrue(failedMessage(error).contains("devicecode parse"))
        }
    }

    func testStartHTTPErrorCarriesStatusAndBody() async throws {
        let store = MemoryTokenStore()
        let fetcher = StubDeviceFetcher { _, _ in
            TokenHTTPResponse(status: 400, data: Data("{\"error\":\"x\"}".utf8))
        }
        do {
            _ = try await start(profile: "b18-http", store: store, fetcher: fetcher)
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(failedMessage(error).contains("devicecode http 400"))
        }
    }

    func testStartTransportError() async throws {
        let store = MemoryTokenStore()
        do {
            _ = try await start(
                profile: "b18-net", store: store,
                fetcher: ThrowingDeviceFetcher()
            )
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(failedMessage(error).contains("devicecode request"))
        }
    }

    func testDeviceScopeMatchesRust() {
        // Copied from rust/ost/src/auth/mod.rs `AuthConfig::work().scope`.
        XCTAssertEqual(
            AuthEndpoints.deviceCodeScope,
            "https://api.spaces.skype.com/.default offline_access"
        )
    }

    // MARK: - Poll: unknown + expiry (ports the Rust R-arg test)

    func testPollUnknownSessionIsError() async throws {
        let store = MemoryTokenStore()
        let fetcher = StubDeviceFetcher { _, _ in self.json("{}") }
        do {
            _ = try await poll(
                session: "dc-nope", store: store, fetcher: fetcher
            )
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(
                failedMessage(error),
                "no_session: unknown or finished session"
            )
        }
        XCTAssertEqual(fetcher.calls.count, 0)
    }

    func testPollExpiredDropsSession() async throws {
        let store = MemoryTokenStore()
        let fetcher = StubDeviceFetcher { [self] _, _ in
            // Omit the default 900: a duplicate key would keep FIRST (900)
            // under JSONSerialization (serde_json keeps last) — invalid
            // fixture. Single expires_in: 10 intended.
            self.json(self.startBody(
                extra: "\"expires_in\": 10", omit: ["expires_in"]
            ))
        }
        let d = try await start(profile: "b18-exp", store: store, fetcher: fetcher)
        now += 11
        do {
            _ = try await poll(session: d.session, store: store, fetcher: fetcher)
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(failedMessage(error).hasPrefix("device_expired:"))
        }
        // Session gone: second poll is no_session, not expired.
        do {
            _ = try await poll(session: d.session, store: store, fetcher: fetcher)
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(failedMessage(error).hasPrefix("no_session:"))
        }
    }

    // MARK: - Poll: pending (retryable incl. transport/parse)

    private func pendingStart(
        profile: String, store: any TokenStore, code: String
    ) async throws -> (DeviceStart, StubDeviceFetcher) {
        let fetcher = StubDeviceFetcher { [self] url, _ in
            if url.absoluteString == AuthEndpoints.deviceCodeURL {
                return self.json(self.startBody())
            }
            return self.json("{\"error\": \"\(code)\"}")
        }
        let d = try await start(profile: profile, store: store, fetcher: fetcher)
        return (d, fetcher)
    }

    func testPollPendingKeepsSession() async throws {
        let store = MemoryTokenStore()
        let (d, fetcher) = try await pendingStart(
            profile: "b18-pend", store: store, code: "authorization_pending"
        )
        let p = try await poll(session: d.session, store: store, fetcher: fetcher)
        XCTAssertTrue(p.ok)
        XCTAssertEqual(p.status, "pending")
        XCTAssertEqual(p.interval, 5)
        XCTAssertNil(p.tokens)
        // Still there: second poll also pending.
        let p2 = try await poll(session: d.session, store: store, fetcher: fetcher)
        XCTAssertEqual(p2.status, "pending")
        DeviceAuth.Sessions.drop(profile: "b18-pend")
    }

    func testPollSlowDownIsPending() async throws {
        let store = MemoryTokenStore()
        let (d, fetcher) = try await pendingStart(
            profile: "b18-slow", store: store, code: "slow_down"
        )
        let p = try await poll(session: d.session, store: store, fetcher: fetcher)
        XCTAssertEqual(p.status, "pending")
        DeviceAuth.Sessions.drop(profile: "b18-slow")
    }

    func testPollTransportErrorIsPending() async throws {
        let store = MemoryTokenStore()
        let startFetcher = StubDeviceFetcher { [self] _, _ in
            self.json(self.startBody())
        }
        let d = try await start(
            profile: "b18-tpend", store: store, fetcher: startFetcher
        )
        let p = try await poll(
            session: d.session, store: store,
            fetcher: ThrowingDeviceFetcher()
        )
        XCTAssertEqual(p.status, "pending")
        DeviceAuth.Sessions.drop(profile: "b18-tpend")
    }

    func testPollParseErrorIsPending() async throws {
        let store = MemoryTokenStore()
        let startFetcher = StubDeviceFetcher { [self] _, _ in
            self.json(self.startBody())
        }
        let d = try await start(
            profile: "b18-pjpg", store: store, fetcher: startFetcher
        )
        let badFetcher = StubDeviceFetcher { _, _ in
            TokenHTTPResponse(status: 200, data: Data("nope".utf8))
        }
        let p = try await poll(
            session: d.session, store: store, fetcher: badFetcher
        )
        XCTAssertEqual(p.status, "pending")
        DeviceAuth.Sessions.drop(profile: "b18-pjpg")
    }

    func testPollFatalErrorDropsSession() async throws {
        let store = MemoryTokenStore()
        let (d, fetcher) = try await pendingStart(
            profile: "b18-fatal", store: store, code: "access_denied"
        )
        do {
            _ = try await poll(session: d.session, store: store, fetcher: fetcher)
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(
                failedMessage(error).hasPrefix("device_poll: access_denied:")
            )
        }
        do {
            _ = try await poll(session: d.session, store: store, fetcher: fetcher)
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(failedMessage(error).hasPrefix("no_session:"))
        }
    }

    // MARK: - Poll: complete (save + best-effort fan-out)

    private func completingFetcher(
        refreshToken: String? = "rt-1",
        derivedStatus: Int = 200
    ) -> StubDeviceFetcher {
        StubDeviceFetcher { [self] url, body in
            let s = url.absoluteString
            if s == AuthEndpoints.deviceCodeURL {
                return self.json(self.startBody())
            }
            if s == AuthEndpoints.authzWorkURL {
                if derivedStatus != 200 {
                    return TokenHTTPResponse(status: derivedStatus, data: Data())
                }
                return self.json(
                    "{\"tokens\": {\"skypeToken\": \"sk-1\", \"expiresIn\": 3600}}"
                )
            }
            let form = String(data: body, encoding: .utf8) ?? ""
            if form.contains("grant_type=refresh_token") {
                if derivedStatus != 200 {
                    return TokenHTTPResponse(status: derivedStatus, data: Data())
                }
                return self.json(
                    "{\"access_token\": \"g-1\", \"expires_in\": 3600}"
                )
            }
            // Device poll grant.
            if let rt = refreshToken {
                return self.json(
                    "{\"access_token\": \"aad-1\", \"refresh_token\": \"\(rt)\", \"expires_in\": 3600}"
                )
            }
            return self.json("{\"access_token\": \"aad-1\", \"expires_in\": 3600}")
        }
    }

    func testPollCompleteSavesAndFansOut() async throws {
        let store = MemoryTokenStore()
        let fetcher = completingFetcher()
        let d = try await start(profile: "b18-done", store: store, fetcher: fetcher)
        let p = try await poll(session: d.session, store: store, fetcher: fetcher)
        XCTAssertTrue(p.ok)
        XCTAssertEqual(p.status, "complete")
        XCTAssertNotNil(p.tokens)
        XCTAssertTrue(p.tokens?.aad.present == true)
        XCTAssertTrue(p.tokens?.refresh_present == true)
        let slots = store.load(profile: "b18-done")
        XCTAssertEqual(slots.accessToken?.token, "g-1") // AAD re-granted by fan-out
        XCTAssertEqual(slots.refreshToken, "rt-1")
        XCTAssertEqual(slots.skypeToken?.token, "sk-1")
        XCTAssertNotNil(slots.graphToken)
        XCTAssertNotNil(slots.ic3Token)
        XCTAssertNotNil(slots.recorderToken)
        // Session consumed.
        do {
            _ = try await poll(session: d.session, store: store, fetcher: fetcher)
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(failedMessage(error).hasPrefix("no_session:"))
        }
    }

    func testPollCompleteWithoutRefreshSkipsFanOut() async throws {
        let store = MemoryTokenStore()
        let fetcher = completingFetcher(refreshToken: nil)
        let d = try await start(
            profile: "b18-nort", store: store, fetcher: fetcher
        )
        let p = try await poll(session: d.session, store: store, fetcher: fetcher)
        XCTAssertEqual(p.status, "complete")
        XCTAssertTrue(p.tokens?.refresh_present == false)
        // start + poll only: refresh short-circuits with no RT.
        XCTAssertEqual(fetcher.calls.count, 2)
        let slots = store.load(profile: "b18-nort")
        XCTAssertEqual(slots.accessToken?.token, "aad-1")
        XCTAssertNil(slots.graphToken)
    }

    func testPollCompleteDerivedFailureIsBestEffort() async throws {
        let store = MemoryTokenStore()
        let fetcher = completingFetcher(derivedStatus: 500)
        let d = try await start(
            profile: "b18-be", store: store, fetcher: fetcher
        )
        let p = try await poll(session: d.session, store: store, fetcher: fetcher)
        XCTAssertEqual(p.status, "complete")
        let slots = store.load(profile: "b18-be")
        XCTAssertNotNil(slots.accessToken)
        XCTAssertEqual(slots.refreshToken, "rt-1")
        XCTAssertNil(slots.graphToken)
    }

    func testPollCompleteSaveFailureIsLoud() async throws {
        let store = FailingDeviceStore()
        let fetcher = completingFetcher()
        let ms = MemoryTokenStore()
        // Start against memory (start ignores the store), complete fails save.
        let d = try await start(profile: "b18-save", store: ms, fetcher: fetcher)
        do {
            _ = try await poll(session: d.session, store: store, fetcher: fetcher)
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(failedMessage(error).hasPrefix("token_save:"))
        }
        DeviceAuth.Sessions.drop(profile: "b18-save")
    }

    // MARK: - Sign-out drop

    func testDropProfileKeepsOthers() async throws {
        let store = MemoryTokenStore()
        let mk = { (profile: String) async throws -> DeviceStart in
            let f = StubDeviceFetcher { [self] _, _ in
                self.json(self.startBody())
            }
            return try await self.start(profile: profile, store: store, fetcher: f)
        }
        let a = try await mk("b18-drop-a")
        let b = try await mk("b18-drop-b")
        DeviceAuth.Sessions.drop(profile: "b18-drop-a")
        let fetcher = StubDeviceFetcher { [self] _, _ in
            self.json("{\"error\": \"authorization_pending\"}")
        }
        do {
            _ = try await poll(session: a.session, store: store, fetcher: fetcher)
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(failedMessage(error).hasPrefix("no_session:"))
        }
        let p = try await poll(session: b.session, store: store, fetcher: fetcher)
        XCTAssertEqual(p.status, "pending")
        DeviceAuth.Sessions.drop(profile: "b18-drop-b")
    }
}
