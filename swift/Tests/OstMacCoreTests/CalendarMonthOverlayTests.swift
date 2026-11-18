// CalendarMonthOverlayTests.swift — CAL-SCOPE R1 pins: overlaid
// second-calendar rows render in month cells (read-only), month refresh
// follows the shown month, and all write paths refuse overlay month rows.
// Local demo mode; zero live network.
import XCTest

@testable import OstMacCore

@MainActor
final class CalendarMonthOverlayTests: XCTestCase {
    static func store() -> CalendarWeekStore {
        CalendarWeekStore(
            weekFetcher: { _ in CalWeekResponse(ok: true, weekStart: 0, days: 7, meetings: []) },
            localEdits: true)
    }

    func testMonthOverlayMergesAndMarksReadOnly() {
        let store = Self.store()
        store.loadCalendars()
        store.setOverlay(id: "demo-cal-shared", on: true)
        XCTAssertFalse(store.overlayMonthRows.isEmpty, "month overlay rows load")
        let id = store.overlayMonthRows[0].id
        XCTAssertEqual(store.overlayCalendarID(for: id), "demo-cal-shared")
        XCTAssertEqual(store.row(id: id)?.id, id, "month overlay rows resolve for details")
        store.setOverlay(id: "demo-cal-shared", on: false)
        XCTAssertTrue(store.overlayMonthRows.isEmpty)
        XCTAssertNil(store.overlayCalendarID(for: id))
    }

    func testMonthOverlayBucketedOnMonthKeys() {
        let store = Self.store()
        store.loadCalendars()
        store.setOverlay(id: "demo-cal-shared", on: true)
        let keys = Set(store.monthDayKeys)
        for m in store.overlayMonthRows {
            let k = CalWeek.dayKey(of: m)
            XCTAssertNotNil(k, "overlay row has a day key")
            XCTAssertTrue(keys.contains(k ?? ""), "overlay row lands on a shown month day")
        }
    }

    func testMonthOverlayWritesRefused() async {
        let store = Self.store()
        store.loadCalendars()
        store.setOverlay(id: "demo-cal-shared", on: true)
        guard let over = store.overlayMonthRows.first else { return XCTFail("no month overlay row") }
        let row = MeetingItem(meetingId: over.id, subject: over.subject, start: over.start, end: over.end,
                              joinURL: "https://teams.microsoft.com/l/meetup-join/19:meeting_x@thread.v2/0",
                              isOrganizer: true, isOnline: true,
                              info: over.info)
        store.cancel(eventID: row.id)
        XCTAssertEqual(store.cancelError, "Other calendars are read-only")
        store.loadOptions(row)
        XCTAssertNil(store.optionsSelections[row.id], "no option load for overlay rows")
        let saved = await store.saveOptions(row, lobby: .everyone, presenters: .everyone)
        XCTAssertNil(saved, "no option save for overlay rows")
    }

    func testOptionsStoreLocalEditsRoundTrip() async {
        let store = Self.store()
        let row = MeetingItem(meetingId: "OWN1", subject: "S", start: "2026-09-30T13:00:00",
                              end: "2026-09-30T13:30:00",
                              joinURL: "https://teams.microsoft.com/l/meetup-join/19:meeting_x@thread.v2/0",
                              isOrganizer: true, isOnline: true)
        store.loadOptions(row)
        XCTAssertEqual(store.optionsSelections["OWN1"]?.lobby, .everyone)
        let sel = await store.saveOptions(row, lobby: .organizerOnly, presenters: .company)
        XCTAssertEqual(sel?.lobby, .organizerOnly)
        XCTAssertEqual(sel?.presenters, .company)
        XCTAssertEqual(store.optionsSelections["OWN1"]?.lobby, .organizerOnly)
        XCTAssertNil(store.optionsError)
    }

    func testOptionsLoadRefusesNonOrganizerAndLinkless() {
        let store = Self.store()
        let attendee = MeetingItem(meetingId: "A1", subject: "S", start: "2026-09-30T13:00:00",
                                   end: "2026-09-30T13:30:00", joinURL: "https://teams.microsoft.com/l/meetup-join/19:meeting_x@thread.v2/0",
                                   isOrganizer: false, isOnline: true)
        store.loadOptions(attendee)
        XCTAssertNil(store.optionsSelections["A1"])
        let linkless = MeetingItem(meetingId: "L1", subject: "S", start: "2026-09-30T13:00:00",
                                   end: "2026-09-30T13:30:00", isOrganizer: true, isOnline: true)
        store.loadOptions(linkless)
        XCTAssertNil(store.optionsSelections["L1"])
    }
}
