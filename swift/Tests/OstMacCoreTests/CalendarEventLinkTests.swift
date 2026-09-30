// CalendarEventLinkTests.swift — LINKGUARD: an Outlook calendar-event link
// for an event outside the loaded ranges is read by id (one GET through the
// details runner), never refused, never opened in a browser.
import XCTest

@testable import OstMacCore

@MainActor
final class CalendarEventLinkTests: XCTestCase {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return ids }
    }

    private func store(_ calls: Calls, detail: @escaping @Sendable (String) throws -> CalendarEventDetail,
                       localEdits: Bool = false) -> CalendarWeekStore {
        var runners = CalendarRunners.production
        runners.detail = { id in calls.add(id); return try detail(id) }
        return CalendarWeekStore(
            weekFetcher: { CalWeekResponse(ok: true, weekStart: $0, days: 7, meetings: []) },
            runners: runners, localEdits: localEdits)
    }

    private func event(_ id: String) -> MeetingItem {
        MeetingItem(meetingId: id, subject: "Design review", start: "2026-10-01T09:00:00", end: "2026-10-01T09:30:00")
    }

    func testUnloadedEventIsReadByIDThenResolves() async {
        let calls = Calls()
        let store = store(calls) { CalendarEventDetail(event: MeetingItem(
            meetingId: $0, subject: "Design review", start: "2026-10-01T09:00:00", end: "2026-10-01T09:30:00")) }
        XCTAssertNil(store.row(id: "AAMkFAKE="))
        let ok = await store.resolveEvent(id: "AAMkFAKE=")
        XCTAssertTrue(ok)
        XCTAssertEqual(calls.all, ["AAMkFAKE="], "exactly one read by id")
        XCTAssertEqual(store.row(id: "AAMkFAKE=")?.subject, "Design review", "the calendar screen can show it")
    }

    func testFailedReadResolvesFalseAndLeavesNoRow() async {
        let calls = Calls()
        let store = store(calls) { _ in throw CoreCallError.failed("404 Not Found") }
        let ok = await store.resolveEvent(id: "AAMkGONE")
        XCTAssertFalse(ok)
        XCTAssertNil(store.row(id: "AAMkGONE"))
    }

    func testKnownEventNeedsNoRead() async {
        let calls = Calls()
        let store = store(calls) { _ in throw CoreCallError.failed("must not be called") }
        store.details["K1"] = CalendarEventDetail(event: event("K1"))
        let ok = await store.resolveEvent(id: "K1")
        XCTAssertTrue(ok)
        XCTAssertTrue(calls.all.isEmpty)
    }

    func testDemoNeverReads() async {
        let calls = Calls()
        let store = store(calls, detail: { CalendarEventDetail(event: MeetingItem(
            meetingId: $0, subject: "x", start: "2026-10-01T09:00:00", end: "2026-10-01T09:30:00")) }, localEdits: true)
        XCTAssertFalse(store.canResolveEventsByID)
        let ok = await store.resolveEvent(id: "AAMkFAKE")
        XCTAssertFalse(ok)
        XCTAssertTrue(calls.all.isEmpty, "demo has no remote event to read")
    }
}
