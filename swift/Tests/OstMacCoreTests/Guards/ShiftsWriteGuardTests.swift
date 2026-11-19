// ShiftsWriteGuardTests.swift — shifts-write lane guards: the host-side
// manager gate, request ordering, and scope-pending mapping. Member
// ops (swap/offer/time-off requests) stay open to every roster member;
// manager ops (decide, shift CRUD, publish) throw for non-managers
// before any writer runs. No network (in-memory writer only).
import XCTest

@testable import OstMacCore

@MainActor
final class ShiftsWriteGuardTests: XCTestCase {
    /// Failing writer: any call is a gate failure (the gate must throw
    /// first). Records calls for the manager-happy-path tests.
    nonisolated static func failingWriter() -> ShiftsWriter {
        func fail<T>(_ what: String) throws -> T {
            throw CoreCallError.failed("writer ran (\(what)): gate missing")
        }
        return ShiftsWriter(
            fetchRequests: { _, _ in try fail("fetch") },
            swapCreate: { _, _, _, _ in try fail("swap") },
            offerCreate: { _, _, _, _ in try fail("offer") },
            timeOffRequestCreate: { _, _, _, _, _ in try fail("timeoff-request") },
            decide: { _, _, _, _, _ in try fail("decide") },
            shiftCreate: { _, _, _, _, _, _, _ in try fail("shift-create") },
            shiftUpdate: { _, _, _, _, _, _, _ in try fail("shift-update") },
            shiftDelete: { _, _ in try fail("shift-delete") },
            timeOffCreate: { _, _, _, _, _ in try fail("timeoff-create") },
            share: { _, _, _, _ in try fail("share") })
    }

    nonisolated static func teamResponse() -> ShiftWeekResponse {
        ShiftsDemo.response(teamID: "team-1")
    }

    /// Roster where u-owner owns, u-worker does not.
    nonisolated static func roster() -> TeamMembersResponse {
        TeamMembersResponse(ok: true, teamId: "team-1", members: [
            TeamMember(id: "m-owner", displayName: "Owner", userId: "u-owner",
                       roles: ["owner"], isOwner: true),
            TeamMember(id: "m-worker", displayName: "Worker", userId: "u-worker",
                       roles: [], isOwner: false),
        ])
    }

    func store(writer: ShiftsWriter = failingWriter()) -> ShiftsStore {
        ShiftsStore(week: { _ in Self.teamResponse() },
                    members: { _ in Self.roster() },
                    writer: writer)
    }

    func waitFor(_ what: String, _ cond: @escaping () -> Bool) async throws {
        if try await TestWait.untilThrowing({ cond() }) { return }
        XCTFail("timed out waiting for \(what)")
    }

    func openTeam(_ s: ShiftsStore) async throws {
        s.setTeams([ShiftTeam(id: "team-1", name: "Store")])
        s.open(teamID: "team-1")
        try await waitFor("loaded") { s.state == .loaded }
    }

    // MARK: manager gate

    func testGateClosedUntilRosterAndOwnIDLand() async throws {
        let s = store()
        XCTAssertFalse(s.isManager)
        s.adoptOwn(nil)
        XCTAssertFalse(s.isManager)
        s.adoptOwn("  ")
        XCTAssertFalse(s.isManager)
        // Own id without a roster: still closed.
        s.adoptOwn("u-owner")
        XCTAssertFalse(s.isManager)
        try await openTeam(s)
        try await waitFor("managers") { !s.managerUserIDs.isEmpty }
        XCTAssertTrue(s.isManager)
    }

    func testNonOwnerIsNeverManager() async throws {
        let s = store()
        s.adoptOwn("u-worker")
        try await openTeam(s)
        try await waitFor("managers") { !s.managerUserIDs.isEmpty }
        XCTAssertFalse(s.isManager)
    }

    func testManagerOpsThrowForNonManagersBeforeAnyWriter() async throws {
        let s = store()
        s.adoptOwn("u-worker")
        try await openTeam(s)
        try await waitFor("managers") { !s.managerUserIDs.isEmpty }
        let req = ShiftChangeRequest(id: "q1", kind: "swap", state: "pending")
        await expectThrow("decide", { try await s.decideRequest(req, approve: true) }) { error in
            XCTAssertTrue(String(describing: error).contains("team owners"))
        }
        await expectThrow("create", {
            try await s.createShift(start: "2026-11-24T09:00:00", end: "2026-11-24T17:00:00")
        })
        await expectThrow("update", { try await s.updateShift(shiftID: "s1") })
        await expectThrow("delete", { try await s.deleteShift(shiftID: "s1") })
        await expectThrow("timeoff", {
            try await s.createTimeOff(userID: "u-worker", reasonID: "r1",
                                      start: "2026-11-24T09:00:00", end: "2026-11-24T17:00:00")
        })
        await expectThrow("share", { try await s.publishDrafts(notifyTeam: false) })
    }

