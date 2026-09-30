// CalendarDetailFin2Tests.swift — CALDETAIL-FIN2 pins: one display-name
// format; the user's own entry (mail or UPN) is flagged and never copied
// into a duplicate; a series' instances read through the store; demo
// "Sent on" differs per event and precedes it. Stub runners only.
import XCTest

@testable import OstMacCore

@MainActor
final class CalendarDetailFin2Tests: XCTestCase {
    func testDisplayNameOneFormat() {
        XCTAssertEqual(CalendarNames.display("Harper, Megan"), "Megan Harper")
        XCTAssertEqual(CalendarNames.display("Jordan Fox"), "Jordan Fox")
        XCTAssertEqual(CalendarNames.display("ann.lee@contoso.example"), "Ann Lee")
        XCTAssertEqual(CalendarNames.display("", email: "tom.becker@contoso.example"), "Tom Becker")
        XCTAssertEqual(CalendarNames.display("", email: "tbecker@contoso.example"), "tbecker@contoso.example")
        XCTAssertEqual(CalendarNames.display("Conference Room 4B"), "Conference Room 4B")
        XCTAssertEqual(CalendarNames.display("Smith, John (Contractor)"), "Smith, John (Contractor)")
        let me = EventAttendee(name: "Fox, Jordan", email: "j@x", isMe: true)
        XCTAssertEqual(me.label, "Jordan Fox (You)")
    }

    func testOwnEntryByMailOrUPNIsFlaggedAndNeverDuplicated() throws {
        let json = """
            {"id":"E1","subject":"Sync","isAllDay":false,
             "start":{"dateTime":"2026-09-30T13:00:00","timeZone":"UTC"},
             "end":{"dateTime":"2026-09-30T14:00:00","timeZone":"UTC"},
             "organizer":{"emailAddress":{"name":"Harper, Megan","address":"megan@contoso.example"}},
             "attendees":[
               {"type":"required","status":{"response":"organizer"},"emailAddress":{"name":"Harper, Megan","address":"megan@contoso.example"}},
               {"type":"required","status":{"response":"accepted"},"emailAddress":{"name":"Fox, Jordan","address":"jfox@contoso.onmicrosoft.example"}},
               {"type":"optional","status":{"response":"none"},"emailAddress":{"name":"Becker, Tom","address":"tom@contoso.example"}}]}
            """
        let row = try CalendarEvents.single(Data(json.utf8), tz: TimeZone(identifier: "UTC")!,
                                            me: "jordan.fox@contoso.example",
                                            meAliases: ["jordan.fox@contoso.example", "jfox@contoso.onmicrosoft.example"]).row
        XCTAssertEqual(row.invitees.filter(\.isMe).map(\.email), ["jfox@contoso.onmicrosoft.example"])
        let draft = CalendarEventDraft.duplicate(of: row, detail: nil)
        XCTAssertEqual(draft.attendees.map(\.email), ["megan@contoso.example", "tom@contoso.example"])
        XCTAssertEqual(draft.attendees.map(\.type), ["required", "optional"], "roles kept")
        // A row read without the flag: the caller's addresses still filter it.
        let bare = MeetingItem(meetingId: "B", subject: "S", start: "2026-09-30T13:00:00", end: "2026-09-30T14:00:00",
                               info: CalendarEventInfo(attendees: [
                                   EventAttendee(name: "Me", email: "Me@x.example"),
                                   EventAttendee(name: "Ann", email: "ann@x.example")]))
        XCTAssertEqual(CalendarEventDraft.duplicate(of: bare, detail: nil, myAddresses: ["me@x.example"])
            .attendees.map(\.email), ["ann@x.example"])
    }

    func testAttendeeDecodesWithoutIsMe() throws {
        let old = #"{"name":"A","email":"a@x","type":"required","response":"accepted"}"#
        XCTAssertFalse(try JSONDecoder().decode(EventAttendee.self, from: Data(old.utf8)).isMe)
    }

