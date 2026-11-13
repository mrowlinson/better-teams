// ActivityBadgeTests.swift — rail Activity badge (owner 09-30): >1 s of
// viewing dismisses the badge and restarts the counter; nothing is
// marked read; the counter baseline survives relaunch. Injected clock
// and timer, isolated UserDefaults suites, no windows.
import XCTest

@testable import OstMacCore

@MainActor
final class ActivityBadgeTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "test-activity-badge-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func store() -> ActivityStore { ActivityStore(defaults: defaults) }

    private func mention(_ s: ActivityStore, _ id: String, chat: String = "19:chat@thread.v2") {
        s.ingest(
            realtime: RealtimeMessage(
                chatID: chat, msgId: id, sender: "Doe, Jane", senderID: nil, text: "hi",
                time: "2026-09-25T12:00:00Z", isEdit: false,
                raw: "<at>Smith, Alex</at> \(id)", reactions: nil),
            ownName: "Smith, Alex", ownerMRI: nil, openChatID: nil, chatName: "General")
    }

    /// Manual clock + timer: `advance` moves time and fires due timers.
    private final class Rig {
        var t = Date(timeIntervalSince1970: 1_000_000)
        var timers: [(due: Date, id: Int, fire: @MainActor () -> Void)] = []
        var nextID = 0
        var scheduled = 0
        let dwell: ActivityBadgeDwell
        let store: ActivityStore
        var dismissals = 0

        @MainActor init(_ store: ActivityStore) {
            self.store = store
            var rig: Rig!
            dwell = ActivityBadgeDwell(
                now: { rig.t },
                schedule: { delay, fire in
                    let id = rig.nextID
                    rig.nextID += 1
                    rig.scheduled += 1
                    rig.timers.append((rig.t.addingTimeInterval(delay), id, fire))
                    return { rig.timers.removeAll { $0.id == id } }
                },
                badgeCount: { store.badgeCount },
                dismiss: { rig.dismissals += 1; store.dismissBadge() })
            rig = self
        }

        @MainActor func advance(_ s: TimeInterval) {
            t = t.addingTimeInterval(s)
            for timer in timers.filter({ $0.due <= t }).sorted(by: { $0.due < $1.due }) {
                timers.removeAll { $0.id == timer.id }
                timer.fire()
            }
        }
    }

    // MARK: - Dwell

    func testViewingUnderOneSecondKeepsBadge() {
        let s = store()
        mention(s, "m1")
        let rig = Rig(s)
        rig.dwell.update(viewing: true)
        rig.advance(0.9)
        XCTAssertEqual(s.badgeCount, 1, "negative control: 0.9 s does not dismiss")
        XCTAssertEqual(rig.dismissals, 0)
        rig.dwell.update(viewing: false)
        rig.advance(5)
        XCTAssertEqual(s.badgeCount, 1, "leaving early cancels the timer")
    }

    func testViewingPastOneSecondDismissesBadgeAndRestartsCounter() {
        let s = store()
        mention(s, "m1")
        mention(s, "m2")
        let rig = Rig(s)
        XCTAssertEqual(s.badgeCount, 2)
        rig.dwell.update(viewing: true)
        rig.advance(0.9)
        XCTAssertEqual(s.badgeCount, 2)
        rig.advance(0.2)
        XCTAssertEqual(s.badgeCount, 0, "1.1 s continuous viewing dismisses")
        mention(s, "m3")
        XCTAssertEqual(s.badgeCount, 1, "counter restarts: only the new arrival")
    }

    func testEachVisitNeedsItsOwnContinuousSecond() {
        let s = store()
        mention(s, "m1")
        let rig = Rig(s)
        rig.dwell.update(viewing: true)
        rig.advance(0.6)
        rig.dwell.update(viewing: false)
        rig.advance(10)
        rig.dwell.update(viewing: true)
        rig.advance(0.6)
        XCTAssertEqual(s.badgeCount, 1, "0.6 + 0.6 across two visits is not 1 s")
        rig.advance(0.5)
        XCTAssertEqual(s.badgeCount, 0)
    }

    func testArrivalWhileAlreadyPastDwellDismissesAtOnce() {
        let s = store()
        let rig = Rig(s)
        rig.dwell.update(viewing: true)
        rig.advance(30)
        mention(s, "m1")
        rig.dwell.storeChanged()
        XCTAssertEqual(s.badgeCount, 0, "no badge flashes under the viewer")
        XCTAssertEqual(rig.dismissals, 1)
    }

    func testArrivalInsideDwellWaitsOutTheRemainder() {
        let s = store()
        let rig = Rig(s)
        rig.dwell.update(viewing: true)
        rig.advance(0.5)
        mention(s, "m1")
        rig.dwell.storeChanged()
        rig.advance(0.4)
        XCTAssertEqual(s.badgeCount, 1)
        rig.advance(0.2)
        XCTAssertEqual(s.badgeCount, 0)
    }

    func testViewingRule() {
        let base = (activitySelected: true, searching: false, appActive: true, windowVisible: true)
        func v(_ a: Bool, _ s: Bool, _ p: Bool, _ w: Bool) -> Bool {
            ActivityBadgeDwell.isViewing(activitySelected: a, searching: s, appActive: p, windowVisible: w)
        }
        XCTAssertTrue(v(base.0, base.1, base.2, base.3), "control")
        XCTAssertFalse(v(false, false, true, true), "other section")
        XCTAssertFalse(v(true, true, true, true), "searching")
        XCTAssertFalse(v(true, false, false, true), "app inactive")
        XCTAssertFalse(v(true, false, true, false), "window hidden")
    }

    // MARK: - No read-state writes

    func testDismissMarksNothingRead() {
        let s = store()
        var cleared: [String] = []
        s.onMentionFlagsCleared = { cleared.append($0) }
        mention(s, "m1")
        mention(s, "m2", chat: "19:other@thread.v2")
        let before = s.items
        s.dismissBadge()
        XCTAssertEqual(s.items, before, "items (incl. review flags) untouched")
        XCTAssertEqual(s.unreviewedCount, 2)
        XCTAssertEqual(s.storedCount, 2)
        XCTAssertTrue(cleared.isEmpty, "no MentionStore flag cleared")
    }

    // MARK: - Rows stay listed (R1)

    func testMarkAllReviewedKeepsRowsAndStyleFlips() {
        let s = store()
        mention(s, "m1")
        mention(s, "m2")
        s.markAllReviewed()
        XCTAssertEqual(s.items.map(\.id).count, 2)
        XCTAssertTrue(s.items.allSatisfy(\.reviewed))
        XCTAssertEqual(s.badgeCount, 0)
        s.markUnreviewed(id: s.items[0].id)
        XCTAssertEqual(s.unreviewedCount, 1, "still reversible")
    }

    func testMarkAllReviewedStillFiresMentionFlagHook() {
        let s = store()
        var cleared: [String] = []
        s.onMentionFlagsCleared = { cleared.append($0) }
        mention(s, "m1", chat: "c1")
        s.markAllReviewed()
        XCTAssertEqual(cleared, ["c1"])
        s.markAllReviewed()
        XCTAssertEqual(cleared, ["c1"], "second call is a no-op")
    }

    // MARK: - Persistence (R4)

    func testBaselineSurvivesRelaunch() {
        let a = store()
        mention(a, "m1")
        a.dismissBadge()
        let b = store()
        XCTAssertEqual(b.storedCount, 1)
        XCTAssertEqual(b.badgeCount, 0, "old item does not re-badge after relaunch")
        XCTAssertEqual(b.unreviewedCount, 1, "still unread")
        mention(b, "m2")
        XCTAssertEqual(b.badgeCount, 1)
    }

    func testControlWithoutDismissRelaunchStillBadges() {
        let a = store()
        mention(a, "m1")
        XCTAssertEqual(store().badgeCount, 1, "control: no dismissal, the item badges")
    }
}
