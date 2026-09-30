// Guards (regfix-a): presence duration / lock, Do Not Disturb auto-expire,
// multiple quiet-hours windows, schedule-entry editing, density metrics.
// All fakes: no core, no network, no real defaults, time explicit.
import XCTest

@testable import OstMacCore

private final class Wants: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ w: String) { lock.lock(); list.append(w); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return list }
}

private func echo(_ s: PresenceStatus) -> PresenceResponse {
    PresenceResponse(ok: true, availability: s.availability, activity: s.availability)
}

@MainActor
final class RegfixPresenceGuardTests: XCTestCase {
    private func make() -> (PresenceStore, PresenceTruthStore, Wants) {
        let wants = Wants()
        let presence = PresenceStore(
            ownFetcher: { PresenceResponse(ok: true, availability: "Available", activity: "Available") },
            setFetcher: { want in wants.add(want); return echo(PresenceStatus(rawValue: want) ?? .available) },
            userFetcher: { _ in throw NSError(domain: "fake", code: 1) },
            resolveFetcher: { _ in throw NSError(domain: "fake", code: 1) })
        let truth = PresenceTruthStore(
            defaults: MemoryDefaults(),
            setFetcher: { want in wants.add(want); return echo(PresenceStatus(rawValue: want) ?? .available) },
            presence: presence)
        truth.idleProvider = { 0 }
        return (presence, truth, wants)
    }

