// ShiftsTests.swift — om-shifts lane: wire decode, bucketing, store open.
import XCTest

@testable import OstMacCore

@MainActor
final class ShiftsTests: XCTestCase {
    nonisolated static func weekJSON() -> ShiftWeekResponse {
        let json = """
            {"ok":true,"team_id":"team-1",\
            "schedule":{"enabled":true,"time_zone":"America/New_York",\
            "provision_status":"Completed"},\
            "shifts":[\
            {"id":"s1","user_id":"u1","display_name":"Morning",\
            "start":"2026-09-28T09:00:00","end":"2026-09-28T17:00:00",\
            "theme":"blue","notes":null,"is_draft":false},\
            {"id":"s2","user_id":"u2","display_name":"Night",\
            "start":"2026-09-29T21:00:00","end":"2026-09-30T05:00:00",\
            "theme":null,"notes":null,"is_draft":true}],\
            "times_off":[\
            {"id":"o1","user_id":"u1","reason_id":"r1",\
            "start":"2026-09-30T00:00:00","end":"2026-10-01T00:00:00",\
            "is_draft":false}],\
            "reasons":[\
            {"id":"r1","name":"Vacation","code":"V"},\
            {"id":"r2","name":"Sick","code":null}]}
            """
        return try! decodeOrThrow(ShiftWeekResponse.self, from: Data(json.utf8))
    }

