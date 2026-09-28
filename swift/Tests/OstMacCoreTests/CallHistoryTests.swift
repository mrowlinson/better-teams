// CallHistoryTests.swift — om-call-history: store feeds, redial gate,
// empty state, persistence round-trip, label formatters. No core calls
// (isolated UserDefaults suites, injected clock instants).
import XCTest

@testable import OstMacCore

@MainActor
final class CallHistoryTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "test-call-history-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func store() -> CallHistoryStore {
        CallHistoryStore(defaults: defaults)
    }

    private func ringing(
        id: String = "c1", dir: String = "in",
        peerName: String = "Doe, Jane", thread: String = ""
    ) -> CallInfo {
        CallInfo(
            id: id, dir: dir, peer: "8:orgid:aaa", peerName: peerName,
            thread: thread, state: "ringing", startedAt: 1_700_000_000)
    }

    // MARK: - Empty state

    func testFreshStoreIsEmpty() {
        let s = store()
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.records.count, 0)
        XCTAssertEqual(s.totalCount, 0)
        XCTAssertEqual(s.missedCount, 0)
    }

    func testEmptyStateCopyIsGuidance() {
        XCTAssertEqual(CallHistoryStore.emptyImage, "phone")
        XCTAssertEqual(CallHistoryStore.emptyTitle, "No recent calls")
        XCTAssertFalse(CallHistoryStore.emptyMessage.isEmpty)
    }

    // MARK: - Classification (missed / in / out)

    func testUnansweredIncomingRecordsMissed() {
        let s = store()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        s.noteActiveCall(ringing(), at: t0)
        s.noteActiveCall(
            CallInfo(
                id: "c1", dir: "in", peer: "8:orgid:aaa",
                peerName: "Doe, Jane", state: "ended", startedAt: 1_700_000_000),
            at: t0.addingTimeInterval(20))
        XCTAssertEqual(s.records.count, 1)
        let r = s.records[0]
        XCTAssertEqual(r.direction, .missed)
        XCTAssertTrue(r.isMissed)
        XCTAssertEqual(r.displayName, "Doe, Jane")
        XCTAssertEqual(r.durationSecs, 0)
        XCTAssertEqual(s.missedCount, 1)
    }

    func testAnsweredIncomingRecordsInWithDuration() {
        let s = store()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        s.noteActiveCall(ringing(), at: t0)
        s.noteActiveCall(
            CallInfo(
                id: "c1", dir: "in", peer: "8:orgid:aaa",
                peerName: "Doe, Jane", state: "connected",
                startedAt: 1_700_000_000),
            at: t0.addingTimeInterval(5))
        s.noteActiveCall(
            CallInfo(
                id: "c1", dir: "in", peer: "8:orgid:aaa",
                peerName: "Doe, Jane", state: "ended",
                startedAt: 1_700_000_000),
            at: t0.addingTimeInterval(65))
        XCTAssertEqual(s.records.count, 1)
        let r = s.records[0]
        XCTAssertEqual(r.direction, .incoming)
        XCTAssertEqual(r.durationSecs, 60)
        XCTAssertEqual(r.durationLabel, "1:00")
        XCTAssertEqual(s.missedCount, 0)
    }

    func testOutgoingEndRecordsOut() {
        let s = store()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        s.noteActiveCall(
            CallInfo(
                id: "c9", dir: "out", peer: "8:orgid:bbb",
                peerName: "Chen, Tom", thread: "19:t",
                state: "ringing", startedAt: 1_700_000_000),
            at: t0)
        s.noteActiveCall(
            CallInfo(
                id: "c9", dir: "out", peer: "8:orgid:bbb",
                peerName: "Chen, Tom", thread: "19:t",
                state: "ended", startedAt: 1_700_000_000),
            at: t0.addingTimeInterval(10))
        XCTAssertEqual(s.records.count, 1)
        XCTAssertEqual(s.records[0].direction, .outgoing)
        XCTAssertEqual(s.records[0].thread, "19:t")
    }

    func testFeedIncomingThenEndRecordsMissed() {
        let s = store()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        s.noteEvent(
            CallEvent(
                kind: "incoming", callID: "c5", peer: "8:orgid:ccc",
                peerName: "Garcia, Maria"),
            at: t0)
        XCTAssertTrue(s.records.isEmpty) // rings don't list until finished
        s.noteEvent(CallEvent(kind: "end", callID: "c5"), at: t0)
        XCTAssertEqual(s.records.count, 1)
        XCTAssertEqual(s.records[0].direction, .missed)
        XCTAssertEqual(s.records[0].displayName, "Garcia, Maria")
    }

    func testFeedRejectedFinalizesPending() {
        let s = store()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        s.noteActiveCall(ringing(id: "c7"), at: t0)
        s.noteEvent(CallEvent(kind: "rejected", callID: "c7"), at: t0)
        XCTAssertEqual(s.records.count, 1)
        XCTAssertEqual(s.records[0].direction, .missed)
    }

    func testUnknownEventKindIgnored() {
        let s = store()
        s.noteEvent(CallEvent(kind: "bogus", callID: "cx"))
        XCTAssertTrue(s.records.isEmpty)
    }

    // MARK: - Exactly-once + ordering + cap

    func testDoubleCloseRecordsOnce() {
        let s = store()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        s.noteActiveCall(ringing(), at: t0)
        // Feed end AND slot snapshot both arrive: one record.
        s.noteEvent(CallEvent(kind: "end", callID: "c1"), at: t0)
        s.noteActiveCall(
            CallInfo(
                id: "c1", dir: "in", peer: "8:orgid:aaa",
                peerName: "Doe, Jane", state: "ended",
                startedAt: 1_700_000_000),
            at: t0)
        XCTAssertEqual(s.records.count, 1)
    }

    func testNewestFirst() {
        let s = store()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for id in ["c1", "c2", "c3"] {
            s.noteActiveCall(ringing(id: id), at: t0)
            s.noteActiveCall(
                CallInfo(
                    id: id, dir: "in", peer: "8:orgid:aaa",
                    peerName: "N", state: "ended",
                    startedAt: 1_700_000_000),
                at: t0)
        }
        XCTAssertEqual(s.records.map(\.id), ["c3", "c2", "c1"])
    }

    func testNilSlotFinalizesPending() {
        let s = store() // demo end() clears the slot without a snapshot
        s.noteActiveCall(ringing(), at: Date(timeIntervalSince1970: 1_700_000_000))
        s.noteActiveCall(nil)
        XCTAssertEqual(s.records.count, 1)
        XCTAssertEqual(s.records[0].direction, .missed)
    }

    // MARK: - Redial action

    func testRedialFiresHandler() {
        let s = store()
        var got: [CallRecord] = []
        s.onRedial = { got.append($0) }
        let record = CallRecord(
            id: "c1", direction: .outgoing, peerName: "Chen, Tom",
            thread: "19:t", startedAt: 1, endedAt: 2, durationSecs: 1)
        s.redial(record)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].thread, "19:t")
    }

    func testRedialWithoutHandlerIsNoop() {
        let s = store()
        s.redial(CallRecord(
            id: "c1", direction: .missed,
            startedAt: 1, endedAt: 2))
    }

    func testCanRedialNeedsThread() {
        XCTAssertTrue(CallHistoryStore.canRedial(CallRecord(
            id: "a", direction: .outgoing, thread: "19:t",
            startedAt: 1, endedAt: 2)))
        XCTAssertFalse(CallHistoryStore.canRedial(CallRecord(
            id: "b", direction: .missed, startedAt: 1, endedAt: 2)))
        XCTAssertFalse(CallHistoryStore.canRedial(CallRecord(
            id: "c", direction: .incoming, thread: "  ",
            startedAt: 1, endedAt: 2)))
        // Instance gate agrees with the static one.
        XCTAssertTrue(store().canRedial(CallRecord(
            id: "a", direction: .outgoing, thread: "19:t",
            startedAt: 1, endedAt: 2)))
    }

    // MARK: - Clear + persistence

    func testClearEmptiesAndPersists() {
        let s = store()
        s.noteActiveCall(ringing(), at: Date(timeIntervalSince1970: 1_700_000_000))
        s.noteActiveCall(nil)
        XCTAssertFalse(s.isEmpty)
        s.clear()
        XCTAssertTrue(s.isEmpty)
        // A fresh store over the same suite sees the cleared list.
        XCTAssertTrue(store().isEmpty)
    }

    func testRecordsPersistAcrossStores() {
        let s = store()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        s.noteActiveCall(ringing(thread: "19:t"), at: t0)
        s.noteActiveCall(
            CallInfo(
                id: "c1", dir: "in", peer: "8:orgid:aaa",
                peerName: "Doe, Jane", thread: "19:t",
                state: "ended", startedAt: 1_700_000_000),
            at: t0)
        let reopened = store()
        XCTAssertEqual(reopened.records.count, 1)
        XCTAssertEqual(reopened.records[0].direction, .missed)
        XCTAssertEqual(reopened.records[0].displayName, "Doe, Jane")
        XCTAssertEqual(reopened.missedCount, 1)
    }

    func testCorruptPayloadLoadsEmpty() {
        defaults.set("garbage".data(using: .utf8)!, forKey: CallHistoryStore.defaultsKey)
        XCTAssertTrue(store().isEmpty)
    }

    func testSeedDemoDoesNotPersist() {
        let s = store()
        s.seedDemo()
        XCTAssertEqual(s.records.count, 3)
        XCTAssertEqual(s.missedCount, 1)
        // Demo rows stay in memory: a fresh store over the suite is empty.
        XCTAssertTrue(store().isEmpty)
    }

    // MARK: - Labels

    func testDirectionLabelsAndIcons() {
        XCTAssertEqual(CallDirection.missed.label, "Missed")
        XCTAssertEqual(CallDirection.incoming.label, "Incoming")
        XCTAssertEqual(CallDirection.outgoing.label, "Outgoing")
        XCTAssertEqual(CallDirection.missed.rawValue, "missed")
        XCTAssertEqual(CallDirection.incoming.rawValue, "in")
        XCTAssertEqual(CallDirection.outgoing.rawValue, "out")
        for d: CallDirection in [.missed, .incoming, .outgoing] {
            XCTAssertTrue(d.systemImage.hasPrefix("phone."))
        }
    }

    func testDisplayNameFallbacks() {
        XCTAssertEqual(
            CallRecord(
                id: "a", direction: .incoming, peer: "8:x",
                peerName: "Doe, Jane", startedAt: 1, endedAt: 2).displayName,
            "Doe, Jane")
        XCTAssertEqual(
            CallRecord(
                id: "b", direction: .missed, peer: "8:x",
                startedAt: 1, endedAt: 2).displayName,
            "8:x")
        XCTAssertEqual(
            CallRecord(
                id: "c", direction: .outgoing, thread: "19:t",
                startedAt: 1, endedAt: 2).displayName,
            "19:t")
    }

    func testDurationLabels() {
        XCTAssertEqual(CallRecord.durationLabel(0), "0:00")
        XCTAssertEqual(CallRecord.durationLabel(43), "0:43")
        XCTAssertEqual(CallRecord.durationLabel(754), "12:34")
        XCTAssertEqual(CallRecord.durationLabel(3723), "1:02:03")
    }

    func testDisplayTimeTodayVsOlder() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let now = Date()
        let today = cal.startOfDay(for: now).addingTimeInterval(12 * 3600 + 53 * 60)
        let todayLabel = CallRecord.displayTime(for: today, now: now)
        // Today = the system short clock, nothing else (12h locales
        // carry an AM/PM marker, so "no space" no longer holds).
        let short = DateFormatter()
        short.timeStyle = .short
        short.dateStyle = .none
        XCTAssertEqual(todayLabel, short.string(from: today))
        let older = today.addingTimeInterval(-3 * 86400)
        let olderLabel = CallRecord.displayTime(for: older, now: now)
        XCTAssertTrue(
            olderLabel.hasPrefix(short.string(from: older) + " "),
            "older shows clock + day: \(olderLabel)")
    }

    func testDetailLines() {
        let missed = CallRecord(
            id: "m", direction: .missed, startedAt: 1_700_000_000,
            endedAt: 1_700_000_020)
        XCTAssertTrue(missed.detailLine.hasPrefix("Missed · "))
        let answered = CallRecord(
            id: "i", direction: .incoming, startedAt: 1_700_000_000,
            endedAt: 1_700_000_060, durationSecs: 60)
        XCTAssertTrue(answered.detailLine.hasPrefix("Incoming · 1:00 · "))
        let unanswered = CallRecord(
            id: "o", direction: .outgoing, startedAt: 1_700_000_000,
            endedAt: 1_700_000_010)
        XCTAssertTrue(unanswered.detailLine.hasPrefix("Outgoing · "))
        XCTAssertFalse(unanswered.detailLine.contains("0:00"))
    }

    func testCallsLineFormatter() {
        XCTAssertEqual(DiagnosticsFormat.callsLine(total: 0, missed: 0), "0 recent · 0 missed")
        XCTAssertEqual(DiagnosticsFormat.callsLine(total: 3, missed: 1), "3 recent · 1 missed")
    }

    func testCallsWindowID() {
        XCTAssertEqual(AppIdentity.callsWindowID, "calls")
    }
}
