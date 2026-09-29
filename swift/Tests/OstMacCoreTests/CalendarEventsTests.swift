// CalendarEventsTests.swift — CALENDAR lane pins: calendarView read in
// UTC and shown in the local zone (all-day dates never shift), request
// shapes for RSVP / edit / Meet now / delete, series wording, safe body
// rendering, month composition, time-zone change and RSVP rollback.
// Stub transport only; zero live network.
import XCTest

@testable import OstMacCore

final class StubCalendarHTTP: CalendarHTTP, @unchecked Sendable {
    struct Sent {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: [String: Any]?
    }

    private let lock = NSLock()
    private var _sent: [Sent] = []
    var replies: [(Int, String)]

    init(_ replies: [(Int, String)]) { self.replies = replies }

    var sent: [Sent] { lock.withLock { _sent } }

    func send(_ method: String, url: URL, headers: [String: String], body: Data?) throws -> ReadHTTPResponse {
        lock.withLock {
            let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            _sent.append(Sent(method: method, url: url, headers: headers, body: json))
            let r = replies.isEmpty ? (200, "{}") : replies.removeFirst()
            return ReadHTTPResponse(status: r.0, data: Data(r.1.utf8))
        }
    }
}

@MainActor
final class CalendarEventsTests: XCTestCase {
    nonisolated static let newYork = TimeZone(identifier: "America/New_York")!

    static func graph(_ http: StubCalendarHTTP, tz: TimeZone = newYork) -> CalendarGraph {
        CalendarGraph(http: http, token: { "t" }, timeZone: { tz })
    }

    static let timed = """
        {"id":"E1","subject":"Standup","isAllDay":false,
         "start":{"dateTime":"2026-09-29T13:30:00.0000000","timeZone":"UTC"},
         "end":{"dateTime":"2026-09-29T13:45:00.0000000","timeZone":"UTC"},
         "isOnlineMeeting":true,"onlineMeeting":{"joinUrl":"https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0","tollNumber":"+1 555-0100","conferenceId":"123#"},
         "organizer":{"emailAddress":{"name":"Doe, Jane","address":"jane@contoso.example"}},
         "responseStatus":{"response":"notResponded"},"type":"occurrence","seriesMasterId":"S1",
         "originalStartTimeZone":"Pacific Standard Time",
         "locations":[{"displayName":"Room 1"},{"displayName":"Room 2"}],
         "attendees":[{"type":"required","status":{"response":"accepted"},"emailAddress":{"name":"Ann Lee","address":"ann@contoso.example"}},
                      {"type":"optional","status":{"response":"none"},"emailAddress":{"name":"Bob Ray","address":"bob@contoso.example"}},
                      {"type":"resource","status":{"response":"accepted"},"emailAddress":{"name":"Room 1","address":"r1@contoso.example"}}]}
        """
    static let allDay = """
        {"id":"E2","subject":"Offsite","isAllDay":true,
         "start":{"dateTime":"2026-09-29T00:00:00.0000000","timeZone":"UTC"},
         "end":{"dateTime":"2026-10-01T00:00:00.0000000","timeZone":"UTC"}}
        """

