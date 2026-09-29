// CalendarDemo.swift — CALENDAR lane: week-aware demo calendar (any
// week pages to real rows: weekday standup and weekly 1:1 series,
// one-offs this week and either side, all-day and multi-day all-day
// events, rooms, attendee responses, an organizer in another zone) and
// the demo details (body, dial-in, attachments). Nonisolated: runs in
// the store's off-main fetch closure. Every entry point takes the
// `DemoGate` a `--demo` launch mints, so live code cannot reach it.
import Foundation

public enum CalendarDemo {
    static let owner = DemoData.ownerDisplayName
    static let ownerEmail = "jordan.fox@contoso.example"

    struct Person {
        let name: String
        let email: String
    }

    static let megan = Person(name: "Harper, Megan", email: "megan.harper@contoso.example")
    static let luis = Person(name: "Ortega, Luis", email: "luis.ortega@contoso.example")
    static let ava = Person(name: "Lindqvist, Ava", email: "ava.lindqvist@contoso.example")
    static let paula = Person(name: "Norris, Paula", email: "paula.norris@contoso.example")
    static let tom = Person(name: "Becker, Tom", email: "tom.becker@contoso.example")
    static let grace = Person(name: "Walsh, Grace", email: "grace.walsh@contoso.example")
    static let me = Person(name: owner, email: ownerEmail)

    static func attendee(_ p: Person, _ r: RSVPResponse, optional: Bool = false) -> EventAttendee {
        EventAttendee(name: p.name, email: p.email, type: optional ? "optional" : "required", response: r)
    }

    static func room(_ name: String) -> EventAttendee {
        EventAttendee(name: name, email: name.lowercased().replacingOccurrences(of: " ", with: ".") + "@contoso.example",
                      type: "resource", response: .accepted)
    }

