// CalendarRemnantTests.swift — CAL-REMNANT (C4) pins: meeting-options
// PATCH keys + wire parse, channel-meeting create + announce shapes,
// multi-calendar overlay reads, overlay read-only guards, and the
// series/assistant store paths end to end. Stub transport only.
import XCTest

@testable import OstMacCore

@MainActor
final class CalendarRemnantTests: XCTestCase {
    static let eventJSON = """
        {"id":"E9","subject":"Options check","start":{"dateTime":"2026-09-29T13:30:00.0000000","timeZone":"UTC"},
         "end":{"dateTime":"2026-09-29T14:00:00.0000000","timeZone":"UTC"},"isAllDay":false,
         "isOnlineMeeting":true,"onlineMeeting":{"joinUrl":"https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0"},
         "organizer":{"emailAddress":{"name":"Doe, Jane","address":"jane@contoso.example"}},"isOrganizer":true,
         "responseRequested":false,"allowNewTimeProposals":false,"hideAttendees":true}
        """

    static func event(_ id: String, organizer: Bool = true) -> MeetingItem {
        MeetingItem(meetingId: id, subject: "S\(id)", start: "2026-09-30T13:00:00",
                    end: "2026-09-30T14:00:00", isOrganizer: organizer,
                    info: CalendarEventInfo(responseRequested: true))
    }

    // MARK: meeting options (event-level knobs)

    func testOptionsPatchBodyKeys() {
        let body = CalendarEventPatch(responseRequested: false, allowNewTimeProposals: false,
                                      hideAttendees: true).body
        XCTAssertEqual(body["responseRequested"] as? Bool, false)
        XCTAssertEqual(body["allowNewTimeProposals"] as? Bool, false)
        XCTAssertEqual(body["hideAttendees"] as? Bool, true)
        XCTAssertTrue(CalendarEventPatch().body.isEmpty)
    }

    func testOptionsPatchIsNeverPersonal() {
        XCTAssertFalse(CalendarEventPatch(responseRequested: false).isPersonal)
        XCTAssertFalse(CalendarEventPatch(allowNewTimeProposals: true).isPersonal)
        XCTAssertFalse(CalendarEventPatch(hideAttendees: true).isPersonal)
        XCTAssertTrue(CalendarEventPatch(showAs: "busy").isPersonal)
    }

    func testOptionsAppliedToRow() {
        let row = CalendarEventPatch(responseRequested: false, allowNewTimeProposals: false,
                                     hideAttendees: true)
            .applied(to: Self.event("E1"))
        XCTAssertEqual(row.info?.responseRequested, false)
        XCTAssertEqual(row.info?.allowNewTimeProposals, false)
        XCTAssertEqual(row.info?.hideAttendees, true)
    }

    func testOptionsParseFromWireAndSelect() throws {
        let row = try CalendarEvents.single(Data(Self.eventJSON.utf8), tz: TimeZone(identifier: "UTC")!).row
        XCTAssertEqual(row.info?.responseRequested, false)
        XCTAssertEqual(row.info?.allowNewTimeProposals, false)
        XCTAssertEqual(row.info?.hideAttendees, true)
        XCTAssertTrue(CalendarEvents.listSelect.contains("allowNewTimeProposals"))
        XCTAssertTrue(CalendarEvents.listSelect.contains("hideAttendees"))
    }

    func testUpdateSendsOptionsPatch() throws {
        let http = StubCalendarHTTP([(200, Self.eventJSON)])
        let updated = try CalendarEventsTests.graph(http).update(
            id: "E9", patch: CalendarEventPatch(hideAttendees: true))
        XCTAssertEqual(http.sent.count, 1)
        XCTAssertTrue(http.sent[0].url.absoluteString.contains("/me/events/E9"))
        XCTAssertEqual(http.sent[0].body?["hideAttendees"] as? Bool, true)
        XCTAssertEqual(updated.id, "E9")
    }

    // MARK: channel meeting create + announce

