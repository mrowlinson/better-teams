// StealIdsTests.swift — om-steal-ids lane: MRI parse + resolve envelope,
// sender_id realtime field, presence MRI refresh, token health verdicts.
// All fetchers mocked (no core, no network).
import XCTest

@testable import OstMacCore

private final class CountBox: @unchecked Sendable {
    var resolves = 0
    var fetches = 0
}

@MainActor
final class StealIdsTests: XCTestCase {
    // MARK: - Fixtures

    nonisolated static func status(
        aad: (Bool, Bool) = (false, false),
        graph: (Bool, Bool) = (false, false),
        ic3: (Bool, Bool) = (false, false),
        recorder: (Bool, Bool) = (false, false),
        skype: (Bool, Bool) = (false, false),
        refresh: Bool = false
    ) -> StatusResponse {
        func slot(_ s: (Bool, Bool)) -> String {
            "{\"present\":\(s.0),\"expired\":\(s.1)}"
        }
        let json = "{\"ok\":true,\"signed_in\":\(aad.0 && !aad.1),\"tokens\":" +
            "{\"aad\":\(slot(aad)),\"refresh_present\":\(refresh)," +
            "\"graph\":\(slot(graph)),\"ic3\":\(slot(ic3))," +
            "\"recorder\":\(slot(recorder)),\"skype\":\(slot(skype))," +
            "\"region_gtms_present\":false}}"
        return try! decodeOrThrow(StatusResponse.self, from: Data(json.utf8))
    }

    nonisolated static func me(mail: String? = "a@x.example") -> WhoamiResponse {
        let m = mail.map { "\"\($0)\"" } ?? "null"
        let json = "{\"ok\":true,\"id\":\"gid-1\",\"display_name\":\"Doe, Jane\",\"mail\":\(m)}"
        return try! decodeOrThrow(WhoamiResponse.self, from: Data(json.utf8))
    }

    // MARK: - MRI helpers

    func testOidParsesOrgidOnly() {
        XCTAssertEqual(Mri.oid(from: "8:orgid:abc-123"), "abc-123")
        XCTAssertEqual(Mri.oid(from: "8:orgid:x"), "x")
        for bad in ["", "8:orgid:", "8:orgid:a b", "8:orgid:a/b",
                    "8:skypeids:aaa", "19:t@thread.v2", "user@x.example"]
        {
            XCTAssertNil(Mri.oid(from: bad), bad)
        }
    }

    func testIsMriIsBroadIsResolvableIsNarrow() {
        XCTAssertTrue(Mri.isMri("8:orgid:aaa"))
        XCTAssertTrue(Mri.isMri("8:skypeids:aaa"))
        XCTAssertFalse(Mri.isMri("Doe, Jane"))
        XCTAssertTrue(Mri.isResolvable("8:orgid:aaa"))
        XCTAssertFalse(Mri.isResolvable("8:skypeids:aaa"))
    }

    func testResolveEnvelopeDecodes() throws {
        let data = """
        {"ok":true,"id":"gid-1","email":"a@x.example","display_name":"Doe, Jane"}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(ResolveMriResponse.self, from: data)
        XCTAssertEqual(r.id, "gid-1")
        XCTAssertEqual(r.email, "a@x.example")
        XCTAssertEqual(r.display_name, "Doe, Jane")
    }

    func testResolveEnvelopeGuestMailNull() throws {
        let data = """
        {"ok":true,"id":"gid-2","email":null,"display_name":"Guest"}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(ResolveMriResponse.self, from: data)
        XCTAssertNil(r.email)
    }

    // MARK: - Realtime sender_id

    func testRealtimeDecodesSenderID() throws {
        let data = """
        {"chat_id":"19:t","id":"m1","sender":"Doe, Jane","sender_id":"8:orgid:aaa",
         "text":"hi","time":"2026-09-22T10:00:00Z","is_edit":false}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(RealtimeMessage.self, from: data)
        XCTAssertEqual(m.senderID, "8:orgid:aaa")
        XCTAssertEqual(m.sender, "Doe, Jane")
    }

    func testRealtimeMissingSenderIDIsNil() throws {
        // Old core builds omit the key — must still decode.
        let data = """
        {"chat_id":"19:t","id":"m1","sender":"S",
         "text":"hi","time":"t","is_edit":false}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(RealtimeMessage.self, from: data)
        XCTAssertNil(m.senderID)
    }

    // MARK: - Presence MRI refresh

