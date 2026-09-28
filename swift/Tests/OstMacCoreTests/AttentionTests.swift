// AttentionTests.swift — e2-attention lane: multi-window quiet hours
// (any-match, per-window semantics, old-keys migration, cap) and the
// Diagnostics quiet line's Focus source.
import XCTest

@testable import OstMacCore

@MainActor
final class AttentionTests: XCTestCase {
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
        UserDefaults(suiteName: "test-attention-\(UUID().uuidString)") ?? .standard
    }

    // MARK: multi-window matching

    func testAnyWindowQuiets() {
        let cal = fixedCalendar()
        let store = QuietHoursStore(defaults: isolatedDefaults())
        do {
            store.windows = [
                // Weeknights 22:00–07:00…
                QuietHoursWindow(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60),
                // …plus weekday lunch 12:00–13:00.
                QuietHoursWindow(
                    enabled: true, startMinutes: 12 * 60, endMinutes: 13 * 60,
                    days: [2, 3, 4, 5, 6]),
            ]
        }
        XCTAssertTrue(store.scheduleActive(at: dt(25, 23, 0, cal), calendar: cal))
        XCTAssertTrue(store.scheduleActive(at: dt(25, 12, 30, cal), calendar: cal))
        XCTAssertFalse(store.scheduleActive(at: dt(25, 10, 0, cal), calendar: cal))
        // Window #1's legacy proxies still read window #1.
        XCTAssertTrue(store.windowEnabled)
        XCTAssertEqual(store.startMinutes, 22 * 60)
        XCTAssertEqual(store.endMinutes, 7 * 60)
    }

    func testPerWindowSemantics() {
        // Overnight/weekday/empty rules apply per window, matching
        // QuietHoursWindow.contains exactly (existing tests pin the math).
        let cal = fixedCalendar()
        let store = QuietHoursStore(defaults: isolatedDefaults())
        do {
            store.windows = [
                // Friday-only overnight.
                QuietHoursWindow(
                    enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60, days: [6]),
                // Degenerate: start == end never fires.
                QuietHoursWindow(enabled: true, startMinutes: 600, endMinutes: 600),
                // Disabled: never fires.
                QuietHoursWindow(
                    enabled: false, startMinutes: 9 * 60, endMinutes: 17 * 60),
            ]
        }
        XCTAssertTrue(store.scheduleActive(at: dt(25, 23, 0, cal), calendar: cal)) // Fri eve
        XCTAssertTrue(store.scheduleActive(at: dt(26, 6, 0, cal), calendar: cal)) // Sat AM
        XCTAssertFalse(store.scheduleActive(at: dt(25, 10, 0, cal), calendar: cal)) // empty+off
        XCTAssertFalse(store.scheduleActive(at: dt(25, 12, 0, cal), calendar: cal))
    }

    func testLegacyFieldsProxyWindowOne() {
        // The single-window API stays live (old tests + old callers):
        // reads/writes hit windows[0], old keys stay in sync.
        let defaults = isolatedDefaults()
        let store = QuietHoursStore(defaults: defaults)
        do {
            store.windowEnabled = true
            store.startMinutes = 21 * 60
            store.endMinutes = 6 * 60 + 30
            store.days = [2, 3, 4, 5, 6]
        }
        let w0 = store.windows[0]
        XCTAssertEqual(
            w0,
            QuietHoursWindow(
                enabled: true, startMinutes: 21 * 60, endMinutes: 6 * 60 + 30,
                days: [2, 3, 4, 5, 6]))
        // Old keys keep the same values (downgrade-safe).
        XCTAssertTrue(defaults.bool(forKey: QuietHoursStore.enabledKey))
        XCTAssertEqual(defaults.integer(forKey: QuietHoursStore.startKey), 21 * 60)
        XCTAssertEqual(defaults.integer(forKey: QuietHoursStore.endKey), 6 * 60 + 30)
        XCTAssertEqual(defaults.array(forKey: QuietHoursStore.daysKey) as? [Int], [2, 3, 4, 5, 6])
    }

    func testAddRemoveCap() {
        let store = QuietHoursStore(defaults: isolatedDefaults())
        XCTAssertEqual(QuietHoursStore.maxWindows, 8)
        XCTAssertEqual(store.windows.count, 1) // seeded window #1
        for _ in 1 ..< QuietHoursStore.maxWindows {
            XCTAssertTrue(store.addWindow(QuietHoursWindow()))
        }
        XCTAssertFalse(store.addWindow(QuietHoursWindow()))
        XCTAssertEqual(store.windows.count, QuietHoursStore.maxWindows)
        // Window #1 is pinned (legacy home): removing it clears, not drops.
        let first = store.windows[0]
        XCTAssertNotNil(first)
        store.removeWindow(at: 0)
        let after = store.windows
        XCTAssertEqual(after.count, QuietHoursStore.maxWindows)
        XCTAssertFalse(after[0].enabled) // cleared to a default window
        // Other windows drop normally.
        store.removeWindow(at: 1)
        XCTAssertEqual(store.windows.count, QuietHoursStore.maxWindows - 1)
    }

    func testWindowsPersistRoundTrip() {
        let defaults = isolatedDefaults()
        let first = QuietHoursStore(defaults: defaults)
        do {
            first.windows = [
                QuietHoursWindow(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60),
                QuietHoursWindow(
                    enabled: true, startMinutes: 12 * 60, endMinutes: 13 * 60, days: [2, 3, 4, 5, 6]),
            ]
        }
        let second = QuietHoursStore(defaults: defaults)
        XCTAssertEqual(
            second.windows,
            first.windows)
        // …and the behavior survives the relaunch too.
        let cal = fixedCalendar()
        XCTAssertTrue(second.scheduleActive(at: dt(25, 12, 30, cal), calendar: cal))
    }

    // MARK: old-keys migration

    func testOldKeysMigrateLosslessly() {
        // Pre-list configs (old keys only, no windows blob) seed window
        // #1 with identical behavior.
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: QuietHoursStore.enabledKey)
        defaults.set(21 * 60, forKey: QuietHoursStore.startKey)
        defaults.set(6 * 60 + 30, forKey: QuietHoursStore.endKey)
        defaults.set([2, 3, 4, 5, 6], forKey: QuietHoursStore.daysKey)
        let store = QuietHoursStore(defaults: defaults)
        let w0 = store.windows[0]
        XCTAssertEqual(
            w0,
            QuietHoursWindow(
                enabled: true, startMinutes: 21 * 60, endMinutes: 6 * 60 + 30,
                days: [2, 3, 4, 5, 6]))
        let cal = fixedCalendar()
        XCTAssertTrue(store.scheduleActive(at: dt(25, 23, 0, cal), calendar: cal))
        XCTAssertFalse(store.scheduleActive(at: dt(25, 12, 0, cal), calendar: cal))
        // Legacy reads agree (same window).
        XCTAssertTrue(store.windowEnabled)
    }

    func testFreshDefaultsSeedOneWindow() {
        let store = QuietHoursStore(defaults: isolatedDefaults())
        let windows = store.windows
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(
            windows[0],
            QuietHoursWindow(
                enabled: false, startMinutes: 22 * 60, endMinutes: 7 * 60,
                days: [1, 2, 3, 4, 5, 6, 7]))
    }

    func testActiveWindowDiagnostic() {
        let cal = fixedCalendar()
        let store = QuietHoursStore(defaults: isolatedDefaults())
        do {
            store.windows = [
                QuietHoursWindow(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60),
                QuietHoursWindow(
                    enabled: true, startMinutes: 12 * 60, endMinutes: 13 * 60,
                    days: [2, 3, 4, 5, 6]),
            ]
        }
        let lunch = store.activeWindow(at: dt(25, 12, 30, cal), calendar: cal)
        XCTAssertEqual(lunch?.startMinutes, 12 * 60)
        XCTAssertNil(store.activeWindow(at: dt(25, 10, 0, cal), calendar: cal))
    }

    // MARK: Diagnostics quiet line — Focus source (additive)

    func testQuietLineFocusSource() {
        // Old 3-arg calls stay byte stable (defaulted param)…
        XCTAssertEqual(
            DiagnosticsFormat.quietHoursLine(dnd: false, schedule: false, suppressed: 0),
            "off · 0 suppressed")
        // …Focus joins the source list (order: schedule, DND, Focus).
        XCTAssertEqual(
            DiagnosticsFormat.quietHoursLine(dnd: false, schedule: false, suppressed: 2, focus: true),
            "on (Focus) · 2 suppressed")
        XCTAssertEqual(
            DiagnosticsFormat.quietHoursLine(dnd: true, schedule: true, suppressed: 1, focus: true),
            "on (schedule + DND + Focus) · 1 suppressed")
    }
}