    private func settle(_ wants: Wants, count: Int) async {
        for _ in 0 ..< 100 where wants.values.count < count {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testBeRightBackAndAppearAwayAreRealStatuses() {
        XCTAssertEqual(PresenceStatus.brb.title, "Be right back")
        XCTAssertEqual(PresenceStatus.away.title, "Appear away")
        XCTAssertEqual(PresenceStatus.brb.availability, "BeRightBack")
        XCTAssertNotEqual(PresenceStatus.brb, PresenceStatus.away)
    }

    func testTimedDurationPinsStatusAsALockThatExpires() async {
        let (_, truth, wants) = make()
        truth.liveWrites = true
        truth.resetAfter = .oneHour
        let t0 = Date()
        truth.choose(status: .dnd, now: t0)
        XCTAssertEqual(truth.lock?.status, .dnd)
        XCTAssertTrue(truth.isLocked(now: t0.addingTimeInterval(59 * 60)), "held inside the hour")
        XCTAssertFalse(truth.isLocked(now: t0.addingTimeInterval(61 * 60)), "released after the hour")
        await settle(wants, count: 1)
        XCTAssertEqual(wants.values, ["dnd"])
    }

    func testDurationChoiceSurvivesRelaunch() {
        let defaults = MemoryDefaults()
        let a = PresenceTruthStore(defaults: defaults, presence: nil)
        a.resetAfter = .fourHours
        let b = PresenceTruthStore(defaults: defaults, presence: nil)
        XCTAssertEqual(b.resetAfter, .fourHours)
    }

    func testNoDurationSetsPlainlyAndReleasesAnEarlierLock() async {
        let (presence, truth, wants) = make() // truth holds presence weakly
        defer { withExtendedLifetime(presence) {} }
        truth.liveWrites = true
        truth.resetAfter = .fourHours
        truth.choose(status: .dnd)
        await settle(wants, count: 1)
        XCTAssertTrue(truth.isLocked())
        truth.resetAfter = .untilOff
        truth.choose(status: .brb)
        XCTAssertNil(truth.lock, "a manual set must not be reasserted back to the old lock")
        await settle(wants, count: 2)
        XCTAssertEqual(wants.values, ["dnd", "brb"])
    }

    func testIdleMacFlipsAvailableToAwayAndBackOnInput() async {
        let (presence, truth, wants) = make()
        truth.liveWrites = true
        await presence.refreshOwn()
        truth.idleProvider = { 900 }
        truth.tick()
        await settle(wants, count: 1)
        XCTAssertEqual(wants.values, ["away"], "idle Mac -> Away")
        for _ in 0 ..< 100 where presence.own?.availability != "Away" {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        truth.idleProvider = { 0 }
        truth.tick(now: Date().addingTimeInterval(1))
        await settle(wants, count: 2)
        XCTAssertEqual(wants.values, ["away", "available"], "input back -> Available")
    }

    func testDoNotDisturbAutoExpires() {
        let q = QuietHoursStore(defaults: MemoryDefaults())
        let t0 = Date()
        q.enableDND(.thirtyMinutes, now: t0)
        XCTAssertTrue(q.dndActive(at: t0.addingTimeInterval(29 * 60)))
        XCTAssertFalse(q.dndActive(at: t0.addingTimeInterval(31 * 60)))
        q.refresh(now: t0.addingTimeInterval(31 * 60))
        XCTAssertFalse(q.dndOn, "toggle flips off by itself")
    }

    func testAutoChangeUndoBannerAndMenuTitle() {
        let offer = PresenceUndoOffer(status: .available, text: "Teams moved you to Away — back to Available?",
                                      expiresAt: Date().addingTimeInterval(30))
        let content = PresenceUndoInfo.makeContent(offer)
        XCTAssertEqual(content.categoryIdentifier, PresenceUndoInfo.categoryID)
        XCTAssertEqual(content.body, offer.text)
        XCTAssertNil(content.sound, "quiet banner")
        XCTAssertEqual(PresenceUndoInfo.category.actions.map(\.identifier), [PresenceUndoInfo.undoActionID])
        XCTAssertEqual(offer.undoMenuTitle, "Undo — Back to Available")
    }

    func testTwoQuietWindowsWithDifferentWeekdays() {
        let q = QuietHoursStore(defaults: MemoryDefaults())
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        q.windows[0] = QuietHoursWindow(enabled: true, startMinutes: 22 * 60, endMinutes: 23 * 60, days: [2]) // Mon
        XCTAssertTrue(q.addWindow(QuietHoursWindow(enabled: true, startMinutes: 12 * 60, endMinutes: 13 * 60, days: [7]))) // Sat
        func date(_ d: Int, _ h: Int) -> Date { // 2026-09-28 is a Monday
            cal.date(from: DateComponents(year: 2026, month: 9, day: d, hour: h, minute: 30))!
        }
        XCTAssertTrue(q.scheduleActive(at: date(28, 22), calendar: cal), "Mon 22:30 window 1")
        XCTAssertTrue(q.scheduleActive(at: date(26, 12), calendar: cal), "Sat 12:30 window 2")
        XCTAssertFalse(q.scheduleActive(at: date(29, 22), calendar: cal), "Tue 22:30 in no window")
        XCTAssertFalse(q.scheduleActive(at: date(28, 12), calendar: cal), "Mon 12:30 in no window")
    }

    func testEditedPresenceScheduleEntryPersists() {
        let defaults = MemoryDefaults()
        let s = PresenceScheduleStore(defaults: defaults, setFetcher: { _ in echo(.busy) })
        XCTAssertTrue(s.addEntry(PresenceScheduleEntry(window: QuietHoursWindow(enabled: true))))
        s.entries[0].status = .brb
        s.entries[0].window.days = [2, 4]
        s.entries[0].window.startMinutes = 9 * 60
        let again = PresenceScheduleStore(defaults: defaults, setFetcher: { _ in echo(.busy) })
        XCTAssertEqual(again.entries.first?.status, .brb)
        XCTAssertEqual(again.entries.first?.window.days, [2, 4])
        XCTAssertEqual(again.entries.first?.window.startMinutes, 9 * 60)
    }

    func testCompactDensityIsStrictlyTighterAndComfortableIsUnchanged() {
        let c = MessageDensity.comfortable.metrics, k = MessageDensity.compact.metrics
        XCTAssertEqual([c.headerTop, c.continuationTop, c.rowBottom, c.bubbleHorizontal, c.bubbleVertical,
                        c.separatorVertical, c.chatRowVertical, c.chatAvatar],
                       [8, 2, 2, 12, 8, 8, 3, 28], "Comfortable = the shipped layout")
        XCTAssertLessThan(k.headerTop, c.headerTop)
        XCTAssertLessThan(k.bubbleVertical, c.bubbleVertical)
        XCTAssertLessThan(k.separatorVertical, c.separatorVertical)
        XCTAssertLessThan(k.chatRowVertical, c.chatRowVertical)
        XCTAssertLessThan(k.chatAvatar, c.chatAvatar)
    }
}
