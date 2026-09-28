// CalendarWeekTests.swift — B1 calendar lane: week decode, day bucketing,
// store load/schedule/cancel, validation. Fetchers are mocked; no FFI.
import XCTest

@testable import OstMacCore

@MainActor
final class CalendarWeekTests: XCTestCase {
    // MARK: - Fixtures

    nonisolated static func weekJSON() -> CalWeekResponse {
        let json = """
            {"ok":true,"week_start":1790553600,"days":7,"meetings":[\
            {"id":"W1","subject":"Mon standup","start":"2026-09-28T09:00:00.0000000",\
            "end":"2026-09-28T09:15:00.0000000",\
            "join_url":"https://teams.microsoft.com/l/meetup-join/19:abc@thread.v2/0",\
            "organizer":"Doe, Jane","is_online":true},\
            {"id":"W2","subject":"Mon retro","start":"2026-09-28T16:00:00.0000000",\
            "end":"2026-09-28T16:30:00.0000000",\
            "join_url":null,"organizer":null,"is_online":false},\
            {"id":"W3","subject":"Fri demo","start":"2026-10-02T14:00:00.0000000",\
            "end":"2026-10-02T15:00:00.0000000",\
            "join_url":null,"organizer":"Lee, Sam","is_online":false},\
            {"id":"W4","subject":"Unscheduled","start":null,"end":null,\
            "join_url":null,"organizer":null,"is_online":false}]}
            """
        return try! decodeOrThrow(CalWeekResponse.self, from: Data(json.utf8))
    }

    nonisolated static func eventJSON() -> CalEventResult {
        let json = """
            {"ok":true,"event":\
            {"id":"C1","subject":"Sync","start":"2026-09-29T10:00:00",\
            "end":"2026-09-29T10:30:00",\
            "join_url":"https://teams.microsoft.com/l/meetup-join/new",\
            "organizer":null,"is_online":true}}
            """
        return try! decodeOrThrow(CalEventResult.self, from: Data(json.utf8))
    }

    nonisolated static func cancelJSON() -> CalCancelResult {
        let json = #"{"ok":true,"id":"W1"}"#
        return try! decodeOrThrow(CalCancelResult.self, from: Data(json.utf8))
    }

