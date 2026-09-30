// CalTeamsTests.swift — CALTEAMS lane pins (UI-SPEC §5.1, §6.3, §6.4):
// the inspector fit is decided at its minimum width and it opens without
// widening a 1060 pt window; New Meeting starts on the exact half hour;
// Join with ID builds the Teams join link from a meeting ID + passcode.
import AppKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class CalTeamsTests: XCTestCase {
    private final class Blank: NSViewController {
        override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 600)) }
    }

    /// 1060 pt fits rail + list + detail + the 260 pt inspector minimum
    /// (1043), though not the inspector's 280 pt last width (1063): the
    /// thread inspector must open there, narrower, with the window as is.
    func testInspectorFitsAtMinimumAndOpensWithoutWideningWindow() {
        let split = ShellSplitViewController(rail: Blank())
        let window = OffscreenWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.contentViewController = split
        window.setFrame(NSRect(x: 0, y: 0, width: 1060, height: 700), display: false)
        window.layoutIfNeeded()
        XCTAssertTrue(split.inspectorItem.isCollapsed)
        XCTAssertEqual(split.widthNeededForInspector,
                       80 + 260 + 440 + 260 + 3 * split.splitView.dividerThickness)
        XCTAssertTrue(split.inspectorFits(in: window))

        split.expandInspector(in: window)
        window.layoutIfNeeded()
        XCTAssertFalse(split.inspectorItem.isCollapsed)
        XCTAssertEqual(window.frame.width, 1060, "opening a fitting inspector never widens the window")
        let w = split.inspectorPane.view.frame.width
        XCTAssertGreaterThanOrEqual(w, 260)
        XCTAssertEqual(split.inspectorItem.maximumThickness, 360, "cap restored after the expanding pass")
    }

    /// Seconds never push the default start a minute late (10:01).
    func testNewMeetingStartsOnTheHalfHour() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int, _ m: Int, _ s: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: h, minute: m, second: s))!
        }
        XCTAssertEqual(NewMeetingSheet.nextHalfHour(at(22, 0, 37), calendar: cal), at(22, 30, 0))
        XCTAssertEqual(NewMeetingSheet.nextHalfHour(at(21, 44, 59), calendar: cal), at(22, 0, 0))
        XCTAssertEqual(NewMeetingSheet.nextHalfHour(at(9, 30, 0), calendar: cal), at(10, 0, 0))
        XCTAssertEqual(NewMeetingSheet.nextHalfHour(at(9, 29, 1), calendar: cal), at(9, 30, 0))
    }

    /// Meeting ID (spaces allowed) + passcode → the Teams meet link the
    /// existing join path parses; missing or malformed input → nil.
    func testJoinWithMeetingIDBuildsMeetLink() {
        XCTAssertEqual(JoinMeetingSheet.meetURL(id: "123 456 789 012", passcode: " aB3xY9 "),
                       "https://teams.microsoft.com/meet/123456789012?p=aB3xY9")
        XCTAssertEqual(JoinMeetingSheet.meetURL(id: "123456789", passcode: "a&b"),
                       "https://teams.microsoft.com/meet/123456789?p=a%26b")
        XCTAssertNil(JoinMeetingSheet.meetURL(id: "123 456 789 012", passcode: "  "))
        XCTAssertNil(JoinMeetingSheet.meetURL(id: "12345", passcode: "x"))
        XCTAssertNil(JoinMeetingSheet.meetURL(id: "12345abc9012", passcode: "x"))
    }
}