    func testRefreshChatPeerMriResolvesAndPins() async {
        let box = CountBox()
        let store = PresenceStore(
            userFetcher: { id in
                box.fetches += 1
                XCTAssertEqual(id, "gid-9")
                return UserPresenceResponse(ok: true, id: id, availability: "Busy", activity: "InACall")
            },
            resolveFetcher: { mri in
                box.resolves += 1
                XCTAssertEqual(mri, "8:orgid:aaa")
                return ResolveMriResponse(ok: true, id: "gid-9", email: nil, display_name: "Doe, Jane")
            })
        await store.refreshChatPeerMri(chatID: "19:t", mri: "8:orgid:aaa")
        XCTAssertEqual(store.availabilityForChat("19:t"), "Busy")
        XCTAssertEqual(store.peers["gid-9"]?.activity, "InACall")
        XCTAssertEqual(store.mriByChat["19:t"], "8:orgid:aaa")
        XCTAssertEqual(store.resolved["8:orgid:aaa"]?.id, "gid-9")
        XCTAssertNil(store.error)
    }

    func testRefreshChatPeerMriCachesResolveAcrossChats() async {
        let box = CountBox()
        let store = PresenceStore(
            userFetcher: { id in
                box.fetches += 1
                return UserPresenceResponse(ok: true, id: id, availability: "Available", activity: "Available")
            },
            resolveFetcher: { _ in
                box.resolves += 1
                return ResolveMriResponse(ok: true, id: "gid-9", email: nil, display_name: "D")
            })
        await store.refreshChatPeerMri(chatID: "19:a", mri: "8:orgid:aaa")
        await store.refreshChatPeerMri(chatID: "19:b", mri: "8:orgid:aaa")
        XCTAssertEqual(box.resolves, 1) // one resolve per mate
        XCTAssertEqual(box.fetches, 2) // but one presence fetch per chat
        XCTAssertEqual(store.availabilityForChat("19:b"), "Available")
    }

    func testRefreshChatPeerMriThrottlesSameChat() async {
        let box = CountBox()
        let store = PresenceStore(
            userFetcher: { id in
                box.fetches += 1
                return UserPresenceResponse(ok: true, id: id, availability: "Busy", activity: "x")
            },
            resolveFetcher: { _ in
                box.resolves += 1
                return ResolveMriResponse(ok: true, id: "gid-9", email: nil, display_name: "D")
            })
        await store.refreshChatPeerMri(chatID: "19:t", mri: "8:orgid:aaa")
        await store.refreshChatPeerMri(chatID: "19:t", mri: "8:orgid:aaa")
        XCTAssertEqual(box.resolves, 1)
        XCTAssertEqual(box.fetches, 1)
        store.resolveThrottle = 0 // window elapsed → refetch (resolve cached)
        await store.refreshChatPeerMri(chatID: "19:t", mri: "8:orgid:aaa")
        XCTAssertEqual(box.resolves, 1)
        XCTAssertEqual(box.fetches, 2)
    }

    func testRefreshChatPeerMriIgnoresNonOrgid() async {
        let box = CountBox()
        let store = PresenceStore(
            userFetcher: { _ in
                box.fetches += 1
                throw CoreCallError.failed("must not fetch")
            },
            resolveFetcher: { _ in
                box.resolves += 1
                throw CoreCallError.failed("must not resolve")
            })
        await store.refreshChatPeerMri(chatID: "19:t", mri: "Doe, Jane")
        await store.refreshChatPeerMri(chatID: "19:t", mri: "8:skypeids:aaa")
        XCTAssertEqual(box.resolves, 0)
        XCTAssertEqual(box.fetches, 0)
        XCTAssertNil(store.availabilityForChat("19:t"))
        XCTAssertNil(store.error)
    }

    func testRefreshChatPeerMriFailureKeepsStale() async {
        struct Boom: Error {}
        let store = PresenceStore(
            resolveFetcher: { _ in throw Boom() })
        store.adoptChatPeer(
            chatID: "19:t",
            response: UserPresenceResponse(ok: true, id: "u", availability: "Busy", activity: "x"))
        await store.refreshChatPeerMri(chatID: "19:t", mri: "8:orgid:aaa")
        XCTAssertEqual(store.availabilityForChat("19:t"), "Busy") // stale kept
        XCTAssertNotNil(store.error)
    }

    func testClearDropsResolvedCaches() {
        let store = PresenceStore()
        store.adoptResolved(
            mri: "8:orgid:aaa",
            response: ResolveMriResponse(ok: true, id: "u", email: nil, display_name: "D"))
        store.clear()
        XCTAssertTrue(store.resolved.isEmpty)
        XCTAssertTrue(store.mriByChat.isEmpty)
    }

    // MARK: - Health

