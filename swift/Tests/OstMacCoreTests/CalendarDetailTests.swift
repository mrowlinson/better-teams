// CalendarDetailTests.swift — CALDETAIL / CAL2 pins: the organizer is
// never counted as an attendee (header tally == Tracking groups); the
// user's own entry shows their own response; request shapes for the
// personal fields, forward, RSVP on a series, free/busy, attachments,
// duplicate and webinar; attachment downloads land in the temp folder
// seam; .ics export; suggested times; personal-edit rollback; webinar
// detection; group Meet now creates → posts → joins. Stub transport
// only; zero live network.
import XCTest

@testable import OstMacCore

@MainActor
final class CalendarDetailTests: XCTestCase {
    static let invite = """
        {"id":"E9","subject":"Planning; Q4, draft","isAllDay":false,
         "start":{"dateTime":"2026-09-29T13:30:00.0000000","timeZone":"UTC"},
         "end":{"dateTime":"2026-09-29T14:30:00.0000000","timeZone":"UTC"},
         "createdDateTime":"2026-09-24T20:12:00Z",
         "isOnlineMeeting":true,"onlineMeeting":{"joinUrl":"https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0"},
         "organizer":{"emailAddress":{"name":"Harper, Megan","address":"megan@contoso.example"}},
         "responseStatus":{"response":"accepted"},
         "attendees":[
           {"type":"required","status":{"response":"organizer"},"emailAddress":{"name":"Harper, Megan","address":"megan@contoso.example"}},
           {"type":"required","status":{"response":"none"},"emailAddress":{"name":"Fox, Jordan","address":"jordan@contoso.example"}},
           {"type":"required","status":{"response":"accepted"},"emailAddress":{"name":"Becker, Tom","address":"tom@contoso.example"}},
           {"type":"optional","status":{"response":"declined"},"emailAddress":{"name":"Ortega, Luis","address":"luis@contoso.example"}},
           {"type":"required","status":{"response":"none"},"emailAddress":{"name":"Walsh, Grace","address":"grace@contoso.example"}},
           {"type":"resource","status":{"response":"accepted"},"emailAddress":{"name":"Room 4B","address":"r4b@contoso.example"}}]}
        """

