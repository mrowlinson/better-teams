// FixPack3Tests (FIXPACK3): presence-schedule edit re-apply (R4), the
// notification category set (R5), delete minors (R7a/R7b). Fake wires only;
// nothing touches the network, a profile or real defaults.
import UserNotifications
import XCTest

@testable import OstMacCore

private final class HoldWire: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var calls = 0
    private var failuresLeft: Int
    private let blockFirst: Bool
    init(failures: Int, blockFirst: Bool = false) { failuresLeft = failures; self.blockFirst = blockFirst }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func release() { gate.signal() }
    func send(_: String, _: String) throws {
        lock.lock()
        calls += 1
        let first = calls == 1
        lock.unlock()
        if first && blockFirst { gate.wait() }
        lock.lock(); defer { lock.unlock() }
        if failuresLeft > 0 { failuresLeft -= 1; throw URLError(.timedOut) }
    }
}

private final class WantLog: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [String] = []
    func add(_ s: String) { lock.lock(); v.append(s); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return v }
}

@MainActor
final class FixPack3Tests: XCTestCase {
    // MARK: R5

    func testSystemNotificationCategorySetCarriesEveryPostedCategory() {
        let reply = UNTextInputNotificationAction(identifier: "r", title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let ids = Set(SystemNotificationCenter.categories(reply: reply).map(\.identifier))
        XCTAssertEqual(ids, [SystemNotificationCenter.categoryID, MentionAlert.categoryID, OmCallInfo.categoryID,
                             MeetingNotifyInfo.categoryID, PresenceUndoInfo.categoryID])
        XCTAssertTrue(ids.contains("OM_MEETING"), "the Join banner keeps its category after any message post")
    }

    // MARK: R4

    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(_ hour: Int) -> Date {
        var d = DateComponents(); d.year = 2026; d.month = 9; d.day = 25; d.hour = hour
        return cal().date(from: d)!
    }

    private func entry(_ status: PresenceStatus) -> PresenceScheduleEntry {
        PresenceScheduleEntry(window: QuietHoursWindow(enabled: true, startMinutes: 9 * 60, endMinutes: 17 * 60),
                              status: status)
    }

    private func settled(_ s: PresenceScheduleStore) async {
        for _ in 0 ..< 400 where s.inflight { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testEditingTheActiveEntryReappliesOnTheNextTickNotTheNextTransition() async {
        let log = WantLog()
        let defaults = UserDefaults(suiteName: "fp3-\(UUID().uuidString)")!
        let s = PresenceScheduleStore(defaults: defaults, setFetcher: { want in
            log.add(want)
            return PresenceResponse(ok: true, availability: want, activity: want)
        })
        s.clock = { self.at(10) }
        s.clockCalendar = cal()
        s.enabled = true
        s.entries = [entry(.busy)]
        s.tick(now: at(10), calendar: cal())
        await settled(s)
        XCTAssertEqual(log.values, ["busy"])
        // Same window, inside the refresh line: control, nothing more is sent.
        s.tick(now: at(10).addingTimeInterval(120), calendar: cal())
        await settled(s)
        XCTAssertEqual(log.values, ["busy"], "control: no re-set without an edit")

        // Edit the active entry's status: the very next tick applies it.
        s.entries[0].status = .away
        s.tick(now: at(10).addingTimeInterval(180), calendar: cal())
        await settled(s)
        XCTAssertEqual(log.values, ["busy", "away"], "edit re-applied at once")

        // An edit to an entry that is NOT active changes nothing.
        var off = entry(.dnd)
        off.window.startMinutes = 20 * 60
        off.window.endMinutes = 21 * 60
        s.entries.append(off)
        s.tick(now: at(10).addingTimeInterval(240), calendar: cal())
        await settled(s)
        XCTAssertEqual(log.values, ["busy", "away"], "inactive entry edits do not re-fire")
    }

    // MARK: R7

    private func store(_ wire: HoldWire) -> ConversationStore {
        let s = ConversationStore()
        let own = ChatMessage(id: "m1", sender: "Owner", timestamp: "2026-09-29T10:00:00Z", content: "keep me")
        s.attachLiveForTesting(chatID: "19:chat@thread.v2", messages: [own], ownName: "Owner")
        s.deleteTransport = { chat, id in try wire.send(chat, id) }
        return s
    }

    private func wait(_ done: () -> Bool) async {
        for _ in 0 ..< 400 where !done() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// (a) attempt 1 fails, retry succeeds: attempt 1's fade timer must not
    /// drop the retried tombstone early; the retry's own timer still does.
    func testRetriedOneToOneDeleteIsNotDroppedByTheFirstAttemptsFadeTimer() async {
        let wire = HoldWire(failures: 1)
        let s = store(wire)
        s.tombstoneFadeNanos = 600_000_000 // 0.6 s
        s.deleteMessage(id: "m1", isOneToOne: true)
        await wait { s.deleteFailedIDs.contains("m1") }
        XCTAssertTrue(s.deleteFailedIDs.contains("m1"), "control: first attempt failed")
        try? await Task.sleep(nanoseconds: 350_000_000) // 0.35 s into attempt 1's clock
        s.retryDelete(id: "m1", isOneToOne: true)
        await wait { wire.count == 2 }
        // ~0.7 s after attempt 1 (past its 0.6 s timer), ~0.35 s after the retry
        // (its own timer fires ~0.25 s later).
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(s.messages.count, 1, "first attempt's timer must not remove the retried tombstone")
        XCTAssertTrue(s.messages[0].deleted)
        // The retry's own timer (0.6 s after the retry) does fade it.
        await wait { s.messages.isEmpty }
        XCTAssertTrue(s.messages.isEmpty, "retry's own fade still drops the row")
    }

    /// (b) an edit that lands while the delete request is in flight survives
    /// the rollback.
    func testFailedDeleteKeepsAnEditMadeMidRequest() async {
        let wire = HoldWire(failures: 1, blockFirst: true)
        let s = store(wire)
        s.deleteMessage(id: "m1")
        await wait { wire.count == 1 }
        s.ingestEdited(id: "m1", content: "edited while deleting") // a realtime edit lands mid-request
        wire.release()
        await wait { s.deleteFailedIDs.contains("m1") }
        XCTAssertTrue(s.deleteFailedIDs.contains("m1"))
        XCTAssertEqual(s.messages[0].content, "edited while deleting", "snapshot must not overwrite the edit")
        XCTAssertTrue(s.messages[0].edited)
        XCTAssertFalse(s.messages[0].deleted)
    }

    func testRollbackWithNoMidRequestChangeRestoresTheSnapshot() {
        let before = ChatMessage(id: "m1", sender: "Owner", timestamp: "t", content: "keep me")
        var tomb = before
        tomb.content = ""; tomb.deleted = true
        let out = ConversationStore.restoringAfterFailedDelete(before: before, current: tomb)
        XCTAssertEqual(out.content, "keep me")
        XCTAssertFalse(out.deleted)
    }
}
