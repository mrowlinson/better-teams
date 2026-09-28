// PresenceTruthTests.swift — top10-presence lane: status lock, local
// activity truth, idle auto-away/restore, server-flip log + undo,
// per-device precedence, Diagnostics lines. Mock set-fetchers only
// (no core, no network); time is explicit, never slept.
import XCTest

@testable import OstMacCore

/// Lock-guarded want log for `@Sendable` mock set-fetchers.
final class TruthCallLog: @unchecked Sendable {
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

private func truthEcho(_ status: PresenceStatus) -> PresenceResponse {
    PresenceResponse(ok: true, availability: status.availability, activity: status.availability)
}

@MainActor
final class PresenceTruthTests: XCTestCase {
    func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-pres-truth-\(UUID().uuidString)") ?? .standard
    }

    /// Presence + truth sharing one mock set-fetcher (adoption lands in
    /// the same PresenceStore the truth reconciles).
    func makePair(
        defaults: UserDefaults? = nil,
        log: TruthCallLog? = nil
    ) -> (PresenceStore, PresenceTruthStore, TruthCallLog) {
        let calls = log ?? TruthCallLog()
        let presence = PresenceStore()
        let truth = PresenceTruthStore(
            defaults: defaults ?? isolatedDefaults(),
            setFetcher: { want in
                calls.append(want)
                let status = PresenceStatus(rawValue: want) ?? .available
                return truthEcho(status)
            },
            presence: presence)
        truth.idleProvider = { 0 } // active unless a test says idle
        return (presence, truth, calls)
    }