    /// The week starting at unix `weekStart`.
    public static func week(_ gate: DemoGate, start weekStart: Int64, now: Date = DemoClock.now,
                            calendar cal: Calendar = .current) -> CalWeekResponse {
        let start = Date(timeIntervalSince1970: TimeInterval(weekStart))
        let thisWeek = CalWeek.startOfWeek(containing: now, calendar: cal)
        let weekIndex = Int((cal.dateComponents([.day], from: thisWeek, to: start).day ?? 0) / 7)
        // Offsets count from Monday, whatever day the locale's week starts on.
        let mondayOffset = (2 - cal.firstWeekday + 7) % 7
        func day(_ offset: Int) -> Date {
            cal.date(byAdding: .day, value: mondayOffset + offset, to: start) ?? start
        }
        func at(_ offset: Int, _ h: Int, _ m: Int) -> String {
            let p = cal.dateComponents([.year, .month, .day], from: day(offset))
            let d = cal.date(from: DateComponents(year: p.year, month: p.month, day: p.day, hour: h, minute: m)) ?? start
            return CalendarTime.wallClock(d, in: cal.timeZone)
        }
        func dayKey(_ offset: Int) -> String { String(at(offset, 0, 0).prefix(10)) + "T00:00:00" }
        func join(_ id: String) -> String { "https://teams.microsoft.com/l/meetup-join/19:meeting_\(id)@thread.v2/0" }

        func meeting(_ id: String, _ subject: String, day d: Int, _ h: Int, _ m: Int, minutes: Int,
                     organizer: Person, category: String, online: Bool = true,
                     info: CalendarEventInfo) -> MeetingItem {
            let endMinute = h * 60 + m + minutes
            return MeetingItem(
                meetingId: id, subject: subject, start: at(d, h, m), end: at(d, endMinute / 60, endMinute % 60),
                joinURL: online ? join(id) : nil, organizer: organizer.name, organizerEmail: organizer.email,
                isOrganizer: organizer.email == ownerEmail, isOnline: online, categories: [category],
                info: info)
        }
        func info(_ attendees: [EventAttendee], mine: RSVPResponse = .accepted, location: String? = nil,
                  kind: CalendarEventKind = .singleInstance, series: String? = nil, recurrence: String? = nil,
                  zone: String? = nil, attachments: Bool = false, online: Bool = true,
                  preview: String? = nil) -> CalendarEventInfo {
            CalendarEventInfo(
                location: location, myResponse: mine, showAs: mine == .tentativelyAccepted ? "tentative" : "busy",
                kind: kind, seriesMasterID: series, attendees: attendees, originalStartTimeZone: zone,
                hasAttachments: attachments, bodyPreview: preview, reminderMinutes: 15,
                dialIn: online ? EventDialIn(tollNumber: "+1 555-0142", conferenceID: "618 204 339#") : nil,
                recurrence: recurrence)
        }

        var rows: [MeetingItem] = []
        // Weekday standup series (every week).
        for d in 0 ..< 5 {
            let id = weekIndex == 0 && d == 0 ? "demo-cal-standup" : "demo-cal-standup-w\(weekIndex)d\(d)"
            rows.append(meeting(
                id, "Engineering standup", day: d, 9, 30, minutes: 30, organizer: megan, category: "Blue category",
                info: info([attendee(megan, .organizer), attendee(me, .accepted), attendee(tom, .accepted),
                            attendee(ava, .tentativelyAccepted), attendee(luis, .notResponded, optional: true)],
                           kind: .occurrence, series: "demo-cal-standup-series",
                           recurrence: "Occurs every weekday starting Jan 5, 2026",
                           preview: "Daily check-in: yesterday, today, blockers.")))
        }
        // Weekly 1:1 series (Tuesday).
        rows.append(meeting(
            weekIndex == 0 ? "demo-cal-oneonone" : "demo-cal-oneonone-w\(weekIndex)", "1:1 with Megan",
            day: 1, 13, 0, minutes: 30, organizer: megan, category: "Yellow category",
            info: info([attendee(megan, .organizer), attendee(me, .accepted)], kind: .occurrence,
                       series: "demo-cal-oneonone-series", recurrence: "Occurs every Tuesday starting Feb 3, 2026")))

        switch weekIndex {
        case 0:
            rows += [
                meeting("demo-cal-planning", "Sprint planning", day: 0, 11, 0, minutes: 60, organizer: megan,
                        category: "Purple category",
                        info: info([attendee(megan, .organizer), attendee(me, .accepted), attendee(tom, .accepted),
                                    attendee(ava, .accepted), attendee(paula, .declined)], attachments: true,
                                   preview: "Pick the sprint goal and commit the backlog.")),
                meeting("demo-cal-northwind", "Customer call: Northwind", day: 0, 14, 0, minutes: 60, organizer: luis,
                        category: "Orange category",
                        info: info([attendee(luis, .organizer), attendee(me, .accepted), attendee(grace, .notResponded)],
                                   zone: "Pacific Standard Time",
                                   preview: "Quarterly check-in with the Northwind team.")),
                meeting("demo-cal-crit", "Design critique", day: 1, 10, 0, minutes: 60, organizer: ava,
                        category: "Purple category", online: false,
                        info: info([attendee(ava, .organizer), attendee(me, .accepted), attendee(megan, .accepted),
                                    room("Conference Room 4B")], location: "Conference Room 4B", online: false)),
                meeting("demo-cal-hiring", "Hiring sync", day: 1, 15, 30, minutes: 30, organizer: paula,
                        category: "Red category",
                        info: info([attendee(paula, .organizer), attendee(me, .tentativelyAccepted),
                                    attendee(megan, .accepted)], mine: .tentativelyAccepted)),
                MeetingItem(
                    meetingId: "demo-cal-roadmap", subject: "Roadmap review", start: at(2, 10, 0), end: at(2, 11, 30),
                    joinURL: join("demo_roadmap"), organizer: owner, organizerEmail: ownerEmail,
                    isOrganizer: true, isOnline: true, categories: ["Blue category"],
                    info: info([attendee(me, .organizer), attendee(megan, .accepted), attendee(tom, .accepted),
                                attendee(ava, .declined), attendee(luis, .notResponded), attendee(grace, .notResponded, optional: true),
                                room("Board Room")], mine: .organizer, location: "Board Room",
                               preview: "Walk through the next two quarters.")),
                meeting("demo-cal-vendor", "Vendor demo", day: 2, 13, 0, minutes: 60, organizer: tom,
                        category: "Orange category",
                        info: info([attendee(tom, .organizer), attendee(me, .notResponded), attendee(paula, .accepted)],
                                   mine: .notResponded)),
                meeting("demo-cal-focus", "Focus time", day: 2, 14, 30, minutes: 120, organizer: me,
                        category: "Gray category", online: false,
                        info: info([], mine: .organizer, online: false)),
                meeting("demo-cal-design", "Design sync", day: 3, 9, 0, minutes: 60, organizer: ava,
                        category: "Purple category",
                        info: info([attendee(ava, .organizer), attendee(me, .notResponded), attendee(megan, .accepted),
                                    attendee(tom, .notResponded)], mine: .notResponded)),
                meeting("demo-cal-gonogo", "Release go/no-go", day: 3, 11, 0, minutes: 30, organizer: megan,
                        category: "Red category",
                        info: info([attendee(megan, .organizer), attendee(me, .accepted), attendee(tom, .accepted)])),
                meeting("demo-cal-lunch", "Team lunch", day: 3, 12, 30, minutes: 60, organizer: paula,
                        category: "Green category", online: false,
                        info: info([attendee(paula, .organizer), attendee(me, .accepted), attendee(grace, .accepted)],
                                   location: "Harbor Café", online: false)),
                meeting("demo-cal-demo", "Sprint demo", day: 4, 10, 0, minutes: 60, organizer: megan,
                        category: "Blue category",
                        info: info([attendee(megan, .organizer), attendee(me, .accepted), attendee(tom, .accepted),
                                    attendee(ava, .accepted)])),
                meeting("demo-cal-retro", "Retrospective", day: 4, 11, 0, minutes: 45, organizer: tom,
                        category: "Teal category",
                        info: info([attendee(tom, .organizer), attendee(me, .accepted), attendee(megan, .accepted)])),
                meeting("demo-cal-tom", "1:1 with Tom", day: 4, 14, 0, minutes: 30, organizer: me,
                        category: "Yellow category",
                        info: info([attendee(me, .organizer), attendee(tom, .accepted)], mine: .organizer)),
                MeetingItem(
                    meetingId: "demo-cal-offsite", subject: "Team offsite", start: dayKey(4), end: dayKey(5),
                    organizer: paula.name, organizerEmail: paula.email, categories: ["Green category"],
                    isAllDay: true,
                    info: info([attendee(paula, .organizer), attendee(me, .accepted), attendee(megan, .accepted)],
                               location: "Lakeside Lodge", online: false)),
            ]
        case 1:
            rows += [
                meeting("demo-cal-kickoff", "Q4 kickoff", day: 0, 13, 0, minutes: 90, organizer: megan,
                        category: "Purple category",
                        info: info([attendee(megan, .organizer), attendee(me, .notResponded), attendee(tom, .accepted)],
                                   mine: .notResponded)),
                MeetingItem(
                    meetingId: "demo-cal-training", subject: "Security training", start: dayKey(1), end: dayKey(3),
                    organizer: grace.name, organizerEmail: grace.email, categories: ["Red category"], isAllDay: true,
                    info: info([attendee(grace, .organizer), attendee(me, .accepted)], online: false)),
            ]
        case -1:
            rows.append(meeting(
                "demo-cal-budget", "Budget review", day: 2, 15, 0, minutes: 60, organizer: paula,
                category: "Orange category",
                info: info([attendee(paula, .organizer), attendee(me, .accepted), attendee(megan, .accepted)])))
        default:
            break
        }
        return CalWeekResponse(ok: true, weekStart: weekStart, days: 7, meetings: rows)
    }

    /// Demo details for a row (agenda body, attachments, series text).
    public static func detail(_ gate: DemoGate, for row: MeetingItem) -> CalendarEventDetail {
        let preview = row.info?.bodyPreview ?? "Agenda to follow."
        let html = "<p>\(preview)</p><p><b>Agenda</b></p><ul><li>Updates</li><li>Open questions</li>"
            + "<li>Next steps</li></ul><p>Notes: <a href=\"https://contoso.example/notes\">team notes</a></p>"
        let attachments = row.info?.hasAttachments == true
            ? [EventAttachment(id: "demo-att-1", name: "Sprint goals.docx", size: 48_213),
               EventAttachment(id: "demo-att-2", name: "Burndown.xlsx", size: 20_480)]
            : []
        return CalendarEventDetail(event: row, bodyHTML: html, attachments: attachments,
                                   recurrence: row.info?.recurrence)
    }
}
