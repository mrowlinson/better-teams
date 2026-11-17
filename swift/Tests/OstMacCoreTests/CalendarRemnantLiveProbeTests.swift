// CalendarRemnantLiveProbeTests.swift — CAL-REMNANT (C4) opt-in live
// proof (CALREM_LIVE=1). Read-only first: /me, /me/calendars, week
// calendarView (counts only). With CALREM_LIVE_WRITE=1 also ONE solo
// meeting (subject LiveTest.subject, attendees NONE): create, set the
// event-level options, read back, DELETE. Prints counts and booleans
// only — never subjects, names, addresses, tokens or URLs.
import Foundation
import XCTest

@testable import OstMacCore

/// Lane test-meeting subject (owner 11-13: test meetings identify
/// themselves; attendees NONE for this lane: self-only).
enum LiveTest {
    static let subject = "test (BetterTeams lane)"
}

final class CalendarRemnantLiveProbeTests: XCTestCase {
    private static func note(_ s: String, _ log: inout [String]) {
        print("PROBE \(s)")
        log.append(s)
    }

    func testLiveRemnantReadOnly() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CALREM_LIVE"] == "1" else {
            throw XCTSkip("set CALREM_LIVE=1 to run the live remnant probe")
        }
        var log: [String] = []
        defer {
            if let path = env["CALREM_LIVE_LOG"] {
                try? (log.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        let g = CalendarGraph.production()
        let me = try g.selfAddresses()
        Self.note("selfAddresses=\(me.count)", &log)
        let feeds = try g.calendars()
        Self.note("calendars=\(feeds.count) default=\(feeds.filter(\.isDefault).count)", &log)
        let from = Calendar.current.startOfDay(for: CalWeek.startOfWeek(containing: Date()))
        let rows = try g.range(from: from, to: from.addingTimeInterval(7 * 86_400))
        Self.note("weekRows=\(rows.count)", &log)
        if let second = feeds.first(where: { !$0.isDefault }) {
            let over = try g.calendarRange(id: second.id, from: from, to: from.addingTimeInterval(7 * 86_400))
            Self.note("overlayRows=\(over.count) secondCalendar=yes", &log)
        } else {
            Self.note("overlayRows=n/a secondCalendar=no", &log)
        }
    }

    func testLiveRemnantWrite() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CALREM_LIVE"] == "1", env["CALREM_LIVE_WRITE"] == "1" else {
            throw XCTSkip("set CALREM_LIVE=1 and CALREM_LIVE_WRITE=1 for the one-meeting write probe")
        }
        var log: [String] = []
        defer {
            if let path = env["CALREM_LIVE_LOG"] {
                try? (log.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        let g = CalendarGraph.production()
        let now = Date()
        let created = try g.create(subject: LiveTest.subject, start: now.addingTimeInterval(3600),
                                   end: now.addingTimeInterval(5400), online: true)
        Self.note("created join=\(created.joinURL != nil) attendees=\(created.info?.people.count ?? -1)", &log)
        var deleted = false
        defer { Self.note("deleted=\(deleted ? "yes" : "NO-delete-by-hand")", &log) }
        do {
            let patched = try g.update(id: created.meetingId, patch: CalendarEventPatch(
                responseRequested: false, hideAttendees: true))
            let reread = try g.detail(id: created.meetingId)
            Self.note("optionsReadBack="
                + "hide=\(reread.event.info?.hideAttendees.map(String.init(describing:)) ?? "nil")"
                + " respReq=\(reread.event.info?.responseRequested)"
                + " subjectKept=\(patched.subject == LiveTest.subject)", &log)
        }
        try g.delete(id: created.meetingId)
        deleted = (try? g.detail(id: created.meetingId)) == nil
    }
}