    nonisolated static func weekStart() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal.date(from: DateComponents(
            year: 2026, month: 9, day: 28, hour: 0, minute: 0))!
    }

    func waitFor(_ what: String, _ cond: @escaping () -> Bool) async throws {
        if try await TestWait.untilThrowing({ cond() }) { return }
        XCTFail("timed out waiting for \(what)")
    }

    func testDecodeWeek() {
        let response = Self.weekJSON()
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.team_id, "team-1")
        XCTAssertTrue(response.schedule.enabled)
        XCTAssertEqual(response.schedule.timeZone, "America/New_York")
        XCTAssertEqual(response.shifts.count, 2)
        XCTAssertEqual(response.shifts[0].displayName, "Morning")
        XCTAssertEqual(response.shifts[0].theme, "blue")
        XCTAssertTrue(response.shifts[1].isDraft)
        XCTAssertEqual(response.timesOff.count, 1)
        XCTAssertEqual(response.reasons.count, 2)
        XCTAssertEqual(response.reasons[1].name, "Sick")
    }

    func testBucketColumns() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let week = ShiftWeek.build(
            from: Self.weekJSON(), weekStart: Self.weekStart(), calendar: cal)
        XCTAssertEqual(week.columns.count, 7)
        // s1 Monday -> column 0, s2 Tuesday -> column 1.
        XCTAssertEqual(week.columns[0].map(\.id), ["s1"])
        XCTAssertEqual(week.columns[1].map(\.id), ["s2"])
        for day in 2 ..< 7 {
            XCTAssertTrue(week.columns[day].isEmpty)
        }
    }

    func testOutOfRangeShiftsDropped() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let resp = ShiftWeekResponse(
            ok: true, team_id: "t", schedule: ShiftSchedule(enabled: true),
            shifts: [
                ShiftItem(id: "far", start: "2026-10-20T09:00:00"),
                ShiftItem(id: "bad", start: "not-a-date"),
                ShiftItem(id: "none"),
            ],
            timesOff: [], reasons: [])
        let week = ShiftWeek.build(
            from: resp, weekStart: Self.weekStart(), calendar: cal)
        XCTAssertTrue(week.columns.allSatisfy(\.isEmpty))
    }

    func testBalancesCountApprovedPerReason() {
        let resp = Self.weekJSON()
        let balances = ShiftWeek.balances(
            reasons: resp.reasons, timesOff: resp.timesOff)
        // Only r1 has an approved instance; r2 (zero) is omitted.
        XCTAssertEqual(balances.count, 1)
        XCTAssertEqual(balances[0].reason.id, "r1")
        XCTAssertEqual(balances[0].count, 1)
    }

    func testBalancesSkipDrafts() {
        let reasons = [TimeOffReason(id: "r1", name: "Vacation")]
        let offs = [TimeOffItem(id: "o9", reasonId: "r1", isDraft: true)]
        XCTAssertTrue(ShiftWeek.balances(reasons: reasons, timesOff: offs).isEmpty)
    }

    func testShiftDateParsesOffsetAndBare() {
        XCTAssertNotNil(ShiftItem.parse(dateTime: "2026-09-28T09:00:00"))
        XCTAssertNotNil(ShiftItem.parse(dateTime: "2026-09-28T09:00:00-04:00"))
        XCTAssertNil(ShiftItem.parse(dateTime: nil))
        XCTAssertNil(ShiftItem.parse(dateTime: "nope"))
    }

    func testOpenReplacesWeek() async throws {
        let resp = Self.weekJSON()
        let store = ShiftsStore(week: { _ in resp })
        store.setTeams([ShiftTeam(id: "team-1", name: "Store")])
        store.open(teamID: "team-1")
        try await waitFor("loaded") { store.state == .loaded }
        XCTAssertEqual(store.selectedTeamID, "team-1")
        XCTAssertNotNil(store.week)
        XCTAssertEqual(store.week?.balances.count, 1)
    }

    func testOpenEmptySurfaces() async throws {
        let resp = ShiftWeekResponse(
            ok: true, team_id: "t", schedule: ShiftSchedule(enabled: true),
            shifts: [], timesOff: [], reasons: [])
        let store = ShiftsStore(week: { _ in resp })
        store.open(teamID: "team-9")
        try await waitFor("empty") { store.state == .empty }
        XCTAssertNotNil(store.week)
    }

    func testOpenErrorSurfaces() async throws {
        let store = ShiftsStore(week: { _ in
            throw CoreCallError.failed("nope")
        })
        store.open(teamID: "team-1")
        try await waitFor("error") {
            if case .error = store.state { return true }
            return false
        }
        XCTAssertNil(store.week)
    }

    func testBlankTeamIDResetsIdle() {
        let store = ShiftsStore(week: { _ in Self.weekJSON() })
        store.open(teamID: "   ")
        XCTAssertEqual(store.state, .idle)
        XCTAssertNil(store.week)
    }

    func testShiftsWeekWiredToCore() {
        // Blank ids are rejected by core pre-network (no stub left).
        XCTAssertThrowsError(try RustCore.shiftsWeek(teamID: "   ")) { error in
            guard case CoreCallError.failed(let m) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(m.contains("team_id"))
        }
    }

    // -- shifts-404 lane: fallback + humanized errors --

    /// Realistic core failure: `schedule_week` prefix + Graph URL +
    /// JSON blob (the raw string the old `message(for:)` showed).
    nonisolated static func coreFailed(_ raw: String) -> Error {
        CoreCallError.failed(raw)
    }

    nonisolated static func notFound404(team: String) -> Error {
        coreFailed(
            "schedule_week: HTTP 404 for https://graph.microsoft.com/v1.0/teams/\(team)/schedule: "
                + "{\"error\":{\"code\":\"TeamNotFound\",\"message\":\"Team not found.\"}}")
    }

    func testFallbackSkips404TeamsInPickerOrder() async throws {
        let log = ShiftsFetchLog()
        let resp = Self.weekJSON()
        let store = ShiftsStore(week: { id in
            log.record(id)
            if id == "team-c" { return resp }
            throw Self.notFound404(team: id)
        })
        store.setTeams([
            ShiftTeam(id: "team-a", name: "Alpha"),
            ShiftTeam(id: "team-b", name: "Beta"),
            ShiftTeam(id: "team-c", name: "Gamma"),
        ])
        store.open(teamID: "team-a")
        try await waitFor("loaded") { store.state == .loaded }
        // Fetched together (bounded), so arrival order is free.
        XCTAssertEqual(log.all.sorted(), ["team-a", "team-b", "team-c"])
        XCTAssertEqual(store.selectedTeamID, "team-c")
        XCTAssertNotNil(store.week)
        XCTAssertNil(store.loadProgress)
    }

    func testFallbackFromMiddleStartsThere() async throws {
        let log = ShiftsFetchLog()
        let resp = Self.weekJSON()
        let store = ShiftsStore(week: { id in
            log.record(id)
            if id == "team-a" { return resp }
            throw Self.notFound404(team: id)
        })
        store.setTeams([
            ShiftTeam(id: "team-a", name: "Alpha"),
            ShiftTeam(id: "team-b", name: "Beta"),
        ])
        store.open(teamID: "team-b")
        try await waitFor("loaded") { store.state == .loaded }
        // Requested first, then the rest of the picker.
        XCTAssertEqual(log.all.sorted(), ["team-a", "team-b"])
        XCTAssertEqual(store.selectedTeamID, "team-a")
    }

    func testAll404LandsUnavailable() async throws {
        let log = ShiftsFetchLog()
        let store = ShiftsStore(week: { id in
            log.record(id)
            throw Self.notFound404(team: id)
        })
        store.setTeams([
            ShiftTeam(id: "team-a", name: "Alpha"),
            ShiftTeam(id: "team-b", name: "Beta"),
        ])
        store.open(teamID: "team-a")
        try await waitFor("unavailable") {
            if case .unavailable = store.state { return true }
            return false
        }
        // Bounded: one pass, each team tried once.
        XCTAssertEqual(log.all.sorted(), ["team-a", "team-b"])
        guard case .unavailable(let message) = store.state else {
            return XCTFail("wrong state: \(store.state)")
        }
        XCTAssertTrue(message.contains("None of your teams use Shifts"))
        XCTAssertFalse(message.contains("{"))
        XCTAssertNil(store.week)
        // Retry reruns the full chain from the requested team.
        XCTAssertEqual(store.selectedTeamID, "team-a")
    }

    /// Error only when no team has a week: a 404, a sign-in failure
    /// and another 404 land the sign-in failure (first real failure).
    func testErrorOnlyWhenEveryTeamFails() async throws {
        let log = ShiftsFetchLog()
        let store = ShiftsStore(week: { id in
            log.record(id)
            if id == "team-b" {
                throw Self.coreFailed("401 Unauthorized for https://graph.microsoft.com/v1.0/teams/x.")
            }
            throw Self.notFound404(team: id)
        })
        store.setTeams([
            ShiftTeam(id: "team-a", name: "Alpha"),
            ShiftTeam(id: "team-b", name: "Beta"),
            ShiftTeam(id: "team-c", name: "Gamma"),
        ])
        store.open(teamID: "team-a")
        try await waitFor("error") {
            if case .error = store.state { return true }
            return false
        }
        XCTAssertEqual(log.all.sorted(), ["team-a", "team-b", "team-c"])
        guard case .error(let message) = store.state else {
            return XCTFail("wrong state: \(store.state)")
        }
        XCTAssertTrue(message.contains("Sign in again"))
        XCTAssertFalse(message.contains("{"))
        XCTAssertEqual(store.selectedTeamID, "team-b")
        XCTAssertNil(store.loadProgress)
    }

    /// One team's failure no longer hides a later team that has Shifts.
    func testFailingTeamDoesNotHideTeamWithShifts() async throws {
        let resp = Self.weekJSON()
        let store = ShiftsStore(week: { id in
            if id == "team-b" { throw Self.coreFailed("schedule_week: HTTP 500 for https://graph.microsoft.com/x: {}") }
            if id == "team-c" { return resp }
            throw Self.notFound404(team: id)
        })
        store.setTeams([
            ShiftTeam(id: "team-a", name: "Alpha"),
            ShiftTeam(id: "team-b", name: "Beta"),
            ShiftTeam(id: "team-c", name: "Gamma"),
        ])
        store.open(teamID: "team-a")
        try await waitFor("loaded") { store.state == .loaded }
        XCTAssertEqual(store.selectedTeamID, "team-c")
    }

    /// Live 2026-09-28: 8 of 9 teams answer the schedule header with
    /// `enabled:false` (`NotStarted`). Those are skipped like a 404;
    /// all of them disabled lands `.unavailable`.
    func testDisabledScheduleSkipsToTeamWithShifts() async throws {
        let resp = Self.weekJSON()
        let off = ShiftWeekResponse(
            ok: true, team_id: "x",
            schedule: ShiftSchedule(enabled: false, provisionStatus: "NotStarted"),
            shifts: [], timesOff: [], reasons: [])
        let store = ShiftsStore(week: { id in id == "team-c" ? resp : off })
        store.setTeams([
            ShiftTeam(id: "team-a", name: "Alpha"),
            ShiftTeam(id: "team-b", name: "Beta"),
            ShiftTeam(id: "team-c", name: "Gamma"),
        ])
        store.open(teamID: "team-a")
        try await waitFor("loaded") { store.state == .loaded }
        XCTAssertEqual(store.selectedTeamID, "team-c")

        let none = ShiftsStore(week: { _ in off })
        none.setTeams([ShiftTeam(id: "team-a", name: "Alpha"), ShiftTeam(id: "team-b", name: "Beta")])
        none.open(teamID: "team-a")
        try await waitFor("unavailable") {
            if case .unavailable = none.state { return true }
            return false
        }
    }

    /// The requested team still loading holds the pane (a later team's
    /// week never flashes up first); progress counts answered teams;
    /// when it turns out to have no Shifts the next team lands.
    func testRequestedTeamFirstWithProgress() async throws {
        let resp = Self.weekJSON()
        let gate = DispatchSemaphore(value: 0)
        let store = ShiftsStore(week: { id in
            if id == "team-a" {
                gate.wait()
                throw Self.notFound404(team: id)
            }
            if id == "team-b" { return resp }
            throw Self.notFound404(team: id)
        })
        store.setTeams([
            ShiftTeam(id: "team-a", name: "Alpha"),
            ShiftTeam(id: "team-b", name: "Beta"),
            ShiftTeam(id: "team-c", name: "Gamma"),
        ])
        store.open(teamID: "team-a")
        XCTAssertEqual(store.loadProgress, ShiftsLoadProgress(done: 0, total: 3))
        try await waitFor("b and c answered") { store.loadProgress?.done == 2 }
        XCTAssertEqual(store.loadProgress, ShiftsLoadProgress(done: 2, total: 3))
        XCTAssertEqual(store.state, .loading)
        XCTAssertNil(store.week)
        gate.signal()
        try await waitFor("loaded") { store.state == .loaded }
        XCTAssertEqual(store.selectedTeamID, "team-b")
        XCTAssertNil(store.loadProgress)
    }

    /// Picker teams are fetched together, never more than
    /// `maxConcurrentTeams` at once, each once.
    func testPickerFetchIsParallelAndBounded() async throws {
        let meter = ShiftsInFlightMeter()
        let store = ShiftsStore(week: { id in
            meter.enter()
            Thread.sleep(forTimeInterval: 0.05)
            meter.leave()
            throw Self.notFound404(team: id)
        })
        let teams = (1 ... 9).map { ShiftTeam(id: "team-\($0)", name: "T\($0)") }
        store.setTeams(teams)
        store.open(teamID: "team-1")
        try await waitFor("unavailable") {
            if case .unavailable = store.state { return true }
            return false
        }
        XCTAssertEqual(meter.total, 9)
        XCTAssertLessThanOrEqual(meter.peak, ShiftsStore.maxConcurrentTeams)
        XCTAssertGreaterThan(meter.peak, 1)
    }

    func testSingleUnknownTeam404IsError() async throws {
        let store = ShiftsStore(week: { id in
            throw Self.notFound404(team: id)
        })
        store.open(teamID: "team-9")
        try await waitFor("error") {
            if case .error = store.state { return true }
            return false
        }
        guard case .error(let message) = store.state else {
            return XCTFail("wrong state: \(store.state)")
        }
        XCTAssertEqual(message, "This team does not use Shifts or you cannot access it.")
    }

    func testManualSelectOf404TeamFallsForward() async throws {
        let resp = Self.weekJSON()
        let store = ShiftsStore(week: { id in
            if id == "team-b" { return resp }
            throw Self.notFound404(team: id)
        })
        store.setTeams([
            ShiftTeam(id: "team-a", name: "Alpha"),
            ShiftTeam(id: "team-b", name: "Beta"),
        ])
        store.select(teamID: "team-a")
        try await waitFor("loaded") { store.state == .loaded }
        XCTAssertEqual(store.selectedTeamID, "team-b")
    }

    func testPickerStillManualSelectable() async throws {
        let resp = Self.weekJSON()
        let store = ShiftsStore(week: { _ in resp })
        store.setTeams([
            ShiftTeam(id: "team-a", name: "Alpha"),
            ShiftTeam(id: "team-b", name: "Beta"),
        ])
        store.select(teamID: "team-a")
        try await waitFor("loaded") { store.state == .loaded }
        XCTAssertEqual(store.selectedTeamID, "team-a")
        store.select(teamID: "team-b")
        try await waitFor("reselected") { store.selectedTeamID == "team-b" }
        try await waitFor("loaded") { store.state == .loaded }
        XCTAssertNotNil(store.week)
    }

    func testErrorMappingTable() {
        let blob404 = "schedule_week: HTTP 404 for https://graph.microsoft.com/v1.0/teams/x/schedule: "
            + "{\"error\":{\"code\":\"TeamNotFound\",\"message\":\"Team not found.\"}}"
        let rows: [(raw: String, name: String?, want: String)] = [
            (blob404, "Store", "Store does not use Shifts or you cannot access it."),
            (blob404, nil, "This team does not use Shifts or you cannot access it."),
            ("schedule_week: HTTP 404 for https://graph.microsoft.com/x", "A", "A does not use Shifts or you cannot access it."),
            ("401 Unauthorized for https://graph.microsoft.com/v1.0/teams/x.", nil,
             "Your sign-in may have expired. Sign in again, then retry."),
            ("schedule_week: HTTP 403 for https://graph.microsoft.com/x: {\"error\":{}}", nil,
             "Your sign-in may have expired. Sign in again, then retry."),
            ("schedule_week: GET https://graph.microsoft.com/x failed: network connection timed out", nil,
             "Couldn't reach the service. Check your connection, then retry."),
            ("{\"ok\":false,\"error\":\"schedule_week\"}", nil, "Couldn't load shifts. Retry."),
            // Status digits inside a team GUID are not a status.
            ("schedule_week: HTTP 500 for https://graph.microsoft.com/v1.0/teams/1404f03a-4010-4c2e/schedule: {}", nil,
             // NOLOAD: an unexpected 5xx reads as a service hiccup,
             // never the raw core text.
             "Teams is having trouble right now (500). Try again in a moment."),
            ("shifts timed out after 15s", nil,
             "Couldn't reach the service. Check your connection, then retry."),
            ("nope", nil, "nope"),
        ]
        for row in rows {
            let got = ShiftsStore.message(
                for: Self.coreFailed(row.raw), teamName: row.name)
            XCTAssertEqual(got, row.want, "raw: \(row.raw)")
            XCTAssertFalse(got.hasPrefix("{"), "raw: \(row.raw)")
            XCTAssertFalse(got.contains("{"), "raw: \(row.raw)")
            XCTAssertFalse(got.contains("https://"), "raw: \(row.raw)")
        }
        // Non-core errors sanitize the same way (never `{`-led).
        let odd = ShiftsStore.message(for: ShiftsProbeError(), teamName: nil)
        XCTAssertFalse(odd.hasPrefix("{"))
    }

    /// All-404 payload pins: exact user-facing copy, no JSON, no
    /// URL (the browser titles it "None of your teams use Shifts").
    /// The committed `docs/shots/shifts-404-unavailable.png` comes
    /// from `--demo --show-shifts-unavailable` + screencapture
    /// (ContentUnavailableView paints blank under headless
    /// ImageRenderer, so no render test pins pixels).
    func testUnavailableMessageContent() {
        let message = ShiftsStore.allUnavailableMessage()
        XCTAssertTrue(message.contains("None of your teams use Shifts"))
        XCTAssertTrue(message.contains("Pick another team"))
        XCTAssertFalse(message.contains("{"))
        XCTAssertFalse(message.contains("https://"))
    }

    // MARK: - F6: zero-teams seed (never strands .idle)

    func testShowNoTeamsLandsEmptyGuidance() {
        let store = ShiftsStore(week: { _ in Self.weekJSON() })
        store.setTeams([ShiftTeam(id: "team-1", name: "Store")])
        store.showNoTeams()
        XCTAssertEqual(store.state, .empty)
        XCTAssertTrue(store.teams.isEmpty)
        XCTAssertNil(store.selectedTeamID)
        XCTAssertNil(store.week)
    }

    func testShowTeamsErrorSanitizes() {
        let store = ShiftsStore(week: { _ in Self.weekJSON() })
        store.showTeamsError(
            "teams: HTTP 500 for https://graph.microsoft.com/v1.0/teams: {\"error\":{}}")
        guard case .error(let message) = store.state else {
            return XCTFail("expected .error, got \(store.state)")
        }
        XCTAssertFalse(message.contains("{"))
        XCTAssertFalse(message.contains("https://"))
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(store.selectedTeamID)
    }

    func testRefreshWithoutSelectionFiresReloadHook() {
        let store = ShiftsStore(week: { _ in Self.weekJSON() })
        store.showNoTeams()
        var fired = 0
        store.reloadTeams = { fired += 1 }
        store.refresh()
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(store.state, .empty) // unchanged until the host re-seeds
    }

    func testRefreshWithoutSelectionNorHookIsHarmless() {
        let store = ShiftsStore(week: { _ in Self.weekJSON() })
        store.showNoTeams()
        store.refresh() // no hook: stands down, no state churn
        XCTAssertEqual(store.state, .empty)
    }
}

/// Locked fetch log (the store calls the fetcher off-main).
private final class ShiftsFetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []

    func record(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        ids.append(id)
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }
}

/// Peak concurrent fetcher calls (the store calls the fetcher off-main).
private final class ShiftsInFlightMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private var calls = 0
    private var high = 0

    func enter() {
        lock.lock()
        defer { lock.unlock() }
        now += 1
        calls += 1
        high = max(high, now)
    }

    func leave() {
        lock.lock()
        defer { lock.unlock() }
        now -= 1
    }

    var peak: Int { lock.lock(); defer { lock.unlock() }; return high }
    var total: Int { lock.lock(); defer { lock.unlock() }; return calls }
}

/// Non-core error probe (sanitize path for foreign errors).
private struct ShiftsProbeError: Error {}
