// CalendarLiveProbeTests.swift — opt-in live proof of the calendar Graph
// client (CALENDAR_LIVE=1). Read-only: this week's calendarView (UTC,
// shown local). With CALENDAR_LIVE_WRITE=1 also one solo
// meeting (subject "test", no attendees): create, move once, delete.
// Prints counts and booleans only, never subjects, names, tokens or URLs.
import Foundation
import XCTest
@testable import OstMacCore

final class CalendarLiveProbeTests: XCTestCase {
    func testLiveCalendarWeekAndSoloMeeting() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CALENDAR_LIVE"] == "1" else {
            throw XCTSkip("set CALENDAR_LIVE=1 to run the live calendar probe")
        }
        var log: [String] = []
        func note(_ s: String) {
            print("PROBE \(s)")
            log.append(s)
        }
        defer {
            if let path = env["CALENDAR_LIVE_LOG"] {
                try? (log.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        let g = CalendarGraph.production()
        let start = Calendar.current.startOfDay(for: CalWeek.startOfWeek(containing: Date()))
        let week = try g.week(start: Int64(start.timeIntervalSince1970))
        let rows = week.meetings
        let timed = rows.filter { !$0.isAllDay }
        let consistent = timed.allSatisfy { CalendarTime.localize($0).start == $0.start && $0.utcStart != nil }
        note("week rows=\(rows.count) allDay=\(rows.count - timed.count) timedLocalized=\(consistent)")
        note("fields location=\(rows.filter { $0.info?.location != nil }.count) series=\(rows.filter(\.isSeries).count) "
            + "attendees=\(rows.filter { !($0.info?.people.isEmpty ?? true) }.count) chat=\(rows.filter { $0.chatThreadID != nil }.count) "
            + "organizerZoneDiffers=\(rows.filter { CalendarTime.organizerZone($0) != nil }.count)")
        let responses = Dictionary(grouping: rows.compactMap { $0.info?.myResponse.rawValue }, by: { $0 }).mapValues(\.count)
        note("myResponse \(responses.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        note("offsetMinutes=\(TimeZone.current.secondsFromGMT() / 60)")

        if env["CALENDAR_LIVE_WRITE"] == "1" {
            let now = Date()
            let created = try g.create(subject: "test", start: now, end: now.addingTimeInterval(1800), online: true)
            note("created id=\(created.meetingId) join=\(created.joinURL != nil) attendees=\(created.info?.people.count ?? -1)")
            note("created localStartMatchesNow=\(abs((CalendarTime.instant(created.start, zone: TimeZone.current.identifier) ?? .distantPast).timeIntervalSince(now)) < 60)")
            var deleted = false
            defer { note("deleted: \(deleted ? "yes" : "NO — delete id above by hand")") }
            let moved = try g.update(id: created.meetingId, patch: CalendarEventPatch(
                start: CalWeek.graphDateTime(now.addingTimeInterval(1800)),
                end: CalWeek.graphDateTime(now.addingTimeInterval(3600))))
            note("edited subjectKept=\(moved.subject == "test") startMoved=\(moved.start != created.start)")
            try g.delete(id: created.meetingId)
            let gone = (try? g.detail(id: created.meetingId)) == nil
            deleted = gone
            note("deleteConfirmed=\(gone)")
        }
    }
}