    /// Async throw assertion with an error handler (XCTest has none).
    func expectThrow(_ what: String, _ work: () async throws -> Void,
                     _ handler: (Error) -> Void = { _ in }) async {
        do {
            try await work()
            XCTFail("expected throw (\(what))")
        } catch {
            handler(error)
        }
    }

    // MARK: member ops stay open

    func testMemberRequestOpsRunWithoutManagerRank() async throws {
        var created: [String] = []
        var writer = Self.failingWriter()
        writer.swapCreate = { _, sender, _, _ in created.append(sender); return "q-swap" }
        writer.timeOffRequestCreate = { _, reason, _, _, _ in created.append(reason); return "q-off" }
        let s = store(writer: writer)
        s.adoptOwn("u-worker")
        try await openTeam(s)
        try await waitFor("managers") { !s.managerUserIDs.isEmpty }
        XCTAssertFalse(s.isManager)
        let sid = try await s.createSwapRequest(shiftID: "s1")
        XCTAssertEqual(sid, "q-swap")
        let tid = try await s.createTimeOffRequest(reasonID: "r1",
                                                   start: "2026-12-24T00:00:00",
                                                   end: "2026-12-26T00:00:00")
        XCTAssertEqual(tid, "q-off")
        XCTAssertEqual(created, ["s1", "r1"])
    }

    // MARK: requests ordering + scope mapping

    func testPendingSortsFirst() {
        let rs = [
            ShiftChangeRequest(id: "a", kind: "swap", state: "approved"),
            ShiftChangeRequest(id: "b", kind: "timeoff", state: "pending"),
            ShiftChangeRequest(id: "c", kind: "offer", state: "declined"),
        ]
        let s = store()
        XCTAssertEqual(rs.filter(\.isPending).map(\.id), ["b"])
        XCTAssertEqual(s.pendingRequests, [])
    }

    func testScopeFailureMapsToScopePendingLine() async throws {
        var writer = Self.failingWriter()
        writer.fetchRequests = { _, _ in
            throw CoreCallError.failed("schedule_requests: HTTP 403 for https://x: " +
                "{\"error\":{\"message\":\"Missing scope permissions. API requires Schedule.ReadWrite.All\"}}")
        }
        let s = store(writer: writer)
        try await openTeam(s)
        try await waitFor("requests-error") { s.requestsError != nil }
        XCTAssertEqual(s.requestsError, ShiftsWriter.scopePendingMessage)
        XCTAssertTrue(s.requests.isEmpty)
        XCTAssertTrue(isShiftScopeError(CoreCallError.failed("needs Schedule.ReadWrite.All")))
        XCTAssertFalse(isShiftScopeError(CoreCallError.failed("HTTP 404")))
    }

    func testLoadedRequestsLandPendingFirst() async throws {
        var writer = Self.failingWriter()
        writer.fetchRequests = { _, kind in
            switch kind {
            case "swap": return [ShiftChangeRequest(id: "s1", kind: "swap", state: "approved")]
            case "offer": return []
            default: return [ShiftChangeRequest(id: "t1", kind: "timeoff", state: "pending")]
            }
        }
        let s = store(writer: writer)
        try await openTeam(s)
        try await waitFor("requests") { s.requests.count == 2 }
        XCTAssertNil(s.requestsError)
        XCTAssertEqual(s.requests.map(\.id), ["t1", "s1"])
        XCTAssertEqual(s.pendingRequests.map(\.id), ["t1"])
    }

    // MARK: hasDrafts

    func testManagerDraftsShowTheRequestsArea() async throws {
        var writer = Self.failingWriter()
        writer.fetchRequests = { _, _ in [] }
        let s = store(writer: writer)
        s.adoptOwn("u-owner")
        try await openTeam(s)
        try await waitFor("managers") { !s.managerUserIDs.isEmpty }
        XCTAssertTrue(s.isManager)
        // Demo week ships one draft shift (nathan-sun).
        XCTAssertTrue(s.hasDrafts)
        XCTAssertTrue(s.showsRequestsArea)
    }
}