    func testAnnounceRequestShape() throws {
        let http = StubCalendarHTTP([(202, "")])
        let g = CalendarEventsTests.graph(http)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        try g.announceChannelMeeting(teamID: "T1", channelID: "C1", subject: "Standup",
                                    start: start, end: start.addingTimeInterval(1800),
                                    joinURL: "https://teams.microsoft.com/l/meetup-join/x")
        XCTAssertEqual(http.sent.count, 1)
        let sent = try XCTUnwrap(http.sent.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertTrue(sent.url.absoluteString.contains("/teams/T1/channels/C1/messages"))
        let body = try XCTUnwrap(sent.body?["body"] as? [String: Any])
        let content = try XCTUnwrap(body["content"] as? String)
        XCTAssertTrue(content.contains("Standup"))
        XCTAssertTrue(content.contains("meetup-join/x"))
    }

    func testAnnounceWithoutJoinURLOmitsLink() throws {
        let http = StubCalendarHTTP([(202, "")])
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        try CalendarEventsTests.graph(http).announceChannelMeeting(
            teamID: "T1", channelID: "C1", subject: "Standup",
            start: start, end: start.addingTimeInterval(1800), joinURL: nil)
        let content = try XCTUnwrap((http.sent.first?.body?["body"] as? [String: Any])?["content"] as? String)
        XCTAssertTrue(content.contains("Standup"))
        XCTAssertFalse(content.contains("Join the meeting"))
    }

    func testScheduleWithChannelRecordsAnnouncementInDemo() {
        let store = CalendarWeekStore(
            weekFetcher: { _ in CalWeekResponse(ok: true, weekStart: 0, days: 7, meetings: []) },
            localEdits: true)
        let channel = ChannelTarget(teamID: "T1", channelID: "C1", teamName: "Team", channelName: "General")
        store.schedule(subject: "test (BetterTeams lane)", start: "2026-09-30T13:00:00",
                       end: "2026-09-30T13:30:00", online: true, channel: channel)
        XCTAssertEqual(store.meetings.count, 1)
        XCTAssertEqual(store.lastAnnouncedChannel, channel)
        XCTAssertNil(store.scheduleError)
    }

    func testScheduleAnnounceFailureKeepsEventAndSurfacesError() async {
        let created = Self.event("NEW")
        let store = CalendarWeekStore(
            weekFetcher: { _ in CalWeekResponse(ok: true, weekStart: 0, days: 7, meetings: []) },
            scheduleRunner: { _, _, _, _, _ in CalEventResult(ok: true, event: created) },
            announceRunner: { _, _, _, _, _, _ in throw CoreCallError.failed("nope") })
        let channel = ChannelTarget(teamID: "T1", channelID: "C1", teamName: "Team", channelName: "General")
        store.schedule(subject: "test (BetterTeams lane)", start: "2026-09-30T13:00:00",
                       end: "2026-09-30T13:30:00", online: true, channel: channel)
        await TestWait.until { !store.scheduling }
        XCTAssertEqual(store.meetings.map(\.id), ["NEW"], "event kept")
        XCTAssertNil(store.lastAnnouncedChannel)
        XCTAssertTrue(store.scheduleError?.contains("channel post") == true, store.scheduleError ?? "nil")
    }

    // MARK: multi-calendar overlay (read-only)

    func testCalendarsRequestShape() throws {
        let http = StubCalendarHTTP([(200, """
            {"value":[{"id":"A","name":"Calendar","isDefaultCalendar":true,"canEdit":true},
                      {"id":"B","name":"Team shared","color":"auto","isDefaultCalendar":false,"canEdit":false}]}
            """)])
        let feeds = try CalendarEventsTests.graph(http).calendars()
        XCTAssertEqual(http.sent.count, 1)
        XCTAssertTrue(http.sent[0].url.absoluteString.contains("/me/calendars"))
        XCTAssertEqual(feeds.map(\.id), ["A", "B"])
        XCTAssertEqual(feeds.first { $0.id == "B" }?.name, "Team shared")
        XCTAssertTrue(feeds.first { $0.id == "A" }?.isDefault == true)
    }

    func testCalendarRangeRequestShape() throws {
        let http = StubCalendarHTTP([(200, #"{"value":[\#(CalendarEventsTests.timed)]}"#)])
        let rows = try CalendarEventsTests.graph(http).calendarRange(
            id: "B", from: Date(timeIntervalSince1970: 1_790_000_000),
            to: Date(timeIntervalSince1970: 1_790_600_000))
        XCTAssertEqual(http.sent.count, 1)
        XCTAssertTrue(http.sent[0].url.absoluteString.contains("/me/calendars/B/calendarView"))
        XCTAssertEqual(rows.count, 1)
    }

    func testOverlayDemoEndToEnd() {
        let store = CalendarWeekStore(
            weekFetcher: { _ in CalWeekResponse(ok: true, weekStart: 0, days: 7, meetings: []) },
            localEdits: true)
        store.loadCalendars()
        XCTAssertEqual(store.overlayCalendars.map(\.id), ["demo-cal-shared"])
        store.setOverlay(id: "demo-cal-shared", on: true)
        XCTAssertFalse(store.overlayRows.isEmpty, "demo overlay rows load")
        let id = store.overlayRows[0].id
        XCTAssertEqual(store.overlayCalendarID(for: id), "demo-cal-shared")
        XCTAssertEqual(store.row(id: id)?.id, id, "overlay rows resolve for details")
        store.loadDetail(id: id)
        XCTAssertNotNil(store.details[id], "overlay details render from the row")
        XCTAssertNil(store.detailErrors[id])
        store.setOverlay(id: "demo-cal-shared", on: false)
        XCTAssertTrue(store.overlayRows.isEmpty)
        XCTAssertNil(store.overlayCalendarID(for: id))
    }

    func testOverlayWritesRefused() async {
        let runners = CalendarRunners(
            detail: { _ in throw CoreCallError.failed("must not call") },
            respond: { _, _ in throw CoreCallError.failed("must not call") },
            update: { _, _ in throw CoreCallError.failed("must not call") },
            meetNow: { _ in throw CoreCallError.failed("must not call") })
        let store = CalendarWeekStore(
            weekFetcher: { _ in CalWeekResponse(ok: true, weekStart: 0, days: 7, meetings: []) },
            runners: runners, localEdits: true)
        store.loadCalendars()
        store.setOverlay(id: "demo-cal-shared", on: true)
        let overlay = try? XCTUnwrap(store.overlayRows.first)
        let row = try? XCTUnwrap(overlay.map { r in
            MeetingItem(meetingId: r.id, subject: r.subject, start: r.start, end: r.end,
                        isOrganizer: false, info: r.info)
        })
        guard let row else { return XCTFail("no overlay row") }
        store.cancel(eventID: row.id)
        XCTAssertEqual(store.cancelError, "Other calendars are read-only")
        store.respond(to: row, .accept)
        XCTAssertEqual(store.rsvpError, "Other calendars are read-only")
        let personalOK = await store.setPersonal(row, CalendarEventPatch(showAs: "busy"))
        XCTAssertFalse(personalOK)
        XCTAssertEqual(store.personalError, "Other calendars are read-only")
        let forwardOK = await store.forward(row, to: ["a@x.example"])
        XCTAssertFalse(forwardOK)
        XCTAssertEqual(store.forwardError, "Other calendars are read-only")
        store.removeFromCalendar(row, decline: false)
        XCTAssertEqual(store.removeError, "Other calendars are read-only")
        let updateOK = await store.update(row, patch: CalendarEventPatch(hideAttendees: true))
        XCTAssertFalse(updateOK, "organizer-only update already refuses attendees")
    }

    // MARK: series/assistant store paths (functional check)

    func testAssistantFreeBusyPathFillsRows() async {
        let store = CalendarWeekStore(
            weekFetcher: { _ in CalWeekResponse(ok: true, weekStart: 0, days: 7, meetings: []) },
            runners: CalendarRunners(
                detail: { _ in throw CoreCallError.failed("x") }, respond: { _, _ in },
                update: { _, _ in throw CoreCallError.failed("x") },
                meetNow: { _ in throw CoreCallError.failed("x") },
                schedule: { emails, _, _ in emails.map { CalendarFreeBusy(email: $0, blocks: []) } }))
        let from = Date(), to = from.addingTimeInterval(3600)
        store.loadFreeBusy(["ann@contoso.example"], from: from, to: to)
        await TestWait.until { !store.freeBusyLoading }
        XCTAssertEqual(store.freeBusy.map(\.email), ["ann@contoso.example"])
        XCTAssertNil(store.freeBusyError)
    }
}