    func testWeekReadIsUTCAndShownInLocalZone() throws {
        let http = StubCalendarHTTP([
            (200, #"{"value":[\#(Self.timed)],"@odata.nextLink":"https://graph.microsoft.com/v1.0/me/calendarView?page=2"}"#),
            (200, #"{"value":[\#(Self.allDay)]}"#),
        ])
        let week = try Self.graph(http).week(start: 1_790_553_600)
        XCTAssertEqual(http.sent.count, 2, "nextLink followed")
        let first = http.sent[0]
        XCTAssertEqual(first.headers["Prefer"], #"outlook.timezone="UTC""#)
        XCTAssertTrue(first.url.absoluteString.contains("$select=id,subject,start,end,isAllDay"))
        XCTAssertTrue(first.url.absoluteString.contains("startDateTime=2026-"))

        let e1 = try XCTUnwrap(week.meetings.first { $0.id == "E1" })
        XCTAssertEqual(e1.start, "2026-09-29T09:30:00", "13:30 UTC = 9:30 EDT")
        XCTAssertEqual(e1.utcStart, "2026-09-29T13:30:00")
        XCTAssertEqual(e1.info?.location, "Room 1; Room 2")
        XCTAssertEqual(e1.info?.myResponse, .notResponded)
        XCTAssertEqual(e1.info?.kind, .occurrence)
        XCTAssertEqual(e1.info?.seriesMasterID, "S1")
        XCTAssertEqual(e1.info?.tally, CalendarEventInfo.Tally(accepted: 1, tentative: 0, declined: 0, pending: 1))
        XCTAssertEqual(e1.info?.rooms.count, 1)
        XCTAssertEqual(e1.info?.dialIn?.conferenceID, "123#")
        XCTAssertEqual(e1.chatThreadID, "19:meeting_abc@thread.v2")
        XCTAssertNotNil(CalendarTime.organizerZone(e1, local: Self.newYork), "organizer in Pacific time")

        let e2 = try XCTUnwrap(week.meetings.first { $0.id == "E2" })
        XCTAssertEqual(e2.start, "2026-09-29T00:00:00", "all-day dates never shift")
        XCTAssertTrue(e2.isAllDay)
        let cols = CalWeek.bucket([e2], keys: ["2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01"])
        XCTAssertEqual(cols.map(\.count), [0, 1, 1, 0], "multi-day all-day covers each day, end exclusive")

        // Same instants in another zone.
        let tokyo = CalendarTime.localize(e1, to: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertEqual(tokyo.start, "2026-09-29T22:30:00")
        XCTAssertEqual(CalendarTime.localize(e2, to: TimeZone(identifier: "Asia/Tokyo")!).start, e2.start)
    }

    func testWriteRequestShapes() throws {
        let http = StubCalendarHTTP([
            (202, ""), (200, Self.timed), (201, Self.timed), (204, ""), (400, #"{"error":{"message":"nope"}}"#),
        ])
        let g = Self.graph(http)
        try g.respond(id: "S1", action: .tentativelyAccept)
        _ = try g.update(id: "E1", patch: CalendarEventPatch(subject: "New", start: "2026-09-29T10:00:00",
                                                              end: "2026-09-29T10:30:00", timeZone: "America/New_York"))
        let created = try g.create(subject: "Meeting with Jordan", start: Date(timeIntervalSince1970: 1_790_600_000),
                                   end: Date(timeIntervalSince1970: 1_790_603_600), online: true)
        try g.delete(id: "E1")
        XCTAssertThrowsError(try g.respond(id: "E1", action: .accept)) { e in
            XCTAssertTrue("\(e)".contains("nope"))
            XCTAssertFalse("\(e)".contains("graph.microsoft.com"), "no URL in errors")
        }
        let s = http.sent
        XCTAssertEqual(s[0].method, "POST")
        XCTAssertTrue(s[0].url.path.hasSuffix("/me/events/S1/tentativelyAccept"))
        XCTAssertEqual(s[0].body?["sendResponse"] as? Bool, true)
        XCTAssertEqual(s[1].method, "PATCH")
        XCTAssertEqual(s[1].body?["subject"] as? String, "New")
        XCTAssertEqual((s[1].body?["start"] as? [String: String])?["timeZone"], "America/New_York")
        XCTAssertNil(s[1].body?["location"])
        XCTAssertEqual(s[2].method, "POST")
        XCTAssertTrue(s[2].url.path.hasSuffix("/me/events"))
        XCTAssertEqual(s[2].body?["isOnlineMeeting"] as? Bool, true)
        XCTAssertEqual(s[2].body?["onlineMeetingProvider"] as? String, "teamsForBusiness")
        XCTAssertEqual((s[2].body?["attendees"] as? [Any])?.count, 0, "Meet now invites no one")
        XCTAssertEqual(s[2].headers["Content-Type"], "application/json")
        XCTAssertNotNil(created.joinURL)
        XCTAssertEqual(s[3].method, "DELETE")
    }

    func testRecurrenceWordingAndSafeBody() throws {
        let r = try JSONDecoder().decode(GraphEventWire.Recurrence.self, from: Data("""
            {"pattern":{"type":"weekly","interval":1,"daysOfWeek":["friday","monday","tuesday","wednesday","thursday"]},
             "range":{"type":"endDate","startDate":"2026-09-01","endDate":"2026-12-18"}}
            """.utf8))
        XCTAssertEqual(CalendarEvents.recurrenceSummary(r), "Occurs every weekday starting Sep 1, 2026 until Dec 18, 2026")

        let body = EventBodyRender.attributed(html: """
            <html><head><style>p{color:red}</style><script>alert(1)</script></head><body>
            <p>Hello&nbsp;team</p><img src="https://tracker.example/x.png"><a href="javascript:evil()">bad</a>
            <a href="https://contoso.example/notes">notes</a></body></html>
            """)
        let text = String(body.characters)
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertFalse(text.contains("alert"))
        XCTAssertFalse(text.contains("color"))
        XCTAssertFalse(text.contains("tracker"))
        let links = body.runs.compactMap(\.link)
        XCTAssertEqual(links, [URL(string: "https://contoso.example/notes")!], "only safe schemes link")
    }

    func testMonthComposesWeeksAndRSVPRollsBack() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.newYork
        cal.firstWeekday = 2
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 12))!
        let fixed = cal
        let gate = try XCTUnwrap(DemoGate.launch(args: ["--demo"]))
        let fail = StubFlag()
        let store = CalendarWeekStore(
            weekStart: CalWeek.startOfWeek(containing: now, calendar: cal), calendar: cal,
            weekFetcher: { CalendarDemo.week(gate, start: $0, now: now, calendar: fixed) },
            runners: CalendarRunners(
                detail: { _ in throw CoreCallError.failed("x") },
                respond: { _, _ in if fail.on { throw CoreCallError.failed("calendar: HTTP 500 (boom)") } },
                update: { _, _ in throw CoreCallError.failed("x") },
                meetNow: { _ in throw CoreCallError.failed("x") }))
        store.jump(to: now, span: .month)
        for _ in 0 ..< 500 where !store.monthLoaded { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(store.monthLoaded)
        XCTAssertEqual(store.monthWeeks, 5, "Sep 2026, Monday-first: 5 rows")
        XCTAssertEqual(store.monthDayKeys.first, "2026-08-31")
        XCTAssertEqual(Set(store.monthMeetings.map(\.id)).count, store.monthMeetings.count, "deduplicated")
        XCTAssertTrue(store.monthMeetings.contains { $0.id == "demo-cal-budget" }, "last week (a month row) is in")

        await store.load()
        let row = try XCTUnwrap(store.meetings.first { $0.id == "demo-cal-design" })
        fail.on = true
        store.respond(to: row, .decline)
        XCTAssertNil(store.meetings.first { $0.id == "demo-cal-design" }, "decline drops the row at once")
        for _ in 0 ..< 500 where store.respondingID != nil { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertNotNil(store.meetings.first { $0.id == "demo-cal-design" }, "failure restores it")
        XCTAssertNotNil(store.rsvpError)
    }

    func testTimeZoneChangeRelocalizesWithoutBlank() async {
        let utcRow = MeetingItem(meetingId: "Z", subject: "Sync", start: "2026-09-29T09:30:00",
                                 end: "2026-09-29T10:00:00", utcStart: "2026-09-29T13:30:00", utcEnd: "2026-09-29T14:00:00")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.newYork
        let start = CalWeek.startOfWeek(containing: CalendarTime.instant("2026-09-29T16:00:00")!, calendar: cal)
        let store = CalendarWeekStore(
            weekStart: start, calendar: cal,
            weekFetcher: { CalWeekResponse(ok: true, weekStart: $0, days: 7, meetings: [utcRow]) })
        await store.load()
        store.applyTimeZone(TimeZone(identifier: "Europe/London")!)
        XCTAssertEqual(store.meetings.first?.start, "2026-09-29T14:30:00", "13:30 UTC = 14:30 BST, at once")
        XCTAssertTrue(store.dayKeys.contains("2026-09-29"))
    }
}

final class StubFlag: @unchecked Sendable {
    var on = false
}