    func testOrganizerNeverCountedAndOwnEntryShowsOwnResponse() throws {
        let row = try CalendarEvents.single(Data(Self.invite.utf8), tz: TimeZone(identifier: "UTC")!,
                                            me: "Jordan@contoso.example").row
        // Old header: organizer counted as accepted (the R34.4 bug).
        let raw = (row.info?.people ?? []).filter { $0.response == .accepted || $0.response == .organizer }.count
        XCTAssertEqual(raw, 3, "organizer + Tom + me")
        XCTAssertEqual(row.invitees.map(\.email), ["jordan@contoso.example", "tom@contoso.example",
                                                   "luis@contoso.example", "grace@contoso.example"])
        let t = row.tally
        XCTAssertEqual([t.accepted, t.tentative, t.declined, t.pending], [2, 0, 1, 1], "me (own response) + Tom")
        let groups = CalendarEventInfo.groups(row.invitees)
        XCTAssertEqual(groups.map(\.header), ["Accepted: 2", "Declined: 1", "Didn\u{2019}t respond: 1"])
        XCTAssertEqual(groups.reduce(0) { $0 + $1.people.count }, t.total, "header tally == Tracking groups")
        XCTAssertEqual(row.info?.tally.accepted, t.accepted, "info tally drops Graph's organizer entry too")
        // Organizer listed only by address (no `organizer` status) is also dropped.
        let byAddress = try CalendarEvents.single(Data(Self.invite.replacingOccurrences(
            of: #""status":{"response":"organizer"}"#, with: #""status":{"response":"accepted"}"#).utf8)).row
        XCTAssertEqual(byAddress.tally.accepted, 1)
        XCTAssertEqual(row.info?.sentAt, "2026-09-24T20:12:00")
        XCTAssertNotNil(row.sentDate)
    }

    func testRequestShapes() throws {
        let fileBytes = Data("hello".utf8).base64EncodedString()
        let http = StubCalendarHTTP([
            (200, Self.invite), (200, Self.invite), (202, ""), (202, ""), (202, ""),
            (200, #"{"value":[{"scheduleId":"tom@contoso.example","scheduleItems":[{"status":"busy","start":{"dateTime":"2026-09-29T14:00:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-09-29T15:00:00.0000000","timeZone":"UTC"}}]},{"scheduleId":"x@y.example","error":{"message":"no"}}]}"#),
            (200, #"{"contentBytes":"\#(fileBytes)"}"#),
            (201, Self.invite), (201, #"{"id":"W1"}"#),
            (200, #"{"value":[{"displayName":"Blue category","color":"preset7"}]}"#),
        ])
        let g = CalendarEventsTests.graph(http)
        _ = try g.update(id: "E9", patch: CalendarEventPatch(showAs: "free", reminderMinutes: 5,
                                                              categories: ["Blue category"], sensitivity: "private"))
        _ = try g.update(id: "E9", patch: CalendarEventPatch(reminderMinutes: -1))
        try g.forward(id: "E9", to: ["ann@contoso.example"], comment: "fyi")
        try g.respond(id: "S1", action: .accept)
        try g.respond(id: "E9", action: .decline)
        let fb = try g.schedule(for: ["tom@contoso.example", "x@y.example"],
                                from: Date(timeIntervalSince1970: 1_790_600_000), to: Date(timeIntervalSince1970: 1_790_640_000))
        let bytes = try g.attachment(eventID: "E9", attachmentID: "A/1")
        let draft = CalendarEventDraft(subject: "Copy", start: Date(timeIntervalSince1970: 1_790_600_000),
                                       end: Date(timeIntervalSince1970: 1_790_601_800), location: "Room 4B",
                                       attendees: [EventAttendee(name: "Tom", email: "tom@contoso.example")],
                                       bodyHTML: "<p>Agenda</p>", categories: ["Blue category"])
        _ = try g.create(draft)
        let webinar = try g.createWebinar(title: "Launch", start: Date(timeIntervalSince1970: 1_790_600_000),
                                          end: Date(timeIntervalSince1970: 1_790_603_600))
        let cats = try g.masterCategories()

        let s = http.sent
        XCTAssertEqual(s[0].method, "PATCH")
        XCTAssertEqual(s[0].body?["showAs"] as? String, "free")
        XCTAssertEqual(s[0].body?["isReminderOn"] as? Bool, true)
        XCTAssertEqual(s[0].body?["reminderMinutesBeforeStart"] as? Int, 5)
        XCTAssertEqual(s[0].body?["categories"] as? [String], ["Blue category"])
        XCTAssertEqual(s[0].body?["sensitivity"] as? String, "private")
        XCTAssertNil(s[0].body?["subject"], "personal edit touches nothing else")
        XCTAssertEqual(s[1].body?["isReminderOn"] as? Bool, false)
        XCTAssertNil(s[1].body?["reminderMinutesBeforeStart"])
        XCTAssertEqual(s[2].method, "POST")
        XCTAssertTrue(s[2].url.path.hasSuffix("/me/events/E9/forward"))
        let to = s[2].body?["toRecipients"] as? [[String: [String: String]]]
        XCTAssertEqual(to?.first?["emailAddress"]?["address"], "ann@contoso.example")
        XCTAssertEqual(s[2].body?["comment"] as? String, "fyi")
        // CAL2-2 RSVP: series master id for "all events", sendResponse on.
        XCTAssertTrue(s[3].url.path.hasSuffix("/me/events/S1/accept"))
        XCTAssertEqual(s[3].body?["sendResponse"] as? Bool, true)
        XCTAssertTrue(s[4].url.path.hasSuffix("/me/events/E9/decline"))
        XCTAssertEqual(s[5].method, "POST")
        XCTAssertTrue(s[5].url.path.hasSuffix("/me/calendar/getSchedule"))
        XCTAssertEqual(s[5].body?["schedules"] as? [String], ["tom@contoso.example", "x@y.example"])
        XCTAssertEqual(s[5].body?["availabilityViewInterval"] as? Int, 30)
        XCTAssertEqual(fb.count, 2)
        XCTAssertEqual(fb[0].blocks.first?.status, "busy")
        XCTAssertEqual(fb[0].blocks.first?.start, CalendarTime.instant("2026-09-29T14:00:00", zone: "UTC"))
        XCTAssertTrue(fb[1].unavailable)
        XCTAssertEqual(s[6].method, "GET")
        XCTAssertTrue(s[6].url.absoluteString.hasSuffix("/attachments/A%2F1"), "attachment id path-encoded")
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "hello")
        XCTAssertTrue(s[7].url.path.hasSuffix("/me/events"))
        XCTAssertEqual((s[7].body?["attendees"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((s[7].body?["body"] as? [String: String])?["contentType"], "html")
        XCTAssertEqual((s[7].body?["location"] as? [String: String])?["displayName"], "Room 4B")
        XCTAssertEqual(s[7].body?["isOnlineMeeting"] as? Bool, true)
        XCTAssertTrue(s[8].url.path.hasSuffix("/solutions/virtualEvents/webinars"))
        XCTAssertEqual(s[8].body?["displayName"] as? String, "Launch")
        XCTAssertEqual(webinar, "W1")
        XCTAssertEqual(cats, [CalendarCategory(name: "Blue category", color: "preset7")])
    }

    func testAttachmentDownloadLandsInSeamFolderAndNeverOverwrites() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CalDetail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dir.appendingPathComponent("Agenda.docx"))
        let store = CalendarWeekStore(
            weekFetcher: { _ in CalWeekResponse(ok: true, weekStart: 0, days: 7, meetings: []) },
            runners: CalendarRunners(
                detail: { _ in throw CoreCallError.failed("x") }, respond: { _, _ in },
                update: { _, _ in throw CoreCallError.failed("x") }, meetNow: { _ in throw CoreCallError.failed("x") },
                attachment: { event, id in
                    XCTAssertEqual(event, "E9")
                    XCTAssertEqual(id, "A1")
                    return Data("bytes".utf8)
                }))
        store.downloadsFolder = { dir }
        let file = EventAttachment(id: "A1", name: "Agenda.docx", size: 5)
        let saved = await store.downloadAttachment(eventID: "E9", file)
        let url = try XCTUnwrap(saved)
        XCTAssertEqual(url.lastPathComponent, "Agenda 2.docx", "existing file kept")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "bytes")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("Agenda.docx"), encoding: .utf8), "old")
        let again = await store.downloadAttachment(eventID: "E9", file)
        XCTAssertEqual(again, url, "second open reuses the saved file")
        XCTAssertTrue(url.path.hasPrefix(dir.path))
        XCTAssertEqual(EventAttachment(id: "b", name: "../x/y.pdf", size: 0).fileName, "-x-y.pdf")
    }

    func testICSExportAndPrintText() throws {
        let row = try CalendarEvents.single(Data(Self.invite.utf8), tz: TimeZone(identifier: "UTC")!).row
        let ics = CalendarExport.ics(row, now: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertTrue(ics.hasPrefix("BEGIN:VCALENDAR\r\n"))
        XCTAssertTrue(ics.contains("DTSTART:20260929T133000Z"))
        XCTAssertTrue(ics.contains("DTEND:20260929T143000Z"))
        XCTAssertTrue(ics.contains("SUMMARY:Planning\\; Q4\\, draft"), "RFC 5545 text escaping")
        XCTAssertTrue(ics.contains("ORGANIZER;CN=Megan Harper:mailto:megan@contoso.example"))
        XCTAssertFalse(ics.contains("ATTENDEE;CN=Megan Harper"), "organizer is not an attendee")
        XCTAssertTrue(ics.contains("PARTSTAT=DECLINED"))
        XCTAssertFalse(ics.contains("r4b@contoso.example"), "rooms are not attendees")
        for line in ics.components(separatedBy: "\r\n") { XCTAssertLessThanOrEqual(line.utf8.count, 75) }
        let allDay = MeetingItem(meetingId: "D", subject: "Offsite", start: "2026-09-29T00:00:00",
                                 end: "2026-10-01T00:00:00", isAllDay: true)
        let d = CalendarExport.ics(allDay)
        XCTAssertTrue(d.contains("DTSTART;VALUE=DATE:20260929"))
        XCTAssertTrue(d.contains("DTEND;VALUE=DATE:20261001"))
        XCTAssertEqual(CalendarExport.icsFileName(row), "Planning; Q4, draft.ics")
        let page = CalendarExport.printText(row, when: "Tue 9/29/2026")
        XCTAssertTrue(page.hasPrefix("Planning; Q4, draft\n"))
        XCTAssertTrue(page.contains("Accepted: 1"))
        XCTAssertFalse(page.contains("    Harper, Megan"), "organizer not listed as attendee")
    }

    func testSuggestionsSkipBusyAndStayInWorkingHours() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day = cal.date(from: DateComponents(year: 2026, month: 9, day: 29))!  // a Tuesday
        func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: day)! }
        let people = [
            CalendarFreeBusy(email: "a", blocks: [.init(status: "busy", start: at(8), end: at(10))]),
            CalendarFreeBusy(email: "b", blocks: [.init(status: "tentative", start: at(10), end: at(10, 30)),
                                                  .init(status: "free", start: at(11), end: at(12))]),
            CalendarFreeBusy(email: "c", blocks: [], unavailable: true),
        ]
        let slots = CalendarFreeBusy.suggestions(people, from: at(8), to: at(18), length: 3600, limit: 3, calendar: cal)
        XCTAssertEqual(slots.map(\.start), [at(10, 30), at(11), at(11, 30)])
        let late = CalendarFreeBusy.suggestions([], from: at(16, 30), to: at(20), length: 3600, calendar: cal)
        XCTAssertTrue(late.isEmpty, "16:30 + 1 h ends after 5 PM")
        let sat = cal.date(byAdding: .day, value: 4, to: day)!
        XCTAssertTrue(CalendarFreeBusy.suggestions([], from: sat, to: sat.addingTimeInterval(86_400), length: 1800,
                                                   calendar: cal).isEmpty, "weekends skipped")
    }

    func testReminderOffIsConfirmedByARereadAndReportsWhenOutlookKeepsIt() async throws {
        let base = try CalendarEvents.single(Data(Self.invite.utf8)).row
        let on = CalendarEventPatch(reminderMinutes: 15).applied(to: base)
        XCTAssertNotNil(on.info?.reminderMinutes)
        let detail = CalendarEventDetail(event: on, bodyHTML: nil, bodyText: nil, attachments: [], recurrence: nil)
        let store = CalendarWeekStore(
            weekFetcher: { _ in CalWeekResponse(ok: true, weekStart: 0, days: 7, meetings: [on]) },
            runners: CalendarRunners(
                detail: { _ in detail }, respond: { _, _ in },
                update: { _, _ in on },
                meetNow: { _ in throw CoreCallError.failed("x") },
                remove: { _ in throw CoreCallError.failed("x") }))
        await store.load()
        _ = await store.setPersonal(on, CalendarEventPatch(reminderMinutes: -1))
        XCTAssertEqual(store.personalError, "Outlook kept the reminder on for this event")
        XCTAssertNotNil(store.row(id: "E9")?.info?.reminderMinutes, "shows the truth, not the request")
    }

    func testPersonalEditAppliesAtOnceAndRollsBack() async throws {
        let row = try CalendarEvents.single(Data(Self.invite.utf8)).row
        let fail = StubFlag()
        let store = CalendarWeekStore(
            weekFetcher: { _ in CalWeekResponse(ok: true, weekStart: 0, days: 7, meetings: [row]) },
            runners: CalendarRunners(
                detail: { _ in throw CoreCallError.failed("x") }, respond: { _, _ in },
                update: { id, patch in
                    if fail.on { throw CoreCallError.failed("calendar: HTTP 500 (boom)") }
                    return patch.applied(to: row)
                },
                meetNow: { _ in throw CoreCallError.failed("x") },
                remove: { _ in throw CoreCallError.failed("calendar: HTTP 404 (gone)") }))
        await store.load()
        XCTAssertFalse(row.isOrganizer)
        let ok = await store.setPersonal(row, CalendarEventPatch(showAs: "free", categories: ["Blue category"]))
        XCTAssertTrue(ok, "attendees may change their own copy")
        XCTAssertEqual(store.row(id: "E9")?.info?.showAs, "free")
        XCTAssertEqual(store.row(id: "E9")?.categories, ["Blue category"])
        fail.on = true
        let failed = await store.setPersonal(row, CalendarEventPatch(sensitivity: "private"))
        XCTAssertFalse(failed)
        XCTAssertNotEqual(store.row(id: "E9")?.info?.sensitivity, "private", "rolled back")
        XCTAssertNotNil(store.personalError)
        let rejected = await store.setPersonal(row, CalendarEventPatch(subject: "x"))
        XCTAssertFalse(rejected, "organizer fields never go through the personal path")
        // Delete without responding: gone at once, back on failure.
        store.removeFromCalendar(row, decline: false)
        XCTAssertNil(store.meetings.first { $0.id == "E9" })
        await TestWait.until(interval: 0.002) { store.removeError != nil }
        XCTAssertNotNil(store.meetings.first { $0.id == "E9" })
    }

    func testDuplicateMovesPastOccurrenceForwardAndAddsOrganizer() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let row = MeetingItem(meetingId: "S", subject: "Standup", start: "2026-09-28T09:30:00", end: "2026-09-28T09:45:00",
                              organizer: "Ann Lee", organizerEmail: "ann@contoso.example")
        let now = CalendarTime.instant("2026-09-29T12:00:00", zone: "UTC")!
        let moved = CalendarEventDraft.duplicate(of: row, detail: nil, calendar: cal, now: now)
        XCTAssertEqual(CalendarTime.wallClock(moved.start, in: cal.timeZone), "2026-09-30T09:30:00")
        XCTAssertEqual(moved.end.timeIntervalSince(moved.start), 900)
        XCTAssertEqual(moved.attendees.map(\.email), ["ann@contoso.example"])
        let same = CalendarEventDraft.duplicate(of: row, detail: nil, calendar: cal)
        XCTAssertEqual(CalendarTime.wallClock(same.start, in: cal.timeZone), "2026-09-28T09:30:00")
    }

    func testWebinarDetectedFromInvitationText() {
        XCTAssertEqual(CalendarEventType.detect(isOnline: true, joinURL: "x", text: "Microsoft Teams webinar\nJoin",
                                                hasAttendees: true), .webinar)
        XCTAssertEqual(CalendarEventType.detect(isOnline: true, joinURL: "https://events.teams.microsoft.com/event/abc@1",
                                                text: "Join", hasAttendees: false), .webinar)
        XCTAssertEqual(CalendarEventType.detect(isOnline: true, joinURL: "x", text: "Microsoft Teams town hall",
                                                hasAttendees: false), .townHall)
        XCTAssertEqual(CalendarEventType.detect(isOnline: true, joinURL: "x", text: "Microsoft Teams meeting",
                                                hasAttendees: true), .meeting)
        XCTAssertEqual(CalendarEventType.detect(isOnline: false, joinURL: nil, text: "Dentist", hasAttendees: false),
                       .appointment)
        let gate = DemoGate.launch(args: ["--demo"])!
        let rows = CalendarDemo.week(gate, start: Int64(CalWeek.startOfWeek(containing: DemoClock.now).timeIntervalSince1970)).meetings
        XCTAssertEqual(rows.filter { $0.eventType == .webinar }.map(\.id), ["demo-cal-webinar"])
    }

    func testGroupMeetNowCreatesPostsInvitationThenJoins() async {
        var steps: [String] = []
        let row = MeetingItem(meetingId: "M1", subject: "Meeting in \u{201C}Standup\u{201D}",
                              joinURL: "https://teams.microsoft.com/l/meetup-join/19:meeting_m1@thread.v2/0",
                              isOrganizer: true, isOnline: true)
        let out = await GroupMeetNow.run(
            chatID: "19:group", chatName: "Standup",
            create: { name in steps.append("create:\(name)"); return row },
            createError: { nil },
            post: { chat, text in steps.append("post:\(chat):\(text.contains(row.joinURL!))") },
            join: { steps.append("join:\($0.id)") })
        XCTAssertEqual(out, .started(row))
        XCTAssertEqual(steps, ["create:Meeting in \u{201C}Standup\u{201D}", "post:19:group:true", "join:M1"])

        steps = []
        let unposted = await GroupMeetNow.run(
            chatID: "19:group", chatName: "Standup", create: { _ in row }, createError: { nil },
            post: { _, _ in throw CoreCallError.failed("send failed") }, join: { steps.append("join:\($0.id)") })
        if case .startedNotPosted = unposted {} else { XCTFail("meeting still started") }
        XCTAssertEqual(steps, ["join:M1"])

        steps = []
        let failed = await GroupMeetNow.run(
            chatID: "19:group", chatName: "Standup", create: { _ in nil }, createError: { "HTTP 403" },
            post: { _, _ in steps.append("post") }, join: { _ in steps.append("join") })
        XCTAssertEqual(failed, .failed("HTTP 403"))
        XCTAssertEqual(steps, [], "nothing posted or joined without a meeting")
    }
}