    /// Poll for async fire-and-forget sets (PresenceTests precedent).
    func waitForWants(_ log: TruthCallLog, count: Int) async {
        for _ in 0 ..< 100 {
            if log.count >= count { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Poll for an echo adoption (fires complete async).
    func waitForEcho(_ presence: PresenceStore, availability: String) async {
        for _ in 0 ..< 100 {
            if presence.own?.availability == availability { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: Durations + lock math

    func testLockDurations() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        XCTAssertEqual(
            PresenceLockDuration.fifteenMinutes.expiryDate(now: now, calendar: cal),
            cal.date(byAdding: .minute, value: 15, to: now))
        XCTAssertEqual(
            PresenceLockDuration.oneHour.expiryDate(now: now, calendar: cal),
            cal.date(byAdding: .hour, value: 1, to: now))
        XCTAssertEqual(
            PresenceLockDuration.fourHours.expiryDate(now: now, calendar: cal),
            cal.date(byAdding: .hour, value: 4, to: now))
        XCTAssertNil(PresenceLockDuration.untilOff.expiryDate(now: now, calendar: cal))
    }

    func testLockSummary() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let short = PresenceLock(
            status: .dnd, until: now.addingTimeInterval(42 * 60), setAt: now)
        XCTAssertEqual(short.summary(now: now), "Do not disturb · 42m left")
        let long = PresenceLock(
            status: .busy, until: now.addingTimeInterval(125 * 60), setAt: now)
        XCTAssertEqual(long.summary(now: now), "Busy · 2h 05m left")
        let indefinite = PresenceLock(status: .available, until: nil, setAt: now)
        XCTAssertEqual(indefinite.summary(now: now), "Available · until off")
        XCTAssertTrue(short.isActive(now: now))
        XCTAssertFalse(short.isActive(now: now.addingTimeInterval(43 * 60)))
        XCTAssertTrue(indefinite.isActive(now: now.addingTimeInterval(86400 * 30)))
    }

    func testLockPersistsAndSweeps() {
        let defaults = isolatedDefaults()
        let now = Date()
        let (_, truth, _) = makePair(defaults: defaults)
        truth.lock(status: .dnd, duration: .oneHour, now: now)
        XCTAssertTrue(truth.isLocked(now: now))
        // Relaunch inside the hour: the lock survives.
        let revived = PresenceTruthStore(defaults: defaults)
        XCTAssertTrue(revived.isLocked(now: now.addingTimeInterval(30 * 60)))
        XCTAssertEqual(revived.lock?.status, .dnd)
        // Relaunch past expiry: the init sweep drops it.
        let stale = isolatedDefaults()
        stale.set("dnd", forKey: PresenceTruthStore.lockStatusKey)
        stale.set(
            Date().addingTimeInterval(-3600).timeIntervalSince1970,
            forKey: PresenceTruthStore.lockUntilKey)
        stale.set(
            Date().addingTimeInterval(-7200).timeIntervalSince1970,
            forKey: PresenceTruthStore.lockSetAtKey)
        let swept = PresenceTruthStore(defaults: stale)
        XCTAssertNil(swept.lock)
    }

    // MARK: Accept — DND 1h holds vs idle + calendar

    func testAcceptDNDLockHoldsVsIdleAndCalendar() async {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let (presence, truth, calls) = makePair()
        presence.adoptOwn(truthEcho(.available))
        // Calendar active (9–5 Busy window) + Mac idle all hour.
        let sched = PresenceScheduleStore(
            defaults: isolatedDefaults(),
            setFetcher: { _ in truthEcho(.busy) }, presence: presence)
        sched.enabled = true
        _ = sched.addEntry(PresenceScheduleEntry(
            window: QuietHoursWindow(enabled: true, startMinutes: 0, endMinutes: 24 * 60 - 1),
            status: .busy))
        // Test clock (prod passes real now; the suite pins fixed now).
        var current = now
        sched.externalHold = { [weak truth] in truth?.isLocked(now: current) ?? false }
        truth.scheduleActive = { true }
        truth.idleProvider = { 9999 }
        truth.tick(now: now) // baseline: echo seen, devices built
        truth.lock(status: .dnd, duration: .oneHour, now: now)
        await waitForWants(calls, count: 1)
        await waitForEcho(presence, availability: "DoNotDisturb")
        XCTAssertEqual(calls.values, ["dnd"])
        // Mid-hour: idle + calendar both push, nothing moves.
        current = now.addingTimeInterval(30 * 60)
        truth.tick(now: current)
        sched.tick(now: current)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(calls.count, 1) // no idle-away, no schedule set
        XCTAssertEqual(presence.own?.availability, "DoNotDisturb")
        // Server drifts to Away (the DND->Away flip): reasserted.
        presence.adoptOwn(truthEcho(.away))
        current = now.addingTimeInterval(31 * 60)
        truth.tick(now: current)
        await waitForWants(calls, count: 2)
        await waitForEcho(presence, availability: "DoNotDisturb")
        XCTAssertEqual(calls.values, ["dnd", "dnd"])
        XCTAssertTrue(truth.entries.contains { $0.cause == .server && $0.toAvailability == "Away" })
        XCTAssertTrue(truth.entries.contains {
            $0.cause == .reaffirm && $0.toAvailability == "DoNotDisturb"
        })
        XCTAssertNil(truth.undoOffer) // locked drift offers no undo
        // Past expiry: the lock lifts, the calendar resumes.
        current = now.addingTimeInterval(61 * 60)
        truth.tick(now: current)
        XCTAssertFalse(truth.isLocked(now: current))
        XCTAssertTrue(truth.entries.contains { $0.cause == .lockExpired })
        sched.tick(now: current)
        await waitForEcho(presence, availability: "Busy")
        XCTAssertEqual(presence.own?.availability, "Busy")
    }

    func testScheduleHoldLiftsClean() async {
        let (presence, truth, _) = makePair()
        let log = TruthCallLog()
        let sched = PresenceScheduleStore(
            defaults: isolatedDefaults(),
            setFetcher: { want in
                log.append(want)
                return truthEcho(.busy)
            }, presence: presence)
        sched.enabled = true
        _ = sched.addEntry(PresenceScheduleEntry(
            window: QuietHoursWindow(enabled: true, startMinutes: 0, endMinutes: 24 * 60 - 1),
            status: .busy))
        sched.externalHold = { [weak truth] in truth?.isLocked() ?? false }
        let now = Date()
        truth.lock(status: .available, duration: .fifteenMinutes, now: now)
        sched.tick(now: now)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(log.count, 0) // held, unspent
        truth.unlock(now: now)
        sched.tick(now: now)
        await waitForWants(log, count: 1)
        XCTAssertEqual(log.values, ["busy"]) // current window fires on lift
    }

    // MARK: Idle auto-away + restore

    func testIdleAutoAwayFiresFromAvailableWithUndo() async {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let (presence, truth, calls) = makePair()
        presence.adoptOwn(truthEcho(.available))
        truth.idleProvider = { 301 }
        truth.tick(now: now) // baseline
        truth.tick(now: now.addingTimeInterval(2))
        await waitForWants(calls, count: 1)
        XCTAssertEqual(calls.values, ["away"])
        XCTAssertEqual(truth.entries.first?.cause, .idle)
        XCTAssertEqual(truth.undoOffer?.status, .available)
        await waitForEcho(presence, availability: "Away")
        // Undo restores Available and disarms.
        truth.undoLastAutoChange(now: now.addingTimeInterval(4))
        await waitForWants(calls, count: 2)
        XCTAssertEqual(calls.values, ["away", "available"])
        XCTAssertEqual(truth.entries.first?.cause, .undo)
        XCTAssertNil(truth.undoOffer)
    }

    func testIdleRespectsThresholdLockAndScreen() async {
        let now = Date()
        let (presence, truth, calls) = makePair()
        presence.adoptOwn(truthEcho(.available))
        truth.idleProvider = { 299 }
        truth.tick(now: now)
        truth.tick(now: now.addingTimeInterval(2))
        XCTAssertEqual(calls.count, 0) // under the 5m line
        // Locked screen counts as idle even at 0 idle seconds.
        truth.idleProvider = { 0 }
        truth.noteScreenLock()
        truth.tick(now: now.addingTimeInterval(4))
        await waitForWants(calls, count: 1)
        XCTAssertEqual(calls.values, ["away"])
        XCTAssertEqual(truth.entries.first?.note, "locked")
    }

    func testAsleepCountsAsIdle() async {
        let (presence, truth, calls) = makePair()
        presence.adoptOwn(truthEcho(.available))
        truth.noteSleep()
        truth.tick()
        truth.tick()
        await waitForWants(calls, count: 1)
        XCTAssertEqual(calls.values, ["away"])
    }

    func testIdleHoldsWhileScheduleActive() {
        let (presence, truth, calls) = makePair()
        presence.adoptOwn(truthEcho(.available))
        truth.idleProvider = { 9999 }
        truth.scheduleActive = { true }
        truth.tick()
        truth.tick()
        XCTAssertEqual(calls.count, 0)
        XCTAssertTrue(truth.entries.isEmpty)
    }

    func testIdleOnlyFiresFromAvailable() {
        for start in [PresenceStatus.busy, .dnd, .away, .offline] {
            let (presence, truth, calls) = makePair()
            presence.adoptOwn(truthEcho(start))
            truth.idleProvider = { 9999 }
            truth.tick()
            truth.tick()
            XCTAssertEqual(calls.count, 0, "from \(start.rawValue)")
        }
    }

    func testRestoreOnActivityAfterIdleAway() async {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let (presence, truth, calls) = makePair()
        presence.adoptOwn(truthEcho(.available))
        truth.idleProvider = { 9999 }
        truth.tick(now: now)
        truth.tick(now: now.addingTimeInterval(2))
        await waitForWants(calls, count: 1)
        await waitForEcho(presence, availability: "Away")
        // Input back: restore fires with an undo back to Away.
        truth.idleProvider = { 0 }
        truth.tick(now: now.addingTimeInterval(4))
        await waitForWants(calls, count: 2)
        XCTAssertEqual(calls.values, ["away", "available"])
        XCTAssertEqual(truth.entries.first?.cause, .active)
        XCTAssertEqual(truth.undoOffer?.status, .away)
    }

    func testNoRestoreWithoutIdleArm() {
        // Manual Away + activity: not ours, never touched.
        let (presence, truth, calls) = makePair()
        presence.adoptOwn(truthEcho(.away))
        truth.idleProvider = { 0 }
        truth.tick()
        truth.tick()
        XCTAssertEqual(calls.count, 0)
    }

    func testManualSetDisarmsAndLabels() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let (presence, truth, calls) = makePair()
        presence.adoptOwn(truthEcho(.available))
        truth.tick(now: now)
        truth.noteManualSet(now: now.addingTimeInterval(2))
        presence.adoptOwn(truthEcho(.busy)) // the picker's echo
        truth.tick(now: now.addingTimeInterval(4))
        XCTAssertTrue(truth.entries.isEmpty) // manual, never "server"
        XCTAssertNil(truth.undoOffer)
        XCTAssertEqual(calls.count, 0)
    }

    // MARK: Server flips + schedule log

    func testServerFlipLoggedWithUndo() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let (presence, truth, _) = makePair()
        presence.adoptOwn(truthEcho(.available))
        truth.tick(now: now)
        presence.adoptOwn(truthEcho(.away)) // random-Away, nobody fired
        truth.tick(now: now.addingTimeInterval(2))
        XCTAssertEqual(truth.entries.first?.cause, .server)
        XCTAssertEqual(truth.entries.first?.fromAvailability, "Available")
        XCTAssertEqual(truth.entries.first?.toAvailability, "Away")
        XCTAssertEqual(truth.undoOffer?.status, .available)
    }

    func testScheduledSetLoggedWithUndo() {
        let now = Date()
        let (presence, truth, _) = makePair()
        presence.adoptOwn(truthEcho(.available))
        truth.tick(now: now)
        truth.noteScheduledSet(.busy, now: now.addingTimeInterval(2))
        XCTAssertEqual(truth.entries.first?.cause, .schedule)
        XCTAssertEqual(truth.undoOffer?.status, .available)
        // The schedule's own echo is consumed, never double-logged.
        presence.adoptOwn(truthEcho(.busy))
        truth.tick(now: now.addingTimeInterval(4))
        XCTAssertEqual(truth.entries.count, 1)
    }

    func testUnmappableServerFlipHasNoUndo() {
        let (presence, truth, _) = makePair()
        presence.adoptOwn(PresenceResponse(ok: true, availability: "PresenceUnknown", activity: "x"))
        truth.tick()
        presence.adoptOwn(truthEcho(.away))
        truth.tick()
        XCTAssertEqual(truth.entries.first?.cause, .server)
        XCTAssertNil(truth.undoOffer) // can't set-undo to an unknown state
    }

    // MARK: Ghost + offline

    func testGhostHoldsAutoSets() {
        let ghost = GhostStore()
        ghost.master = true
        ghost.suppressPresence = true
        let (presence, truth, calls) = makePair()
        truth.ghost = ghost
        presence.adoptOwn(truthEcho(.available))
        truth.idleProvider = { 9999 }
        truth.tick()
        truth.tick()
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(ghost.heldPresence, 2) // held every tick (schedule precedent)
        XCTAssertTrue(truth.entries.isEmpty) // no phantom entries
    }

    func testGhostHoldsLockFireButKeepsLock() async {
        let ghost = GhostStore()
        ghost.master = true
        ghost.suppressPresence = true
        let (presence, truth, calls) = makePair()
        truth.ghost = ghost
        presence.adoptOwn(truthEcho(.available))
        let now = Date()
        truth.lock(status: .dnd, duration: .oneHour, now: now)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(ghost.heldPresence, 1)
        XCTAssertTrue(truth.isLocked(now: now)) // intent recorded
        // Lift: the drift reasserts on the next tick.
        ghost.master = false
        truth.tick(now: now.addingTimeInterval(61))
        await waitForWants(calls, count: 1)
        XCTAssertEqual(calls.values, ["dnd"])
    }

    func testOfflineTickSweepsWithoutWrites() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let (presence, truth, calls) = makePair()
        truth.liveWrites = false
        presence.adoptOwn(truthEcho(.available))
        truth.idleProvider = { 9999 }
        truth.tick(now: now)
        truth.tick(now: now.addingTimeInterval(2))
        XCTAssertEqual(calls.count, 0) // demo-safe
        XCTAssertEqual(truth.devices.count, 2) // rows still build
        XCTAssertEqual(truth.activitySummary, "idle 2h 46m")
    }

    // MARK: Undo + log bounds

    func testUndoExpires() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let (presence, truth, calls) = makePair()
        presence.adoptOwn(truthEcho(.available))
        truth.tick(now: now)
        presence.adoptOwn(truthEcho(.away))
        truth.tick(now: now.addingTimeInterval(2))
        XCTAssertNotNil(truth.undoOffer)
        truth.tick(now: now.addingTimeInterval(2 + PresenceTruthStore.undoWindow + 1))
        XCTAssertNil(truth.undoOffer)
        truth.undoLastAutoChange(now: now.addingTimeInterval(20))
        XCTAssertEqual(calls.count, 0)
    }

