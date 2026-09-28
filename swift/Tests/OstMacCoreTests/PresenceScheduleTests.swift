// PresenceScheduleTests.swift — e2-attention lane: presence schedules
// (window→status, transition-only sets, PT1H refresh, manual-pause
// contract (i), failure rule, persistence).
import XCTest

@testable import OstMacCore

/// Lock-guarded want log for `@Sendable` mock set-fetchers.
private final class SetCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var wants: [String] = []

    func append(_ w: String) {
        lock.lock()
        defer { lock.unlock() }
        wants.append(w)
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return wants
    }

    var count: Int { values.count }
}

private func schedEcho(_ status: PresenceStatus) -> PresenceResponse {
    PresenceResponse(ok: true, availability: status.availability, activity: status.availability)
}

@MainActor
final class PresenceScheduleTests: XCTestCase {
    func fixedCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// 2026-09-<day> <hour>:<minute> UTC. Sep 25 = Fri (weekday 6).
    func dt(_ day: Int, _ hour: Int, _ minute: Int = 0, _ cal: Calendar) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        return cal.date(from: comps)!
    }

    func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-pres-sched-\(UUID().uuidString)") ?? .standard
    }

    /// Workday 9–5 Busy entry (all days; tests pin Friday).
    func workEntry(status: PresenceStatus = .busy) -> PresenceScheduleEntry {
        PresenceScheduleEntry(
            window: QuietHoursWindow(enabled: true, startMinutes: 9 * 60, endMinutes: 17 * 60),
            status: status)
    }

    /// Poll until the schedule's lastSetAt lands (fire-and-forget set).
    func awaitSettled(_ store: PresenceScheduleStore, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while store.lastSetAt == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Poll until the log holds `count` calls.
    fileprivate func awaitCalls(_ log: SetCallLog, _ count: Int, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while log.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Poll until the store records an error.
    func awaitError(_ store: PresenceScheduleStore, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while store.error == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: model

    func testEntryDefaults() {
        let e = workEntry()
        XCTAssertEqual(e.status, .busy)
        XCTAssertTrue(e.window.enabled)
    }

    func testStatusTitlesReused() {
        XCTAssertEqual(PresenceStatus.allCases.map(\.title),
                       ["Available", "Busy", "Do not disturb", "Be right back", "Appear away", "Appear offline"])
    }

    func testActiveEntryFirstMatchWins() {
        let cal = fixedCalendar()
        let store = PresenceScheduleStore(defaults: isolatedDefaults())
        let first = PresenceScheduleEntry(
            window: QuietHoursWindow(enabled: true, startMinutes: 9 * 60, endMinutes: 17 * 60),
            status: .busy)
        let second = PresenceScheduleEntry(
            window: QuietHoursWindow(enabled: true, startMinutes: 12 * 60, endMinutes: 13 * 60),
            status: .away)
        store.entries = [first, second]
        // Overlap at noon: list order wins (first).
        XCTAssertEqual(store.activeEntry(at: dt(25, 12, 0, cal), calendar: cal)?.id, first.id)
        // Outside both: none.
        XCTAssertNil(store.activeEntry(at: dt(25, 20, 0, cal), calendar: cal))
        // Disabled entries never match.
        var off = first
        off.window.enabled = false
        store.entries = [off]
        XCTAssertNil(store.activeEntry(at: dt(25, 12, 0, cal), calendar: cal))
    }

    func testCapBound() {
        let store = PresenceScheduleStore(defaults: isolatedDefaults())
        XCTAssertEqual(PresenceScheduleStore.maxEntries, 8)
        for _ in 0 ..< PresenceScheduleStore.maxEntries {
            XCTAssertTrue(store.addEntry(workEntry()))
        }
        XCTAssertFalse(store.addEntry(workEntry()))
        XCTAssertEqual(store.entries.count, PresenceScheduleStore.maxEntries)
        store.removeEntry(id: store.entries[0].id)
        XCTAssertEqual(store.entries.count, PresenceScheduleStore.maxEntries - 1)
        XCTAssertTrue(store.addEntry(workEntry()))
    }

    // MARK: transition-only sets

    func testTransitionSetsOncePerWindow() async {
        let cal = fixedCalendar()
        let log = SetCallLog()
        let presence = PresenceStore()
        let store = PresenceScheduleStore(
            defaults: isolatedDefaults(),
            setFetcher: { want in log.append(want); return schedEcho(.busy) },
            presence: presence)
        store.enabled = true
        store.entries = [workEntry()]
        let t0 = dt(25, 9, 0, cal) // window opens
        store.tick(now: t0, calendar: cal)
        await awaitSettled(store)
        XCTAssertEqual(log.values, ["busy"])
        XCTAssertEqual(presence.own?.availability, "Busy") // echo adopted
        // Tick burst inside the same window (inside the refresh
        // line): no further sets.
        for minute in [5, 10, 20, 30, 45] {
            store.tick(now: t0.addingTimeInterval(TimeInterval(minute * 60)), calendar: cal)
        }
        // Drain any stray in-flight work, then assert the count held.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(store.appliedEntryID, store.entries[0].id)
    }

    func testNoWindowNoSet() async {
        let log = SetCallLog()
        let store = PresenceScheduleStore(
            defaults: isolatedDefaults(),
            setFetcher: { _ in log.append("x"); return schedEcho(.busy) })
        store.enabled = true
        store.entries = [workEntry()]
        let cal = fixedCalendar()
        store.tick(now: dt(25, 20, 0, cal), calendar: cal) // outside window
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(log.count, 0)
        XCTAssertNil(store.appliedEntryID)
    }

    func testDisabledScheduleNeverSets() async {
        let log = SetCallLog()
        let store = PresenceScheduleStore(
            defaults: isolatedDefaults(),
            setFetcher: { _ in log.append("x"); return schedEcho(.busy) })
        store.enabled = false
        store.entries = [workEntry()]
        let cal = fixedCalendar()
        store.tick(now: dt(25, 10, 0, cal), calendar: cal)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(log.count, 0)
    }

    func testSecondWindowTransitions() async {
        let cal = fixedCalendar()
        let log = SetCallLog()
        let store = PresenceScheduleStore(
            defaults: isolatedDefaults(),
            setFetcher: { want in log.append(want); return schedEcho(.available) })
        store.enabled = true
        let day = PresenceScheduleEntry(
            window: QuietHoursWindow(enabled: true, startMinutes: 9 * 60, endMinutes: 17 * 60),
            status: .busy)
        let night = PresenceScheduleEntry(
            window: QuietHoursWindow(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60),
            status: .offline)
        store.entries = [day, night]
        store.tick(now: dt(25, 10, 0, cal), calendar: cal)
        await awaitSettled(store)
        XCTAssertEqual(log.values, ["busy"])
        store.tick(now: dt(25, 23, 0, cal), calendar: cal)
        await awaitCalls(log, 2)
        XCTAssertEqual(log.values, ["busy", "offline"])
    }

    // MARK: PT1H refresh

    func testRefreshBeforePT1HExpiry() async {
        let cal = fixedCalendar()
        let log = SetCallLog()
        let store = PresenceScheduleStore(
            defaults: isolatedDefaults(),
            setFetcher: { _ in log.append("x"); return schedEcho(.busy) })
        store.enabled = true
        store.entries = [workEntry()]
        let t0 = dt(25, 9, 0, cal)
        store.tick(now: t0, calendar: cal)
        await awaitSettled(store)
        XCTAssertEqual(log.count, 1)
        // 49 min later: still fresh, no re-set.
        store.tick(now: t0.addingTimeInterval(49 * 60), calendar: cal)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(log.count, 1)
        // Past the 50-min refresh line: re-set before PT1H lapses.
        store.tick(now: t0.addingTimeInterval(51 * 60), calendar: cal)
        await awaitCalls(log, 2)
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(PresenceScheduleStore.refreshInterval, 50 * 60)
    }

    // MARK: manual contract (i) — manual pauses until next boundary

    func testManualSetPausesUntilBoundary() async {
        let cal = fixedCalendar()
        let log = SetCallLog()
        let presence = PresenceStore()
        let store = PresenceScheduleStore(
            defaults: isolatedDefaults(),
            setFetcher: { want in log.append(want); return schedEcho(.busy) },
            presence: presence)
        store.enabled = true
        let day = PresenceScheduleEntry(
            window: QuietHoursWindow(enabled: true, startMinutes: 9 * 60, endMinutes: 17 * 60),
            status: .busy)
        let night = PresenceScheduleEntry(
            window: QuietHoursWindow(enabled: true, startMinutes: 17 * 60, endMinutes: 22 * 60),
            status: .away)
        store.entries = [day, night]
        store.tick(now: dt(25, 9, 5, cal), calendar: cal)
        await awaitSettled(store)
        XCTAssertEqual(log.values, ["busy"])
        // User picks Available at 9:05 inside the Busy window.
        store.noteManualSet(now: dt(25, 9, 5, cal), calendar: cal)
        // Rest of the window: no flap-back (also past refresh line).
        store.tick(now: dt(25, 10, 0, cal), calendar: cal)
        store.tick(now: dt(25, 12, 0, cal), calendar: cal)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(log.count, 1)
        // Next boundary resumes the schedule.
        store.tick(now: dt(25, 17, 5, cal), calendar: cal)
        await awaitCalls(log, 2)
        XCTAssertEqual(log.values, ["busy", "away"])
    }

    func testManualHookFiresFromPresenceSet() async {
        // PresenceStore.set (the picker path) invokes the manual hook;
        // the app wires it to schedule.noteManualSet.
        var hooked = false
        let presence = PresenceStore(
            setFetcher: { _ in schedEcho(.available) })
        presence.manualSetHook = { hooked = true }
        presence.set(status: .available)
        let deadline = Date().addingTimeInterval(5)
        while !hooked, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(hooked)
    }

    // MARK: failure rule

    func testFailureKeepsStaleAndCapsRetries() async {
        struct Boom: Error {}
        let cal = fixedCalendar()
        let log = SetCallLog()
        let presence = PresenceStore()
        presence.adoptOwn(schedEcho(.available))
        presence.adoptPeer(UserPresenceResponse(ok: true, id: "u1", availability: "Busy", activity: "x"))
        let store = PresenceScheduleStore(
            defaults: isolatedDefaults(),
            setFetcher: { _ in log.append("x"); throw Boom() },
            presence: presence)
        store.enabled = true
        store.entries = [workEntry()]
        store.tick(now: dt(25, 9, 0, cal), calendar: cal)
        await awaitError(store)
        XCTAssertEqual(log.count, 1)
        // One retry allowed…
        store.tick(now: dt(25, 9, 5, cal), calendar: cal)
        await awaitCalls(log, 2)
        // …then the window holds (no retry storm).
        store.tick(now: dt(25, 9, 10, cal), calendar: cal)
        store.tick(now: dt(25, 10, 0, cal), calendar: cal)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(log.count, 2)
        XCTAssertNotNil(store.error)
        // Last good own kept, peers untouched.
        XCTAssertEqual(presence.own?.availability, "Available")
        XCTAssertEqual(presence.peers["u1"]?.availability, "Busy")
        XCTAssertNil(store.lastSetAt)
    }

    func testFailureBudgetResetsOnWindowChange() async {
        struct Boom: Error {}
        let cal = fixedCalendar()
        let log = SetCallLog()
        let store = PresenceScheduleStore(
            defaults: isolatedDefaults(),
            setFetcher: { _ in log.append("x"); throw Boom() })
        store.enabled = true
        let day = PresenceScheduleEntry(
            window: QuietHoursWindow(enabled: true, startMinutes: 9 * 60, endMinutes: 17 * 60),
            status: .busy)
        let night = PresenceScheduleEntry(
            window: QuietHoursWindow(enabled: true, startMinutes: 17 * 60, endMinutes: 22 * 60),
            status: .away)
        store.entries = [day, night]
        store.tick(now: dt(25, 9, 0, cal), calendar: cal)
        await awaitError(store)
        store.tick(now: dt(25, 9, 1, cal), calendar: cal)
        await awaitCalls(log, 2)
        XCTAssertEqual(log.count, 2)
        // New window: fresh budget (attempt fires again).
        store.tick(now: dt(25, 17, 5, cal), calendar: cal)
        await awaitCalls(log, 3)
        XCTAssertEqual(log.count, 3)
    }

    func testSignOutClearsAppliedState() async {
        let cal = fixedCalendar()
        let store = PresenceScheduleStore(
            defaults: isolatedDefaults(),
            setFetcher: { _ in schedEcho(.busy) })
        store.enabled = true
        store.entries = [workEntry()]
        store.tick(now: dt(25, 10, 0, cal), calendar: cal)
        await awaitSettled(store)
        XCTAssertNotNil(store.appliedEntryID)
        store.noteManualSet(now: dt(25, 10, 0, cal), calendar: cal)
        store.clearApplied() // app calls this next to presence.clear()
        XCTAssertNil(store.appliedEntryID)
        XCTAssertNil(store.lastSetAt)
        XCTAssertNil(store.error)
        // Schedule resumes clean: next tick re-sets (manual pause gone).
        store.tick(now: dt(25, 10, 5, cal), calendar: cal)
        await awaitSettled(store)
        XCTAssertNotNil(store.appliedEntryID)
    }

    // MARK: persistence

    func testPersistenceRoundTrip() {
        let defaults = isolatedDefaults()
        let first = PresenceScheduleStore(defaults: defaults)
        first.enabled = true
        first.entries = [workEntry(status: .dnd)]
        let second = PresenceScheduleStore(defaults: defaults)
        XCTAssertTrue(second.enabled)
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(second.entries[0].status, .dnd)
        XCTAssertEqual(second.entries[0].window.startMinutes, 9 * 60)
        // Applied state is session-only (never persisted).
        XCTAssertNil(second.appliedEntryID)
        XCTAssertNil(second.lastSetAt)
    }
}
