// SnoozeTests.swift — d2-send lane: time-boxed per-chat snooze.
// - Durations incl overnight Until-8-AM math (before/after 8 AM) and
//   always-next-day Tomorrow-8-AM.
// - Expired entries never match (boundary: now == expiry is awake).
// - Sweep purges expired, keeps live, persists.
// - ChatFilter "snoozed" skips banners + unread incl @me mention
//   (absolute: mentions do NOT break through, Settings-mute precedent).
// - Unsnooze restores notify; persistence round-trips.
import XCTest

@testable import OstMacCore

final class SnoozeTests: XCTestCase {
    // MARK: helpers

    func fixedCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// 2026-09-<day> <hour>:<minute> UTC.
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
        UserDefaults(suiteName: "test-snooze-\(UUID().uuidString)") ?? .standard
    }

    func msg(
        chatID: String = "19:snooze@thread.v2",
        text: String = "hello",
        raw: String? = nil
    ) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chatID, msgId: "m1", sender: "Megan",
            senderID: "8:orgid:megan", text: text, time: "2026-09-24T10:00:00Z",
            isEdit: false, editedID: nil, raw: raw,
            messageType: "Text")
    }

    func cfg() -> RulesConfig {
        var c = RulesConfig(owner: RulesOwner(displayName: "Me", mri: "8:orgid:me"))
        c.applyRules()
        return c
    }

    // MARK: duration math

    func testFixedDurations() {
        let cal = fixedCalendar()
        let now = dt(24, 10, 0, cal)
        XCTAssertEqual(
            SnoozeDuration.oneHour.expiryDate(now: now, calendar: cal),
            dt(24, 11, 0, cal))
        XCTAssertEqual(
            SnoozeDuration.fourHours.expiryDate(now: now, calendar: cal),
            dt(24, 14, 0, cal))
    }

    func testUntilMorningBefore8() {
        // 06:30 → today's 08:00.
        let cal = fixedCalendar()
        XCTAssertEqual(
            SnoozeDuration.untilMorning.expiryDate(
                now: dt(24, 6, 30, cal), calendar: cal),
            dt(24, 8, 0, cal))
    }

    func testUntilMorningAfter8() {
        // 10:00 → tomorrow's 08:00 (overnight arm).
        let cal = fixedCalendar()
        XCTAssertEqual(
            SnoozeDuration.untilMorning.expiryDate(
                now: dt(24, 10, 0, cal), calendar: cal),
            dt(25, 8, 0, cal))
    }

    func testTomorrowMorningAlwaysNextDay() {
        // 06:30 → TOMORROW's 08:00 (never today's, even when ahead).
        let cal = fixedCalendar()
        XCTAssertEqual(
            SnoozeDuration.tomorrowMorning.expiryDate(
                now: dt(24, 6, 30, cal), calendar: cal),
            dt(25, 8, 0, cal))
        XCTAssertEqual(
            SnoozeDuration.tomorrowMorning.expiryDate(
                now: dt(24, 10, 0, cal), calendar: cal),
            dt(25, 8, 0, cal))
    }

    func testDurationLabels() {
        XCTAssertEqual(SnoozeDuration.oneHour.label, "1 hour")
        XCTAssertEqual(SnoozeDuration.fourHours.label, "4 hours")
        XCTAssertEqual(SnoozeDuration.untilMorning.label, "Until 8 AM")
        XCTAssertEqual(SnoozeDuration.tomorrowMorning.label, "Tomorrow 8 AM")
    }

    // MARK: store match + sweep

    func testSnoozeAndMatch() async {
        let cal = fixedCalendar()
        let now = dt(24, 10, 0, cal)
        let store = await SnoozeStore(defaults: isolatedDefaults())
        let id = "19:snooze@thread.v2"
        await MainActor.run { store.snooze(chatID: id, duration: .oneHour, now: now, calendar: cal) }
        let hit = await MainActor.run { store.isSnoozed(chatID: id, now: now) }
        XCTAssertTrue(hit)
        let miss = await MainActor.run { store.isSnoozed(chatID: "19:other@thread.v2", now: now) }
        XCTAssertFalse(miss)
    }

    func testExpiredNeverMatches() async {
        let cal = fixedCalendar()
        let now = dt(24, 10, 0, cal)
        let store = await SnoozeStore(defaults: isolatedDefaults())
        let id = "19:snooze@thread.v2"
        await MainActor.run { store.snooze(chatID: id, duration: .oneHour, now: now, calendar: cal) }
        // Boundary: now == expiry is awake (strict <).
        let at = await MainActor.run { store.isSnoozed(chatID: id, now: dt(24, 11, 0, cal)) }
        XCTAssertFalse(at)
        let after = await MainActor.run { store.isSnoozed(chatID: id, now: dt(24, 12, 0, cal)) }
        XCTAssertFalse(after)
        // Active set drops it too (lazy sweep on every decide).
        let ids = await MainActor.run { store.activeIDs(now: dt(24, 12, 0, cal)) }
        XCTAssertFalse(ids.contains(id))
    }

    func testSweepPurgesExpiredKeepsLive() async {
        let cal = fixedCalendar()
        let now = dt(24, 10, 0, cal)
        let store = await SnoozeStore(defaults: isolatedDefaults())
        await MainActor.run {
            store.snooze(chatID: "19:old@thread.v2", duration: .oneHour, now: dt(24, 8, 0, cal), calendar: cal)
            store.snooze(chatID: "19:live@thread.v2", duration: .fourHours, now: now, calendar: cal)
        }
        await MainActor.run { store.refresh(now: now) }
        let map = await MainActor.run { store.expiries }
        XCTAssertNil(map["19:old@thread.v2"])
        XCTAssertNotNil(map["19:live@thread.v2"])
    }

    func testUnsnoozeRestores() async {
        let cal = fixedCalendar()
        let now = dt(24, 10, 0, cal)
        let store = await SnoozeStore(defaults: isolatedDefaults())
        let id = "19:snooze@thread.v2"
        await MainActor.run {
            store.snooze(chatID: id, duration: .fourHours, now: now, calendar: cal)
            store.unsnooze(chatID: id)
        }
        let hit = await MainActor.run { store.isSnoozed(chatID: id, now: now) }
        XCTAssertFalse(hit)
        // Unknown ids are a no-op (never crash).
        await MainActor.run { store.unsnooze(chatID: "19:nope@thread.v2") }
    }

    func testBlankChatIDNoOp() async {
        let cal = fixedCalendar()
        let store = await SnoozeStore(defaults: isolatedDefaults())
        await MainActor.run {
            store.snooze(chatID: "  ", duration: .oneHour, now: dt(24, 10, 0, cal), calendar: cal)
        }
        let map = await MainActor.run { store.expiries }
        XCTAssertTrue(map.isEmpty)
    }

    func testSnoozeLabel() async {
        let cal = fixedCalendar()
        let now = dt(24, 10, 0, cal)
        let store = await SnoozeStore(defaults: isolatedDefaults())
        let id = "19:snooze@thread.v2"
        await MainActor.run { store.snooze(chatID: id, duration: .oneHour, now: now, calendar: cal) }
        let label = await MainActor.run {
            store.snoozeLabel(for: id, now: now, calendar: cal)
        }
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.hasPrefix("Snoozed until "))
        let gone = await MainActor.run {
            store.snoozeLabel(for: "19:other@thread.v2", now: now, calendar: cal)
        }
        XCTAssertNil(gone)
        let expired = await MainActor.run {
            store.snoozeLabel(for: id, now: dt(24, 12, 0, cal), calendar: cal)
        }
        XCTAssertNil(expired)
    }

    func testPersistenceRoundTrip() async {
        // Live now: the relaunch sweep purges wall-clock-past entries,
        // so a fixed 2026-09-24 fixture would (correctly) not survive.
        let cal = fixedCalendar()
        let now = Date()
        let defaults = isolatedDefaults()
        let id = "19:snooze@thread.v2"
        let first = await SnoozeStore(defaults: defaults)
        await MainActor.run { first.snooze(chatID: id, duration: .fourHours, now: now, calendar: cal) }
        let second = await SnoozeStore(defaults: defaults)
        let hit = await MainActor.run { second.isSnoozed(chatID: id, now: now) }
        XCTAssertTrue(hit)
    }

    // MARK: filter gate (absolute, mentions incl)

    func testSnoozedSkipsPlain() {
        let d = ChatFilter.decide(
            message: msg(), chatDisplayName: "Team Chat",
            ownerMRI: "8:orgid:me", rules: cfg(),
            snoozedChatIDs: ["19:snooze@thread.v2"])
        XCTAssertEqual(d, .skip(reason: "snoozed"))
    }

    func testSnoozedSkipsOwnerMention() {
        // Absolute: an elevated @me mention does NOT break through.
        let m = msg(text: "hi Me", raw: #"hi <at id="0">@Me</at>"#)
        let d = ChatFilter.decide(
            message: m, chatDisplayName: "Team Chat",
            ownerMRI: "8:orgid:me", rules: cfg(),
            snoozedChatIDs: ["19:snooze@thread.v2"])
        XCTAssertEqual(d, .skip(reason: ChatFilter.snoozedReason))
        // ...and never accrues unread.
        XCTAssertFalse(UnreadStore.shouldCount(
            decision: d, chatID: m.chatID, openChatID: nil))
    }

    func testUnsnoozedNotifiesAgain() {
        // No re-decide of old events: a fresh event after expiry notifies
        // through the normal path.
        let d = ChatFilter.decide(
            message: msg(), chatDisplayName: "Team Chat",
            ownerMRI: "8:orgid:me", rules: cfg(),
            snoozedChatIDs: [])
        XCTAssertEqual(d, .notify(reason: "chat-message"))
    }

    func testSnoozeStatefulOverload() {
        // The stateful (meeting-window) overload carries the gate too.
        var dedup = MeetingStartDedup()
        let d = ChatFilter.decide(
            message: msg(), chatDisplayName: "Team Chat",
            ownerMRI: "8:orgid:me", rules: cfg(),
            meetingDedup: &dedup, now: Date(),
            snoozedChatIDs: ["19:snooze@thread.v2"])
        XCTAssertEqual(d, .skip(reason: "snoozed"))
    }

    func testSnoozedSkipsViaUnreadIngest() async {
        // Full path: stateful ingest decides + accrues nothing.
        let dock = FakeDockBadge()
        let unread = UnreadStore(dock: dock)
        let decision = await MainActor.run {
            var dedup = MeetingStartDedup()
            return unread.ingest(
                message: self.msg(), chatDisplayName: "Team Chat",
                ownerMRI: "8:orgid:me", rules: self.cfg(),
                meetingDedup: &dedup, now: Date(),
                openChatID: nil, snoozedChatIDs: ["19:snooze@thread.v2"])
        }
        XCTAssertEqual(decision, .skip(reason: "snoozed"))
        let count = await MainActor.run { unread.count(for: "19:snooze@thread.v2") }
        XCTAssertEqual(count, 0)
    }
}
