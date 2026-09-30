// DemoShowTests.swift — DEMOSHOW: an Activity jump that lands before the
// timeline's first layout, and the evidence demo clock.
import AppKit
import XCTest
@testable import BetterTeamsUI
@testable import OstMacCore

@MainActor
final class DemoShowTests: XCTestCase {
    /// Activity ▸ mention: the seek lands in the store before the
    /// conversation pane exists, so the timeline gets its jump target
    /// while it has no viewport yet. The first real layout must show
    /// the target row, not the newest message.
    func testJumpBeforeFirstLayoutLandsOnTarget() {
        let conv = ConversationStore()
        let msgs = DemoData.messages(for: DemoData.showcaseID)
        conv.showDemo(chatID: DemoData.showcaseID, chatName: "Product Team", messages: msgs)
        conv.seek(messageID: "sc-1")
        XCTAssertEqual(conv.jumpTargetID, "sc-1", "control: demo seek lands in memory")

        let vc = TimelineViewController(conv: conv, model: nil)
        _ = vc.view // loaded with no size: the jump arrives before any geometry
        let window = OffscreenWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        window.contentViewController = vc // adopts the view's (zero) size
        window.setContentSize(NSSize(width: 640, height: 300)) // then the pane gets its size
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let visible = vc.visibleMessageIDs
        XCTAssertFalse(visible.isEmpty, "control: timeline laid out")
        XCTAssertFalse(visible.contains(msgs.last!.id), "control: thread overflows the viewport")
        XCTAssertTrue(visible.contains("sc-1"), "jump target not in view: \(visible)")
    }

    /// Evidence pins demo time to a weekday, 10:30 AM, so captures show
    /// daytime stamps; the Activity feed is full and stamped in the day.
    func testEvidenceClockIsWeekdayMorning() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let sunday = cal.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 1, minute: 45))!
        let pinned = DemoClock.evidenceMoment(for: sunday, calendar: cal)
        XCTAssertEqual(cal.component(.weekday, from: pinned), 6, "weekend pins to Friday")
        XCTAssertEqual(cal.dateComponents([.hour, .minute], from: pinned), DateComponents(hour: 10, minute: 30))
        let monday = cal.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 1, minute: 45))!
        XCTAssertTrue(cal.isDate(DemoClock.evidenceMoment(for: monday, calendar: cal), inSameDayAs: monday))

        // Demo threads stamp from DemoClock too: pin it like --evidence.
        XCTAssertEqual(DemoClock.pinForEvidence(realNow: sunday, calendar: cal), pinned)
        defer { DemoClock.unpin() }
        let store = ActivityStore.demo(DemoGate.launch(args: ["--demo"])!)
        XCTAssertGreaterThanOrEqual(store.items.count, 10)
        let today = store.items.map { Date(timeIntervalSince1970: TimeInterval($0.at)) }
            .filter { cal.isDate($0, inSameDayAs: pinned) }
        XCTAssertGreaterThanOrEqual(today.count, 2, "control: rows stamped on the pinned day")
        for d in today {
            XCTAssertTrue((7...10).contains(cal.component(.hour, from: d)) && d <= pinned, "\(d) not this morning")
        }
    }
}