    func testSeriesInstancesReadThroughTheStore() async throws {
        let master = MeetingItem(meetingId: "M1", subject: "Standup", start: "2026-09-29T09:30:00", end: "2026-09-29T09:45:00",
                                 info: CalendarEventInfo(kind: .occurrence, seriesMasterID: "M1"))
        XCTAssertEqual(CalendarWeekStore.seriesID(of: master), "M1")
        let one = MeetingItem(meetingId: "O", subject: "Solo", start: "2026-09-29T09:30:00", end: "2026-09-29T09:45:00")
        XCTAssertNil(CalendarWeekStore.seriesID(of: one))
        let rows = [
            MeetingItem(meetingId: "I2", subject: "Standup", start: "2026-10-01T09:30:00", end: "2026-10-01T09:45:00",
                        info: CalendarEventInfo(kind: .occurrence, seriesMasterID: "M1")),
            MeetingItem(meetingId: "I1", subject: "Standup", start: "2026-09-30T09:30:00", end: "2026-09-30T09:45:00",
                        info: CalendarEventInfo(kind: .occurrence, seriesMasterID: "M1")),
        ]
        var asked: [String] = []
        let box = OSAllocatedLockBox()
        let store = CalendarWeekStore(
            weekFetcher: { _ in CalWeekResponse(ok: true, weekStart: 0, days: 7, meetings: []) },
            runners: CalendarRunners(
                detail: { _ in throw CoreCallError.failed("x") }, respond: { _, _ in },
                update: { _, _ in throw CoreCallError.failed("x") },
                meetNow: { _ in throw CoreCallError.failed("x") },
                instances: { id, from, to in
                    box.record(id)
                    XCTAssertLessThan(from, to)
                    return rows
                }))
        store.loadInstances(series: "M1")
        for _ in 0 ..< 100 where store.seriesInstances["M1"] == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        asked = box.values
        XCTAssertEqual(asked, ["M1"])
        XCTAssertEqual(store.seriesInstances["M1"]?.map(\.id), ["I1", "I2"], "start order")
        XCTAssertEqual(store.row(id: "I2")?.id, "I2", "instance rows resolve for the details sheet")
        store.loadInstances(series: "M1")
        XCTAssertEqual(box.values.count, 1, "read once")
    }

    func testDemoSentOnDiffersPerEventAndPrecedesIt() throws {
        let gate = try XCTUnwrap(DemoGate.launch(args: ["--demo"]))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = CalendarTime.instant("2026-09-29T15:00:00", zone: "UTC")!
        let start = CalWeek.startOfWeek(containing: now, calendar: cal)
        let rows = CalendarDemo.week(gate, start: Int64(start.timeIntervalSince1970), now: now, calendar: cal).meetings
        let sent = rows.compactMap { $0.info?.sentAt }
        XCTAssertEqual(sent.count, rows.count)
        XCTAssertGreaterThan(Set(sent).count, 8, "distinct values, not one for every event")
        for r in rows {
            let s = try XCTUnwrap(r.sentDate)
            let a = CalendarTime.instant(r.start, zone: r.isAllDay ? "UTC" : "UTC")!
            XCTAssertLessThan(s, a, r.subject)
        }
        let instances = CalendarDemo.instances(gate, series: "demo-cal-standup-series",
                                               from: now.addingTimeInterval(-14 * 86_400),
                                               to: now.addingTimeInterval(21 * 86_400), calendar: cal)
        XCTAssertGreaterThanOrEqual(instances.count, 10)
        let master = try XCTUnwrap(CalendarDemo.seriesMaster("demo-cal-standup-series", from: rows))
        XCTAssertEqual(master.info?.kind, .seriesMaster)
        XCTAssertEqual(master.id, "demo-cal-standup-series")
    }
}

/// Thread-safe recorder for `@Sendable` runner closures.
private final class OSAllocatedLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func record(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
