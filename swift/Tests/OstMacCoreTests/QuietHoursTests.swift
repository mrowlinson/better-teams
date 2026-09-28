// QuietHoursTests.swift — om-quiet-hours lane: schedule window math
// (incl. overnight + start-day ownership), DND auto-expiry, the
// suppression-count gate, and the rules-first contract (rules decide,
// quiet hours only hold banners — unread still accrues).
import XCTest

@testable import OstMacCore

final class QuietHoursTests: XCTestCase {
    // MARK: helpers

    /// Fixed Gregorian/UTC calendar (deterministic weekdays + times).
    func fixedCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// 2026-09-<day> <hour>:<minute> UTC. Sep 24 = Thu, 25 = Fri,
    /// 26 = Sat, 27 = Sun, 28 = Mon (asserted by testFixtureWeekdays).
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
        UserDefaults(suiteName: "test-quiet-hours-\(UUID().uuidString)") ?? .standard
    }

    func testFixtureWeekdays() {
        let cal = fixedCalendar()
        XCTAssertEqual(cal.component(.weekday, from: dt(24, 12, 0, cal)), 5) // Thu
        XCTAssertEqual(cal.component(.weekday, from: dt(25, 12, 0, cal)), 6) // Fri
        XCTAssertEqual(cal.component(.weekday, from: dt(26, 12, 0, cal)), 7) // Sat
        XCTAssertEqual(cal.component(.weekday, from: dt(27, 12, 0, cal)), 1) // Sun
        XCTAssertEqual(cal.component(.weekday, from: dt(28, 12, 0, cal)), 2) // Mon
    }

    // MARK: same-day window math

    func testDisabledWindowNeverMatches() {
        let cal = fixedCalendar()
        let w = QuietHoursWindow(enabled: false, startMinutes: 9 * 60, endMinutes: 17 * 60)
        XCTAssertFalse(w.contains(dt(24, 12, 0, cal), calendar: cal))
    }

    func testEmptyWindowNeverMatches() {
        // start == end is explicitly NOT all-day.
        let cal = fixedCalendar()
        let w = QuietHoursWindow(enabled: true, startMinutes: 600, endMinutes: 600)
        XCTAssertTrue(w.isEmpty)
        XCTAssertFalse(w.isOvernight)
        XCTAssertFalse(w.contains(dt(24, 10, 0, cal), calendar: cal))
        XCTAssertFalse(w.contains(dt(24, 0, 0, cal), calendar: cal))
    }

    func testSameDayInsideAndOutside() {
        let cal = fixedCalendar()
        let w = QuietHoursWindow(enabled: true, startMinutes: 9 * 60, endMinutes: 17 * 60)
        XCTAssertTrue(w.contains(dt(24, 9, 0, cal), calendar: cal)) // start inclusive
        XCTAssertTrue(w.contains(dt(24, 12, 30, cal), calendar: cal))
        XCTAssertFalse(w.contains(dt(24, 17, 0, cal), calendar: cal)) // end exclusive
        XCTAssertFalse(w.contains(dt(24, 8, 59, cal), calendar: cal))
        XCTAssertFalse(w.contains(dt(24, 23, 0, cal), calendar: cal))
        XCTAssertFalse(w.isOvernight)
    }

    func testDaysGateSameDayWindow() {
        let cal = fixedCalendar()
        // Fridays 09:00–17:00 only.
        let w = QuietHoursWindow(enabled: true, startMinutes: 9 * 60, endMinutes: 17 * 60, days: [6])
        XCTAssertTrue(w.contains(dt(25, 10, 0, cal), calendar: cal)) // Fri
        XCTAssertFalse(w.contains(dt(24, 10, 0, cal), calendar: cal)) // Thu
        XCTAssertFalse(w.contains(dt(26, 10, 0, cal), calendar: cal)) // Sat
    }

    // MARK: overnight window math

    func testOvernightArms() {
        let cal = fixedCalendar()
        let w = QuietHoursWindow(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60)
        XCTAssertTrue(w.isOvernight)
        XCTAssertTrue(w.contains(dt(24, 22, 0, cal), calendar: cal)) // start inclusive
        XCTAssertTrue(w.contains(dt(24, 23, 59, cal), calendar: cal))
        XCTAssertTrue(w.contains(dt(25, 0, 0, cal), calendar: cal)) // past midnight
        XCTAssertTrue(w.contains(dt(25, 6, 59, cal), calendar: cal))
        XCTAssertFalse(w.contains(dt(25, 7, 0, cal), calendar: cal)) // end exclusive
        XCTAssertFalse(w.contains(dt(24, 12, 0, cal), calendar: cal)) // midday gap
        XCTAssertFalse(w.contains(dt(24, 21, 59, cal), calendar: cal))
    }

    func testOvernightBelongsToStartDay() {
        let cal = fixedCalendar()
        // Friday-only 22:00–07:00: Fri evening + Sat morning, nothing else.
        let w = QuietHoursWindow(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60, days: [6])
        XCTAssertTrue(w.contains(dt(25, 23, 0, cal), calendar: cal)) // Fri evening
        XCTAssertTrue(w.contains(dt(26, 6, 0, cal), calendar: cal)) // Sat morning (owns Fri)
        XCTAssertFalse(w.contains(dt(25, 6, 0, cal), calendar: cal)) // Fri morning (owns Thu)
        XCTAssertFalse(w.contains(dt(26, 23, 0, cal), calendar: cal)) // Sat evening
        XCTAssertFalse(w.contains(dt(24, 23, 0, cal), calendar: cal)) // Thu evening
        XCTAssertFalse(w.contains(dt(27, 1, 0, cal), calendar: cal)) // Sun morning (owns Sat)
    }

    func testOvernightSundayWrap() {
        let cal = fixedCalendar()
        // Sunday-only overnight: Sun evening + Mon morning.
        let w = QuietHoursWindow(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60, days: [1])
        XCTAssertTrue(w.contains(dt(27, 23, 0, cal), calendar: cal)) // Sun evening
        XCTAssertTrue(w.contains(dt(28, 6, 0, cal), calendar: cal)) // Mon morning (owns Sun)
        XCTAssertFalse(w.contains(dt(27, 6, 0, cal), calendar: cal)) // Sun morning (owns Sat)
    }

    // MARK: labels + summaries

    func testLabels() {
        XCTAssertEqual(QuietHoursWindow.label(minutes: 0), "00:00")
        XCTAssertEqual(QuietHoursWindow.label(minutes: 22 * 60 + 5), "22:05")
        XCTAssertEqual(QuietHoursWindow.label(minutes: -30), "00:00") // clamped
        XCTAssertEqual(QuietHoursWindow.label(minutes: 99_999), "23:59") // clamped
        let w = QuietHoursWindow(startMinutes: 22 * 60, endMinutes: 7 * 60)
        XCTAssertEqual(w.rangeLabel, "22:00–07:00")
    }

    func testDaysSummary() {
        let cal = fixedCalendar()
        XCTAssertEqual(QuietHoursWindow(days: [1, 2, 3, 4, 5, 6, 7]).daysSummary(calendar: cal), "every day")
        XCTAssertEqual(QuietHoursWindow(days: [2, 3, 4, 5, 6]).daysSummary(calendar: cal), "weekdays")
        XCTAssertEqual(QuietHoursWindow(days: [1, 7]).daysSummary(calendar: cal), "weekends")
        XCTAssertEqual(QuietHoursWindow(days: []).daysSummary(calendar: cal), "no days")
        XCTAssertEqual(QuietHoursWindow(days: [6]).daysSummary(calendar: cal), "Fri")
        let w = QuietHoursWindow(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60)
        XCTAssertEqual(w.summary(calendar: cal), "22:00–07:00 · every day")
    }

    // MARK: DND expiry options

    func testDNDOptionLabels() {
        XCTAssertEqual(DNDDuration.allCases.map(\.label),
                       ["30 minutes", "1 hour", "4 hours", "Until 8 AM", "Until turned off"])
    }

    func testDNDExpiryOffsets() {
        let cal = fixedCalendar()
        let now = dt(24, 12, 0, cal)
        XCTAssertEqual(DNDDuration.thirtyMinutes.expiryDate(now: now, calendar: cal), dt(24, 12, 30, cal))
        XCTAssertEqual(DNDDuration.oneHour.expiryDate(now: now, calendar: cal), dt(24, 13, 0, cal))
        XCTAssertEqual(DNDDuration.fourHours.expiryDate(now: now, calendar: cal), dt(24, 16, 0, cal))
        XCTAssertNil(DNDDuration.untilTurnedOff.expiryDate(now: now, calendar: cal))
    }

    func testUntilMorning() {
        let cal = fixedCalendar()
        // Before 8 AM: today 08:00.
        XCTAssertEqual(
            DNDDuration.untilMorning.expiryDate(now: dt(24, 6, 30, cal), calendar: cal),
            dt(24, 8, 0, cal))
        // After 8 AM: tomorrow 08:00.
        XCTAssertEqual(
            DNDDuration.untilMorning.expiryDate(now: dt(24, 9, 0, cal), calendar: cal),
            dt(25, 8, 0, cal))
        // Exactly 08:00: today's slot is gone — tomorrow.
        XCTAssertEqual(
            DNDDuration.untilMorning.expiryDate(now: dt(24, 8, 0, cal), calendar: cal),
            dt(25, 8, 0, cal))
    }

    // MARK: store — DND state + expiry sweep

    func testStoreDefaultsOff() async {
        let store = await QuietHoursStore(defaults: isolatedDefaults())
        let (enabled, dnd, suppressed) = await MainActor.run {
            (store.windowEnabled, store.dndOn, store.suppressedCount)
        }
        XCTAssertFalse(enabled)
        XCTAssertFalse(dnd)
        XCTAssertEqual(suppressed, 0)
        let quiet = await store.isQuiet()
        XCTAssertFalse(quiet)
    }

    func testDNDActiveAndExpiry() async {
        let cal = fixedCalendar()
        let store = await QuietHoursStore(defaults: isolatedDefaults())
        let now = dt(24, 12, 0, cal)
        await store.enableDND(.oneHour, now: now, calendar: cal)
        let active = await store.dndActive(at: dt(24, 12, 30, cal))
        XCTAssertTrue(active)
        // At expiry the DND no longer quiets…
        let past = await store.dndActive(at: dt(24, 13, 0, cal))
        XCTAssertFalse(past)
        // …and a sweep clears the toggle (drives the Settings UI off).
        await store.refresh(now: dt(24, 13, 0, cal))
        let (dndOn, until) = await MainActor.run { (store.dndOn, store.dndUntil) }
        XCTAssertFalse(dndOn)
        XCTAssertNil(until)
    }

    func testDNDIndefiniteStaysOn() async {
        let cal = fixedCalendar()
        let store = await QuietHoursStore(defaults: isolatedDefaults())
        await store.enableDND(.untilTurnedOff, now: dt(24, 12, 0, cal), calendar: cal)
        let far = await store.dndActive(at: dt(28, 12, 0, cal))
        XCTAssertTrue(far)
        await store.refresh(now: dt(28, 12, 0, cal))
        let stillOn = await MainActor.run { store.dndOn }
        XCTAssertTrue(stillOn)
        await store.disableDND()
        let off = await MainActor.run { store.dndOn }
        XCTAssertFalse(off)
    }

    func testRefreshKeepsFutureDND() async {
        let cal = fixedCalendar()
        let store = await QuietHoursStore(defaults: isolatedDefaults())
        await store.enableDND(.fourHours, now: dt(24, 12, 0, cal), calendar: cal)
        await store.refresh(now: dt(24, 13, 0, cal))
        let stillOn = await MainActor.run { store.dndOn }
        XCTAssertTrue(stillOn)
    }

    func testIsQuietSweepsExpiredDND() async {
        // isQuiet sweeps first, so a stale toggle never sticks on.
        let cal = fixedCalendar()
        let store = await QuietHoursStore(defaults: isolatedDefaults())
        await store.enableDND(.thirtyMinutes, now: dt(24, 12, 0, cal), calendar: cal)
        let quiet = await store.isQuiet(at: dt(24, 13, 0, cal), calendar: cal)
        XCTAssertFalse(quiet)
        let dndOn = await MainActor.run { store.dndOn }
        XCTAssertFalse(dndOn)
    }

    func testLaunchSweepsExpiredDND() async {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: QuietHoursStore.dndOnKey)
        defaults.set(Date(timeIntervalSince1970: 1000).timeIntervalSince1970,
                     forKey: QuietHoursStore.dndUntilKey)
        let store = await QuietHoursStore(defaults: defaults)
        let (dndOn, until) = await MainActor.run { (store.dndOn, store.dndUntil) }
        XCTAssertFalse(dndOn)
        XCTAssertNil(until)
    }

    func testDNDStatus() async {
        let cal = fixedCalendar()
        let store = await QuietHoursStore(defaults: isolatedDefaults())
        let off = await store.dndStatus()
        XCTAssertEqual(off, "off")
        await store.enableDND(.untilTurnedOff, now: dt(24, 12, 0, cal), calendar: cal)
        let indefinite = await store.dndStatus(at: dt(24, 12, 0, cal), calendar: cal)
        XCTAssertEqual(indefinite, "on until turned off")
        await store.enableDND(.oneHour, now: dt(24, 12, 0, cal), calendar: cal)
        let timed = await store.dndStatus(at: dt(24, 12, 0, cal), calendar: cal)
        XCTAssertEqual(timed, "on until 13:00")
    }

    // MARK: store — schedule + combined quiet

    func testIsQuietSources() async {
        let cal = fixedCalendar()
        let store = await QuietHoursStore(defaults: isolatedDefaults())
        await MainActor.run {
            store.windowEnabled = true
            store.startMinutes = 22 * 60
            store.endMinutes = 7 * 60
            store.days = [1, 2, 3, 4, 5, 6, 7]
        }
        let night = await store.isQuiet(at: dt(24, 23, 0, cal), calendar: cal)
        XCTAssertTrue(night)
        let noon = await store.isQuiet(at: dt(24, 12, 0, cal), calendar: cal)
        XCTAssertFalse(noon)
        // DND alone quiets the gap the schedule leaves open.
        await store.enableDND(.oneHour, now: dt(24, 12, 0, cal), calendar: cal)
        let dndNoon = await store.isQuiet(at: dt(24, 12, 0, cal), calendar: cal)
        XCTAssertTrue(dndNoon)
    }

    func testNoteSuppressed() async {
        let store = await QuietHoursStore(defaults: isolatedDefaults())
        await store.noteSuppressed()
        await store.noteSuppressed()
        let count = await MainActor.run { store.suppressedCount }
        XCTAssertEqual(count, 2)
    }

    func testPersistenceRoundTrip() async {
        let defaults = isolatedDefaults()
        let first = await QuietHoursStore(defaults: defaults)
        let cal = fixedCalendar()
        await MainActor.run {
            first.windowEnabled = true
            first.startMinutes = 21 * 60
            first.endMinutes = 6 * 60 + 30
            first.days = [2, 3, 4, 5, 6]
        }
        // DND clocked an hour ago with a 30-minute expiry: already dead,
        // so the relaunch sweep clears it (live-expiry persistence is
        // covered by testPersistenceKeepsLiveDND).
        await first.enableDND(
            .thirtyMinutes, now: Date(timeIntervalSinceNow: -3600), calendar: cal)
        let second = await QuietHoursStore(defaults: defaults)
        let snap = await MainActor.run {
            (second.windowEnabled, second.startMinutes, second.endMinutes,
             second.days, second.dndOn, second.dndUntil, second.pendingDNDOption)
        }
        XCTAssertTrue(snap.0)
        XCTAssertEqual(snap.1, 21 * 60)
        XCTAssertEqual(snap.2, 6 * 60 + 30)
        XCTAssertEqual(snap.3, [2, 3, 4, 5, 6])
        XCTAssertFalse(snap.4)
        XCTAssertNil(snap.5)
        XCTAssertEqual(snap.6, .thirtyMinutes)
    }

    func testPersistenceKeepsLiveDND() async {
        let defaults = isolatedDefaults()
        let first = await QuietHoursStore(defaults: defaults)
        await first.enableDND(.fourHours) // clocked at real now — still live
        let second = await QuietHoursStore(defaults: defaults)
        let (dndOn, until) = await MainActor.run { (second.dndOn, second.dndUntil) }
        XCTAssertTrue(dndOn)
        XCTAssertNotNil(until)
    }

    // MARK: time bridges

    func testTimeOfDayRoundTrip() {
        let cal = fixedCalendar()
        let now = dt(24, 15, 45, cal)
        for minutes in [0, 7 * 60, 12 * 60 + 30, 22 * 60, 23 * 60 + 59] {
            let date = QuietHoursStore.timeOfDay(minutes: minutes, now: now, calendar: cal)
            XCTAssertEqual(QuietHoursStore.minutes(ofTime: date, calendar: cal), minutes)
        }
    }

    // MARK: suppression-count gate

    func testGate() {
        // Quiet + banners on + either path posting → count once.
        XCTAssertTrue(QuietHoursGate.countsSuppression(
            quiet: true, bannersEnabled: true, rulesNotified: true, legacyWouldPost: false))
        XCTAssertTrue(QuietHoursGate.countsSuppression(
            quiet: true, bannersEnabled: true, rulesNotified: false, legacyWouldPost: true))
        XCTAssertTrue(QuietHoursGate.countsSuppression(
            quiet: true, bannersEnabled: true, rulesNotified: true, legacyWouldPost: true))
        // Not quiet → the banners posted (nothing suppressed).
        XCTAssertFalse(QuietHoursGate.countsSuppression(
            quiet: false, bannersEnabled: true, rulesNotified: true, legacyWouldPost: true))
        // Banners off → nothing would have posted anyway.
        XCTAssertFalse(QuietHoursGate.countsSuppression(
            quiet: true, bannersEnabled: false, rulesNotified: true, legacyWouldPost: true))
        // Neither path would post → nothing suppressed.
        XCTAssertFalse(QuietHoursGate.countsSuppression(
            quiet: true, bannersEnabled: true, rulesNotified: false, legacyWouldPost: false))
    }

    // MARK: rules-first contract

    func testRulesSkipStaysSkipWhileQuiet() async {
        // Quiet never resurrects a rules skip: the decision is computed
        // without any quiet input, so a skip stays a skip.
        let store = await QuietHoursStore(defaults: isolatedDefaults())
        await MainActor.run { store.dndOn = true } // indefinite DND: quiet now
        let quiet = await store.isQuietNow
        XCTAssertTrue(quiet)
        var cfg = RulesConfig(owner: RulesOwner(displayName: "Me", mri: "8:orgid:me"))
        cfg.notifyRules = [NotifyRule(kind: NotifyRule.skipMyMessages)]
        cfg.applyRules()
        let own = RealtimeMessage(
            chatID: "19:chat@thread.v2", msgId: "m1", sender: "Me",
            senderID: "8:orgid:me", text: "echo", time: "2026-09-24T12:00:00Z",
            isEdit: false, messageType: "Text")
        XCTAssertEqual(
            ChatFilter.decide(message: own, chatDisplayName: "Team Chat",
                              ownerMRI: "8:orgid:me", rules: cfg),
            .skip(reason: "own-message"))
        XCTAssertFalse(UnreadStore.shouldCount(
            decision: .skip(reason: "own-message"), chatID: own.chatID, openChatID: nil))
    }

    func testUnreadAccruesFromNotifyWhileQuiet() async {
        // Rules notify + quiet: the banner drops but in-app unread still
        // accrues (the ingest gate reads the decision only — no quiet input).
        let store = await QuietHoursStore(defaults: isolatedDefaults())
        await MainActor.run { store.dndOn = true }
        let quiet = await store.isQuietNow
        XCTAssertTrue(quiet)
        XCTAssertTrue(UnreadStore.shouldCount(
            decision: .notify(reason: "chat-message"),
            chatID: "19:chat@thread.v2", openChatID: nil))
        // …except the open chat, which never accrues (unchanged rule).
        XCTAssertFalse(UnreadStore.shouldCount(
            decision: .notify(reason: "chat-message"),
            chatID: "19:chat@thread.v2", openChatID: "19:chat@thread.v2"))
    }

    // MARK: diagnostics line

    func testQuietHoursLine() {
        XCTAssertEqual(
            DiagnosticsFormat.quietHoursLine(dnd: false, schedule: false, suppressed: 0),
            "off · 0 suppressed")
        XCTAssertEqual(
            DiagnosticsFormat.quietHoursLine(dnd: true, schedule: false, suppressed: 1),
            "on (DND) · 1 suppressed")
        XCTAssertEqual(
            DiagnosticsFormat.quietHoursLine(dnd: false, schedule: true, suppressed: 3),
            "on (schedule) · 3 suppressed")
        XCTAssertEqual(
            DiagnosticsFormat.quietHoursLine(dnd: true, schedule: true, suppressed: 12),
            "on (schedule + DND) · 12 suppressed")
    }
}
