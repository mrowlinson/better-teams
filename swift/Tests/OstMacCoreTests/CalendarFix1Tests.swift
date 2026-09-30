// CalendarFix1Tests.swift — webinar join-block strip keeps the body's own
// first paragraph; ranked scheduling suggestions stay in working hours.
import XCTest

@testable import OstMacCore

final class CalendarFix1Tests: XCTestCase {
    func testWebinarBodyKeepsFirstParagraphAndDropsJoinBlock() {
        let html = "<p>Microsoft Teams webinar: the product team walks through Q4.</p><p><b>Agenda</b></p>"
            + "<hr><h2>Microsoft Teams webinar</h2><p><b>Join on your computer, mobile app or room device</b></p>"
        let out = CalendarEventDraft.stripTeamsBlock(html)
        XCTAssertTrue(out.contains("the product team walks through Q4"))
        XCTAssertTrue(out.contains("Agenda"))
        XCTAssertFalse(out.contains("Join on your computer"))
        XCTAssertFalse(out.lowercased().contains("<h2>"))
        let hall = "<p>Company update.</p><hr><h2>Microsoft Teams town hall</h2><p>Join now</p>"
        XCTAssertEqual(CalendarEventDraft.stripTeamsBlock(hall), "<p>Company update.</p>")
        let plain = "The product team walks through Q4. Microsoft Teams webinar Join on your computer"
        XCTAssertEqual(CalendarEventDraft.stripTeamsBlock(plain), "The product team walks through Q4. ")
        let opening = "Microsoft Teams webinar: the product team walks through Q4."
        XCTAssertEqual(CalendarEventDraft.stripTeamsBlock(opening), opening)
    }

    func testMeetingBodyUnchanged() {
        let html = "<p>Sync</p><hr><h2>Microsoft Teams meeting</h2><p>Join</p>"
        XCTAssertEqual(CalendarEventDraft.stripTeamsBlock(html), "<p>Sync</p><hr><h2>")
        XCTAssertEqual(CalendarEventDraft.stripTeamsBlock("<p>No block</p>"), "<p>No block</p>")
    }

    func testRankedSuggestionsInHoursByConflicts() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day = cal.date(from: DateComponents(year: 2026, month: 9, day: 29))!
        func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: day)! }
        let people = [
            CalendarFreeBusy(email: "a@x", blocks: [.init(status: "busy", start: at(8), end: at(16, 30))]),
            CalendarFreeBusy(email: "b@x", blocks: [.init(status: "busy", start: at(8), end: at(12))]),
        ]
        let r = CalendarFreeBusy.rankedSuggestions(people, from: at(8), to: at(18), length: 5400, calendar: cal)
        XCTAssertEqual(r.count, 4)
        for s in r {
            XCTAssertGreaterThanOrEqual(cal.component(.hour, from: s.slot.start), 8)
            let e = cal.dateComponents([.hour, .minute], from: s.slot.end)
            XCTAssertLessThanOrEqual(e.hour! * 60 + e.minute!, 17 * 60, "ends by 5 PM")
        }
        // 1 conflict (a only) slots come first, earliest first: 12:00, 12:30, ...
        XCTAssertEqual(r[0].slot.start, at(12))
        XCTAssertEqual(r[0].conflicts, ["a@x"])
        XCTAssertEqual(r.map(\.conflicts.count), r.map(\.conflicts.count).sorted())
        let free = CalendarFreeBusy.rankedSuggestions([], from: at(8), to: at(18), length: 3600, calendar: cal)
        XCTAssertEqual(free.first?.conflicts, [])
        XCTAssertEqual(free.first?.slot.start, at(8))
    }
}
