// ScheduledSendTests.swift — d2-send lane: client-side scheduled send.
// - Enqueue/cancel/edit; rejects blank text/chat + past fire times.
// - Fire claims once (overlapping ticks never double-send).
// - Past-due fires oldest-first on launch (catch-up).
// - Corrupt file → empty queue; persistence round-trips.
// - Demo/offline fires via the injected sender (never touches core).
import XCTest

@testable import OstMacCore

final class ScheduledSendTests: XCTestCase {
    // MARK: helpers

    func fixedCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    func dt(_ day: Int, _ hour: Int, _ minute: Int = 0, _ cal: Calendar) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        return cal.date(from: comps)!
    }

    /// Fresh queue path in its own temp dir (save creates parents).
    func tempQueuePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ostmac-sched-\(UUID().uuidString)/scheduled.json").path
    }

    func cleanup(_ path: String) {
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).deletingLastPathComponent())
    }

    /// Seeded recorder: MainActor-safe box for the injected sender.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _items: [ScheduledItem] = []

        func send(_ item: ScheduledItem) {
            lock.lock(); defer { lock.unlock() }
            _items.append(item)
        }

        var items: [ScheduledItem] {
            lock.lock(); defer { lock.unlock() }
            return _items
        }
    }

    // MARK: enqueue / cancel / edit

    func testEnqueueAddsPending() async {
        let cal = fixedCalendar()
        let path = tempQueuePath()
        defer { cleanup(path) }
        let store = await ScheduledSendStore(path: path)
        let now = dt(24, 10, 0, cal)
        let item = await MainActor.run {
            store.enqueue(
                chatID: "19:chat@thread.v2", chatName: "Team Chat",
                text: "morning all", fireAt: dt(24, 11, 0, cal), now: now)
        }
        XCTAssertNotNil(item)
        let pending = await MainActor.run { store.pending(for: "19:chat@thread.v2") }
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.text, "morning all")
    }

    func testEnqueueRejectsBlanksAndPast() async {
        let cal = fixedCalendar()
        let path = tempQueuePath()
        defer { cleanup(path) }
        let store = await ScheduledSendStore(path: path)
        let now = dt(24, 10, 0, cal)
        let future = dt(24, 11, 0, cal)
        let blankText = await MainActor.run {
            store.enqueue(chatID: "19:chat@thread.v2", chatName: "C", text: "   ", fireAt: future, now: now)
        }
        XCTAssertNil(blankText)
        let blankChat = await MainActor.run {
            store.enqueue(chatID: " ", chatName: "C", text: "hi", fireAt: future, now: now)
        }
        XCTAssertNil(blankChat)
        let past = await MainActor.run {
            store.enqueue(
                chatID: "19:chat@thread.v2", chatName: "C",
                text: "hi", fireAt: dt(24, 9, 0, cal), now: now)
        }
        XCTAssertNil(past)
        let items = await MainActor.run { store.items }
        XCTAssertTrue(items.isEmpty)
    }

    func testCancelRemovesWithoutSending() async {
        let cal = fixedCalendar()
        let path = tempQueuePath()
        defer { cleanup(path) }
        let store = await ScheduledSendStore(path: path)
        let now = dt(24, 10, 0, cal)
        let item = await MainActor.run {
            store.enqueue(
                chatID: "19:chat@thread.v2", chatName: "C",
                text: "drop me", fireAt: dt(24, 11, 0, cal), now: now)!
        }
        await MainActor.run { store.cancel(id: item.id) }
        let pending = await MainActor.run { store.pending(for: "19:chat@thread.v2") }
        XCTAssertTrue(pending.isEmpty)
        // Unknown ids are a no-op.
        await MainActor.run { store.cancel(id: "nope") }
        // Nothing left to fire.
        let rec = Recorder()
        let fired = await MainActor.run {
            store.fireDue(now: dt(24, 12, 0, cal)) { rec.send($0) }
        }
        XCTAssertTrue(fired.isEmpty)
        XCTAssertTrue(rec.items.isEmpty)
    }

    func testTakeForEditReturnsTextAndRemoves() async {
        let cal = fixedCalendar()
        let path = tempQueuePath()
        defer { cleanup(path) }
        let store = await ScheduledSendStore(path: path)
        let now = dt(24, 10, 0, cal)
        let item = await MainActor.run {
            store.enqueue(
                chatID: "19:chat@thread.v2", chatName: "C",
                text: "fix me", fireAt: dt(24, 11, 0, cal), now: now)!
        }
        let taken = await MainActor.run { store.takeForEdit(id: item.id) }
        XCTAssertEqual(taken?.text, "fix me")
        let pending = await MainActor.run { store.pending(for: "19:chat@thread.v2") }
        XCTAssertTrue(pending.isEmpty)
        let missing = await MainActor.run { store.takeForEdit(id: "nope") }
        XCTAssertNil(missing)
    }

    func testPendingFiltersPerChatSorted() async {
        let cal = fixedCalendar()
        let path = tempQueuePath()
        defer { cleanup(path) }
        let store = await ScheduledSendStore(path: path)
        let now = dt(24, 10, 0, cal)
        let a = "19:a@thread.v2"
        await MainActor.run {
            store.enqueue(chatID: a, chatName: "A", text: "second", fireAt: dt(24, 13, 0, cal), now: now)
            store.enqueue(chatID: "19:b@thread.v2", chatName: "B", text: "other", fireAt: dt(24, 11, 0, cal), now: now)
            store.enqueue(chatID: a, chatName: "A", text: "first", fireAt: dt(24, 12, 0, cal), now: now)
        }
        let pending = await MainActor.run { store.pending(for: a) }
        XCTAssertEqual(pending.map(\.text), ["first", "second"])
    }

    // MARK: claim-then-send

    func testFireClaimsOnce() async {
        let cal = fixedCalendar()
        let path = tempQueuePath()
        defer { cleanup(path) }
        let store = await ScheduledSendStore(path: path)
        let now = dt(24, 10, 0, cal)
        await MainActor.run {
            _ = store.enqueue(chatID: "19:chat@thread.v2", chatName: "C", text: "once", fireAt: dt(24, 11, 0, cal), now: now)
        }
        let rec = Recorder()
        let first = await MainActor.run {
            store.fireDue(now: dt(24, 11, 0, cal)) { rec.send($0) }
        }
        XCTAssertEqual(first.count, 1)
        // Overlapping second tick finds nothing (claimed, persisted).
        let second = await MainActor.run {
            store.fireDue(now: dt(24, 11, 0, cal)) { rec.send($0) }
        }
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(rec.items.count, 1)
        XCTAssertEqual(rec.items.first?.text, "once")
    }

    func testFutureItemsDoNotFire() async {
        let cal = fixedCalendar()
        let path = tempQueuePath()
        defer { cleanup(path) }
        let store = await ScheduledSendStore(path: path)
        let now = dt(24, 10, 0, cal)
        await MainActor.run {
            _ = store.enqueue(chatID: "19:chat@thread.v2", chatName: "C", text: "later", fireAt: dt(24, 11, 0, cal), now: now)
        }
        let rec = Recorder()
        let fired = await MainActor.run {
            store.fireDue(now: dt(24, 10, 30, cal)) { rec.send($0) }
        }
        XCTAssertTrue(fired.isEmpty)
        XCTAssertTrue(rec.items.isEmpty)
        let pending = await MainActor.run { store.pending(for: "19:chat@thread.v2") }
        XCTAssertEqual(pending.count, 1)
    }

    func testPastDueFiresOldestFirstOnLaunch() async {
        // App was asleep/quit: items persisted out of order fire oldest-first.
        let cal = fixedCalendar()
        let path = tempQueuePath()
        defer { cleanup(path) }
        let seed = [
            ScheduledItem(
                id: "c", chatID: "19:chat@thread.v2", chatName: "C",
                text: "third", fireAt: dt(24, 9, 30, cal), createdAt: dt(24, 8, 3, cal)),
            ScheduledItem(
                id: "a", chatID: "19:chat@thread.v2", chatName: "C",
                text: "first", fireAt: dt(24, 9, 0, cal), createdAt: dt(24, 8, 1, cal)),
            ScheduledItem(
                id: "b", chatID: "19:chat@thread.v2", chatName: "C",
                text: "second", fireAt: dt(24, 9, 15, cal), createdAt: dt(24, 8, 2, cal)),
        ]
        let url = URL(fileURLWithPath: path)
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! JSONEncoder().encode(seed).write(to: url, options: .atomic)
        // "Relaunch": fresh store loads the file.
        let store = await ScheduledSendStore(path: path)
        let loaded = await MainActor.run { store.items }
        XCTAssertEqual(loaded.count, 3)
        let rec = Recorder()
        let fired = await MainActor.run {
            store.fireDue(now: dt(24, 10, 0, cal)) { rec.send($0) }
        }
        XCTAssertEqual(fired.map(\.text), ["first", "second", "third"])
        XCTAssertEqual(rec.items.map(\.text), ["first", "second", "third"])
    }

    func testClaimDueMatchingLeavesOthersQueued() async {
        // Demo mode claims the open chat's items only; the rest wait.
        let cal = fixedCalendar()
        let path = tempQueuePath()
        defer { cleanup(path) }
        let store = await ScheduledSendStore(path: path)
        let now = dt(24, 8, 0, cal)
        await MainActor.run {
            store.enqueue(chatID: "19:open@thread.v2", chatName: "O", text: "mine", fireAt: dt(24, 9, 0, cal), now: now)
            store.enqueue(chatID: "19:other@thread.v2", chatName: "X", text: "wait", fireAt: dt(24, 9, 0, cal), now: now)
        }
        let claimed = await MainActor.run {
            store.claimDue(now: dt(24, 10, 0, cal)) { $0.chatID == "19:open@thread.v2" }
        }
        XCTAssertEqual(claimed.map(\.text), ["mine"])
        let waiting = await MainActor.run { store.pending(for: "19:other@thread.v2") }
        XCTAssertEqual(waiting.map(\.text), ["wait"])
    }

    func testClaimDueIsOldestFirst() async {
        let cal = fixedCalendar()
        let path = tempQueuePath()
        defer { cleanup(path) }
        let store = await ScheduledSendStore(path: path)
        let now = dt(24, 8, 0, cal)
        await MainActor.run {
            store.enqueue(chatID: "19:chat@thread.v2", chatName: "C", text: "b", fireAt: dt(24, 9, 15, cal), now: now)
            store.enqueue(chatID: "19:chat@thread.v2", chatName: "C", text: "a", fireAt: dt(24, 9, 0, cal), now: now)
        }
        let claimed = await MainActor.run { store.claimDue(now: dt(24, 10, 0, cal)) }
        XCTAssertEqual(claimed.map(\.text), ["a", "b"])
    }

    // MARK: persistence

    func testCorruptFileYieldsEmptyQueue() async {
        let path = tempQueuePath()
        defer { cleanup(path) }
        let url = URL(fileURLWithPath: path)
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! "not json{{{".write(to: url, atomically: true, encoding: .utf8)
        let store = await ScheduledSendStore(path: path) // never throws/crashes
        let items = await MainActor.run { store.items }
        XCTAssertTrue(items.isEmpty)
        let rec = Recorder()
        let fired = await MainActor.run {
            store.fireDue(now: Date()) { rec.send($0) }
        }
        XCTAssertTrue(fired.isEmpty)
    }

    func testMissingFileYieldsEmptyQueue() async {
        let store = await ScheduledSendStore(path: tempQueuePath())
        let items = await MainActor.run { store.items }
        XCTAssertTrue(items.isEmpty)
    }

    func testPersistenceRoundTrip() async {
        let cal = fixedCalendar()
        let path = tempQueuePath()
        defer { cleanup(path) }
        let now = dt(24, 10, 0, cal)
        let first = await ScheduledSendStore(path: path)
        await MainActor.run {
            _ = first.enqueue(chatID: "19:chat@thread.v2", chatName: "C", text: "keep", fireAt: dt(25, 9, 0, cal), now: now)
        }
        let second = await ScheduledSendStore(path: path)
        let pending = await MainActor.run { second.pending(for: "19:chat@thread.v2") }
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.text, "keep")
        XCTAssertEqual(pending.first?.fireAt, dt(25, 9, 0, cal))
    }

    func testCancelPersists() async {
        // A cancelled item stays cancelled across relaunch (no dup send).
        let cal = fixedCalendar()
        let path = tempQueuePath()
        defer { cleanup(path) }
        let now = dt(24, 10, 0, cal)
        let first = await ScheduledSendStore(path: path)
        let item = await MainActor.run {
            first.enqueue(chatID: "19:chat@thread.v2", chatName: "C", text: "drop", fireAt: dt(24, 11, 0, cal), now: now)!
        }
        await MainActor.run { first.cancel(id: item.id) }
        let second = await ScheduledSendStore(path: path)
        let items = await MainActor.run { second.items }
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: presets

    func testInOneHour() {
        let cal = fixedCalendar()
        XCTAssertEqual(
            ScheduledPresets.inOneHour(now: dt(24, 10, 20, cal), calendar: cal),
            dt(24, 11, 20, cal))
    }

    func testTonight8PM() {
        let cal = fixedCalendar()
        // Afternoon → today 20:00.
        XCTAssertEqual(
            ScheduledPresets.tonight8PM(now: dt(24, 15, 0, cal), calendar: cal),
            dt(24, 20, 0, cal))
        // After 20:00 → tomorrow 20:00 (always future).
        XCTAssertEqual(
            ScheduledPresets.tonight8PM(now: dt(24, 21, 0, cal), calendar: cal),
            dt(25, 20, 0, cal))
    }

    func testTomorrow9AM() {
        let cal = fixedCalendar()
        XCTAssertEqual(
            ScheduledPresets.tomorrow9AM(now: dt(24, 15, 0, cal), calendar: cal),
            dt(25, 9, 0, cal))
        // After midnight edge: still the next calendar day.
        XCTAssertEqual(
            ScheduledPresets.tomorrow9AM(now: dt(24, 0, 30, cal), calendar: cal),
            dt(25, 9, 0, cal))
    }

    func testFireLabel() {
        let cal = fixedCalendar()
        let now = dt(24, 10, 0, cal)
        XCTAssertTrue(
            ScheduledPresets.fireLabel(for: dt(24, 15, 0, cal), now: now, calendar: cal)
                .hasPrefix("Today "))
        XCTAssertTrue(
            ScheduledPresets.fireLabel(for: dt(25, 9, 0, cal), now: now, calendar: cal)
                .hasPrefix("Tomorrow "))
        // Distant dates carry the month/day.
        let far = ScheduledPresets.fireLabel(for: dt(28, 9, 0, cal), now: now, calendar: cal)
        XCTAssertTrue(far.contains("28"))
    }
}