    func testLockExpiryLogsWithoutSet() async {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let (presence, truth, calls) = makePair()
        presence.adoptOwn(truthEcho(.available))
        truth.tick(now: now)
        truth.lock(status: .busy, duration: .fifteenMinutes, now: now)
        await waitForWants(calls, count: 1)
        truth.tick(now: now.addingTimeInterval(16 * 60))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(truth.isLocked(now: now.addingTimeInterval(16 * 60)))
        XCTAssertEqual(truth.entries.first?.cause, .lockExpired)
        XCTAssertEqual(calls.count, 1) // expiry sends nothing
    }

    func testChangeLogCaps() {
        let (_, truth, _) = makePair()
        let now = Date()
        for i in 0 ..< 40 {
            truth.noteScheduledSet(i % 2 == 0 ? .busy : .available, now: now.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(truth.entries.count, PresenceTruthStore.maxEntries)
    }

    func testClearSessionDropsAll() {
        let (presence, truth, _) = makePair()
        presence.adoptOwn(truthEcho(.available))
        truth.tick()
        truth.lock(status: .dnd, duration: .untilOff)
        truth.adoptDevice(PresenceDevice(
            id: "phone", name: "iPhone", kind: .other,
            availability: "Away", detail: "test"))
        truth.clearSession()
        XCTAssertFalse(truth.isLocked())
        XCTAssertTrue(truth.entries.isEmpty)
        XCTAssertTrue(truth.devices.isEmpty)
        XCTAssertNil(truth.undoOffer)
    }

    // MARK: Precedence + devices

    func testPrecedenceRanks() {
        XCTAssertEqual(PresencePrecedence.rank(availability: "DoNotDisturb"), 4)
        XCTAssertEqual(PresencePrecedence.rank(availability: "Busy"), 3)
        XCTAssertEqual(PresencePrecedence.rank(availability: "Available", activity: "InACall"), 3)
        XCTAssertEqual(PresencePrecedence.rank(availability: "Available", activity: "Presenting"), 3)
        XCTAssertEqual(PresencePrecedence.rank(availability: "Away"), 2)
        XCTAssertEqual(PresencePrecedence.rank(availability: "BeRightBack"), 2)
        XCTAssertEqual(PresencePrecedence.rank(availability: "Available"), 1)
        XCTAssertEqual(PresencePrecedence.rank(availability: "Offline"), 0)
        XCTAssertEqual(PresencePrecedence.rank(availability: "PresenceUnknown"), 0)
        XCTAssertEqual(PresencePrecedence.rank(availability: "FutureValue"), 0)
        XCTAssertEqual(PresencePrecedence.rules.count, 5)
    }

    func testPrecedenceEffectiveAndWhy() {
        let now = Date()
        let mac = PresenceDevice(
            id: PresenceDevice.thisMacID, name: "This Mac", kind: .thisMac,
            availability: "Available", lastSeen: now)
        let phone = PresenceDevice(
            id: "phone", name: "iPhone", kind: .other,
            availability: "DoNotDisturb", lastSeen: now.addingTimeInterval(-60))
        let (winner, why) = PresencePrecedence.effective(devices: [mac, phone])!
        XCTAssertEqual(winner.id, "phone")
        XCTAssertTrue(why.contains("Do not disturb"))
        // Tie → most recently seen.
        let a = PresenceDevice(
            id: "a", name: "A", kind: .other,
            availability: "Busy", lastSeen: now)
        let b = PresenceDevice(
            id: "b", name: "B", kind: .other,
            availability: "Busy", lastSeen: now.addingTimeInterval(10))
        XCTAssertEqual(PresencePrecedence.effective(devices: [a, b])?.device.id, "b")
        // Final tie → this Mac.
        let c = PresenceDevice(
            id: "c", name: "C", kind: .other, availability: "Busy")
        let macTied = PresenceDevice(
            id: PresenceDevice.thisMacID, name: "This Mac", kind: .thisMac,
            availability: "Busy")
        XCTAssertEqual(
            PresencePrecedence.effective(devices: [c, macTied])?.device.id,
            PresenceDevice.thisMacID)
        XCTAssertNil(PresencePrecedence.effective(devices: []))
    }

    func testDevicesListThisMacAndServer() {
        let (presence, truth, _) = makePair()
        presence.adoptOwn(truthEcho(.available))
        truth.tick()
        let ids = truth.devices.map(\.id)
        XCTAssertTrue(ids.contains(PresenceDevice.thisMacID))
        XCTAssertTrue(ids.contains(PresenceDevice.serverID))
        XCTAssertEqual(truth.effectiveDevice?.device.id, PresenceDevice.thisMacID)
        XCTAssertFalse(truth.drifted)
        // Adopted extras list; built-ins can't be removed.
        truth.adoptDevice(PresenceDevice(
            id: "phone", name: "iPhone", kind: .other, availability: "Busy"))
        XCTAssertEqual(truth.devices.count, 3)
        truth.removeDevice(id: PresenceDevice.thisMacID)
        XCTAssertEqual(truth.devices.count, 3)
        truth.removeDevice(id: "phone")
        XCTAssertEqual(truth.devices.count, 2)
    }

    func testDriftFlag() {
        let (presence, truth, _) = makePair()
        presence.adoptOwn(truthEcho(.available))
        truth.tick()
        truth.lock(status: .dnd, duration: .untilOff)
        truth.tick()
        XCTAssertTrue(truth.drifted) // Mac publishes DND, echo still Available
    }

    // MARK: Pure activity + formats

    func testClassifyBoundaries() {
        XCTAssertEqual(
            PresenceActivity.classify(idleSeconds: 299).kind, .active)
        XCTAssertEqual(
            PresenceActivity.classify(idleSeconds: 300).kind, .idle)
        XCTAssertEqual(
            PresenceActivity.classify(idleSeconds: 0, locked: true).kind, .locked)
        XCTAssertEqual(
            PresenceActivity.classify(idleSeconds: 0, asleep: true).kind, .asleep)
        XCTAssertEqual(PresenceActivity.idleSpan(45), "45s")
        XCTAssertEqual(PresenceActivity.idleSpan(360), "6m")
        XCTAssertEqual(
            PresenceActivity.classify(idleSeconds: 360).summary, "idle 6m")
    }

    func testSystemIdleProbeSane() {
        let secs = PresenceActivity.systemIdleSeconds()
        XCTAssertTrue(secs.isFinite)
        XCTAssertGreaterThanOrEqual(secs, 0)
    }

    func testDiagnosticsLines() {
        XCTAssertEqual(DiagnosticsFormat.presenceLockLine(lock: nil), "off")
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let lock = PresenceLock(
            status: .dnd, until: now.addingTimeInterval(42 * 60), setAt: now)
        XCTAssertEqual(
            DiagnosticsFormat.presenceLockLine(lock: lock, now: now),
            "Do not disturb · 42m left")
        XCTAssertEqual(
            DiagnosticsFormat.presenceLockLine(
                lock: lock, now: now.addingTimeInterval(3600)),
            "off")
        XCTAssertEqual(
            DiagnosticsFormat.presenceActivityLine(summary: "idle 6m", autoAway: true, restore: false),
            "idle 6m · auto-Away on · restore off")
        XCTAssertEqual(
            DiagnosticsFormat.presenceAutoLine(autoCount: 3, total: 5),
            "3 auto · 5 logged")
        XCTAssertEqual(
            DiagnosticsFormat.presenceDevicesLine(winner: "iPhone (Busy)", count: 3, drifted: true),
            "iPhone (Busy) · 3 devices · drifting")
    }

    func testEntrySummary() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let at = cal.date(from: DateComponents(
            year: 2026, month: 9, day: 10, hour: 14, minute: 53))!
        let entry = PresenceChangeEntry(
            at: at, fromAvailability: "Available", toAvailability: "Away",
            cause: .idle, note: "idle 6m", undoStatus: .available)
        XCTAssertEqual(
            entry.summary(calendar: cal), "14:53 Available → Away · Idle (idle 6m)")
    }
}