    /// Fixed Monday-first UTC calendar for deterministic bucketing.
    nonisolated static func utcMonday() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2
        return cal
    }

    nonisolated static func monday() -> Date {
        Date(timeIntervalSince1970: 1_790_553_600) // 2026-09-28 Mon 00:00 UTC
    }

    func waitFor(_ what: String, _ cond: @escaping () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if cond() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: - Wire decode

    func testDecodeWeek() {
        let response = Self.weekJSON()
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.weekStart, 1_790_553_600)
        XCTAssertEqual(response.days, 7)
        XCTAssertEqual(response.meetings.count, 4)
        XCTAssertEqual(response.meetings[0].id, "W1")
        XCTAssertTrue(response.meetings[0].isJoinable)
        XCTAssertFalse(response.meetings[1].isJoinable)
    }

    func testDecodeEvent() {
        let result = Self.eventJSON()
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.event.id, "C1")
        XCTAssertEqual(result.event.subject, "Sync")
        XCTAssertTrue(result.event.isJoinable)
    }

    func testDecodeCancel() {
        let result = Self.cancelJSON()
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.id, "W1")
    }

    func testErrorEnvelopeThrows() {
        let json = #"{"ok":false,"error":"calweek","detail":"nope"}"#
        XCTAssertThrowsError(
            try decodeOrThrow(CalWeekResponse.self, from: Data(json.utf8)))
    }

    // MARK: - Day bucketing (pure)

    func testDayKeyAndTime() {
        let ms = Self.weekJSON().meetings
        XCTAssertEqual(CalWeek.dayKey(of: ms[0]), "2026-09-28")
        XCTAssertEqual(CalWeek.dayKey(of: ms[2]), "2026-10-02")
        XCTAssertNil(CalWeek.dayKey(of: ms[3]))
        XCTAssertEqual(CalWeek.dayTime(of: ms[0]), "09:00")
        XCTAssertEqual(CalWeek.dayTime(of: ms[1]), "16:00")
        XCTAssertNil(CalWeek.dayTime(of: ms[3]))
    }

    func testBucketColumns() {
        let cols = CalWeek.bucket(
            Self.weekJSON().meetings, weekStart: Self.monday(),
            calendar: Self.utcMonday())
        XCTAssertEqual(cols.count, 7)
        XCTAssertEqual(cols.map(\.count), [2, 0, 0, 0, 1, 0, 0])
        // Monday column sorted by start; unscheduled rows excluded.
        XCTAssertEqual(cols[0].map(\.id), ["W1", "W2"])
        XCTAssertEqual(cols[4].map(\.id), ["W3"])
    }

    func testStartOfWeek() {
        // Wednesday -> Monday midnight.
        let wed = Date(timeIntervalSince1970: 1_790_553_600 + 2 * 86_400 + 3_600)
        XCTAssertEqual(
            CalWeek.startOfWeek(containing: wed, calendar: Self.utcMonday()),
            Self.monday())
    }

    func testGraphDateTime() {
        let d = Date(timeIntervalSince1970: 1_790_553_600 + 10 * 3_600)
        XCTAssertEqual(
            CalWeek.graphDateTime(d, timeZone: TimeZone(identifier: "UTC")!),
            "2026-09-28T10:00:00")
    }

    // MARK: - Store load

    func testLoadHappy() async throws {
        let resp = Self.weekJSON()
        let store = CalendarWeekStore(
            weekStart: Self.monday(), calendar: Self.utcMonday(),
            weekFetcher: { _ in resp })
        await store.load()
        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.meetings.count, 4)
        XCTAssertEqual(store.columns.map(\.count), [2, 0, 0, 0, 1, 0, 0])
    }

    func testLoadEmpty() async throws {
        let store = CalendarWeekStore(
            weekStart: Self.monday(), calendar: Self.utcMonday(),
            weekFetcher: { _ in CalWeekResponse(
                ok: true, weekStart: 1_790_553_600, days: 7, meetings: []) })
        await store.load()
        XCTAssertEqual(store.state, .empty)
        XCTAssertTrue(store.meetings.isEmpty)
    }

    func testLoadError() async throws {
        let store = CalendarWeekStore(
            weekStart: Self.monday(), calendar: Self.utcMonday(),
            weekFetcher: { _ in throw CoreCallError.failed("nope") })
        await store.load()
        XCTAssertEqual(store.state, .error("nope"))
        XCTAssertTrue(store.meetings.isEmpty)
    }

    func testPrevNextWeekShiftsSevenDays() async throws {
        final class SeenBox: @unchecked Sendable { var seen: [Int64] = [] }
        let box = SeenBox()
        let store = CalendarWeekStore(
            weekStart: Self.monday(), calendar: Self.utcMonday(),
            weekFetcher: {
                box.seen.append($0)
                return CalWeekResponse(
                    ok: true, weekStart: $0, days: 7, meetings: [])
            })
        store.nextWeek()
        try await waitFor("next fetch") { box.seen.count == 1 }
        store.prevWeek()
        store.prevWeek()
        try await waitFor("prev fetches") { box.seen.count == 3 }
        guard box.seen.count == 3 else { return } // waitFor already failed
        XCTAssertEqual(
            store.weekStart, Self.monday().addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(box.seen[0], 1_790_553_600 + 7 * 86_400)
        XCTAssertEqual(box.seen[2], 1_790_553_600 - 7 * 86_400)
    }

    // MARK: - Schedule

    func testScheduleValidationBlocksRunner() async throws {
        final class CountBox: @unchecked Sendable { var calls = 0 }
        let box = CountBox()
        let store = CalendarWeekStore(
            weekStart: Self.monday(), calendar: Self.utcMonday(),
            weekFetcher: { _ in Self.weekJSON() },
            scheduleRunner: { _, _, _, _, _ in
                box.calls += 1
                return Self.eventJSON()
            })
        store.schedule(subject: "   ", start: "2026-09-29T10:00:00",
            end: "2026-09-29T10:30:00", online: true)
        XCTAssertEqual(box.calls, 0)
        XCTAssertNotNil(store.scheduleError)
        store.schedule(subject: "S", start: "2026-09-29T10:30:00",
            end: "2026-09-29T10:00:00", online: false)
        XCTAssertEqual(box.calls, 0)
        XCTAssertNotNil(store.scheduleError)
    }

    func testScheduleHappyAppends() async throws {
        let store = CalendarWeekStore(
            weekStart: Self.monday(), calendar: Self.utcMonday(),
            weekFetcher: { _ in Self.weekJSON() },
            scheduleRunner: { _, _, _, _, _ in Self.eventJSON() })
        await store.load()
        let before = store.meetings.count
        store.showSchedule = true
        store.schedule(subject: "Sync", start: "2026-09-29T10:00:00",
            end: "2026-09-29T10:30:00", online: true)
        try await waitFor("scheduled") { store.meetings.count == before + 1 }
        XCTAssertNil(store.scheduleError)
        XCTAssertFalse(store.showSchedule)
        XCTAssertEqual(store.meetings.last?.id, "C1")
    }

    func testScheduleLocalEdits() async throws {
        let store = CalendarWeekStore(
            weekStart: Self.monday(), calendar: Self.utcMonday(),
            weekFetcher: { _ in Self.weekJSON() }, localEdits: true)
        await store.load()
        let before = store.meetings.count
        store.schedule(subject: "Local", start: "2026-09-29T10:00:00",
            end: "2026-09-29T10:30:00", online: false)
        XCTAssertEqual(store.meetings.count, before + 1)
        XCTAssertEqual(store.meetings.last?.subject, "Local")
        XCTAssertNil(store.scheduleError)
    }

    func testScheduleErrorSurfaces() async throws {
        let store = CalendarWeekStore(
            weekStart: Self.monday(), calendar: Self.utcMonday(),
            weekFetcher: { _ in Self.weekJSON() },
            scheduleRunner: { _, _, _, _, _ in
                throw CoreCallError.failed("403 forbidden")
            })
        await store.load()
        let before = store.meetings.count
        store.schedule(subject: "Sync", start: "2026-09-29T10:00:00",
            end: "2026-09-29T10:30:00", online: true)
        try await waitFor("schedule error") { store.scheduleError != nil }
        XCTAssertEqual(store.scheduleError, "403 forbidden")
        XCTAssertEqual(store.meetings.count, before)
    }

    // MARK: - Cancel

    func testCancelHappyRemoves() async throws {
        let store = CalendarWeekStore(
            weekStart: Self.monday(), calendar: Self.utcMonday(),
            weekFetcher: { _ in Self.weekJSON() },
            cancelRunner: { CalCancelResult(ok: true, id: $0) })
        await store.load()
        store.cancel(eventID: "W1")
        try await waitFor("cancelled") {
            !store.meetings.contains(where: { $0.id == "W1" })
        }
        XCTAssertNil(store.cancelError)
        XCTAssertNil(store.cancelingID)
    }

    func testCancelErrorKeepsRow() async throws {
        let store = CalendarWeekStore(
            weekStart: Self.monday(), calendar: Self.utcMonday(),
            weekFetcher: { _ in Self.weekJSON() },
            cancelRunner: { _ in throw CoreCallError.failed("404 gone") })
        await store.load()
        store.cancel(eventID: "W1")
        try await waitFor("cancel error") { store.cancelError != nil }
        XCTAssertEqual(store.cancelError, "404 gone")
        XCTAssertTrue(store.meetings.contains(where: { $0.id == "W1" }))
        XCTAssertNil(store.cancelingID)
    }
}