    func testTokenSlotsMapStatus() {
        let st = Self.status(aad: (true, false), graph: (true, true), refresh: true)
        let slots = HealthStore.tokenSlots(st)
        XCTAssertEqual(slots.count, 6)
        XCTAssertEqual(slots[0], HealthToken(audience: "aad", present: true, expired: false))
        XCTAssertEqual(slots[1].state, "expired")
        XCTAssertEqual(slots[4].state, "missing") // skype absent
        XCTAssertEqual(slots[5], HealthToken(audience: "refresh", present: true, expired: false))
    }

    func testVerdictMatrix() {
        func probe(_ ok: Bool) -> HealthProbe {
            HealthProbe(name: "p", ok: ok, detail: "d", durationMs: 1)
        }
        let fresh = [HealthToken(audience: "aad", present: true, expired: false)]
        let stale = [HealthToken(audience: "aad", present: true, expired: true)]
        XCTAssertEqual(HealthStore.verdict(tokens: fresh, probes: [probe(true), probe(true)]), .ok)
        XCTAssertEqual(HealthStore.verdict(tokens: fresh, probes: [probe(true), probe(false)]), .degraded)
        XCTAssertEqual(HealthStore.verdict(tokens: fresh, probes: [probe(false), probe(false)]), .broken)
        // Fresh probes but a stale token cap at degraded.
        XCTAssertEqual(HealthStore.verdict(tokens: stale, probes: [probe(true)]), .degraded)
        // Broken probes stay broken even with fresh tokens.
        XCTAssertEqual(HealthStore.verdict(tokens: fresh, probes: [probe(false)]), .broken)
    }

    func testRunAllGreen() async {
        let store = HealthStore(
            statusFetcher: { Self.status(
                aad: (true, false), graph: (true, false), ic3: (true, false),
                recorder: (true, false), skype: (true, false), refresh: true) },
            meFetcher: { Self.me() },
            teamsFetcher: { TeamsResponse(ok: true, teams: []) },
            chatsFetcher: { _ in ChatsResponse(ok: true, chats: []) })
        await store.run()
        XCTAssertEqual(store.report?.overall, .ok)
        XCTAssertEqual(store.report?.probes.count, 3)
        XCTAssertTrue(store.report?.probes.allSatisfy(\.ok) ?? false)
        XCTAssertEqual(store.report?.accountUPN, "a@x.example")
        XCTAssertNil(store.error)
        XCTAssertFalse(store.running)
    }

    func testRunProbeFailureDegrades() async {
        struct Boom: Error {}
        let store = HealthStore(
            statusFetcher: { Self.status(
                aad: (true, false), graph: (true, false), ic3: (true, false),
                recorder: (true, false), skype: (true, false), refresh: true) },
            meFetcher: { Self.me() },
            teamsFetcher: { throw Boom() },
            chatsFetcher: { _ in ChatsResponse(ok: true, chats: []) })
        await store.run()
        XCTAssertEqual(store.report?.overall, .degraded)
        XCTAssertEqual(store.report?.probes[1].name, "graph_joined_teams")
        XCTAssertFalse(store.report?.probes[1].ok ?? true)
        XCTAssertNil(store.error) // probe failure lands in the report
    }

    func testProbeDetailUnwrapsCoreError() async {
        let store = HealthStore(
            statusFetcher: { Self.status(aad: (true, false), refresh: true) },
            meFetcher: { throw CoreCallError.failed("whoami: no auth") },
            teamsFetcher: { TeamsResponse(ok: true, teams: []) },
            chatsFetcher: { _ in ChatsResponse(ok: true, chats: []) })
        await store.run()
        // No `failed("…")` wrapper in diagnostics output.
        XCTAssertEqual(store.report?.probes[0].detail, "whoami: no auth")
        XCTAssertEqual(store.report?.overall, .degraded)
    }

    func testRunAllProbesFailBroken() async {
        struct Boom: Error {}
        let store = HealthStore(
            statusFetcher: { Self.status() },
            meFetcher: { throw Boom() },
            teamsFetcher: { throw Boom() },
            chatsFetcher: { _ in throw Boom() })
        await store.run()
        XCTAssertEqual(store.report?.overall, .broken)
        XCTAssertNil(store.report?.accountUPN)
    }

    func testRunStatusFailureSetsError() async {
        struct Boom: Error {}
        let store = HealthStore(
            statusFetcher: { throw Boom() },
            meFetcher: { Self.me() },
            teamsFetcher: { TeamsResponse(ok: true, teams: []) },
            chatsFetcher: { _ in ChatsResponse(ok: true, chats: []) })
        await store.run()
        XCTAssertNil(store.report)
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.running)
    }

    func testDemoReportIsDegraded() {
        XCTAssertEqual(HealthStore.demo.overall, .degraded)
        XCTAssertEqual(HealthStore.demo.tokens.count, 6)
        XCTAssertEqual(HealthStore.demo.probes.count, 3)
    }
}
