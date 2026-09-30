// CalendarGridGuardTests — CALGRID guards for the day/week grid's layout math:
// a block is proportional to its duration (15 / 30 / 60 minutes) and stays
// inside its own slot, and 2 to 4 overlapping meetings split the column into
// equal, non-overlapping lanes (Calendar.app style). Pure math, no windows.
import CoreGraphics
import XCTest

@testable import BetterTeamsUI

final class CalendarGridGuardTests: XCTestCase {
    private let mh = WeekGrid.hourHeight / 60

    private func height(_ minutes: Int) -> CGFloat {
        WeekGridMath.vertical(start: 600, end: 600 + minutes, minuteHeight: mh).height
    }

    func testBlockHeightIsProportionalTo15And30And60Minutes() {
        let h15 = height(15), h30 = height(30), h60 = height(60)
        XCTAssertEqual(h15, 15 * mh - WeekGridMath.gap, accuracy: 0.001)
        XCTAssertEqual(h30, 30 * mh - WeekGridMath.gap, accuracy: 0.001)
        XCTAssertEqual(h60, 60 * mh - WeekGridMath.gap, accuracy: 0.001)
        // Doubling the duration adds exactly that duration's height.
        XCTAssertEqual(h30 - h15, 15 * mh, accuracy: 0.001)
        XCTAssertEqual(h60 - h30, 30 * mh, accuracy: 0.001)
        // Old floor was 18 pt for a 15-minute block (taller than its slot).
        XCTAssertLessThan(h15, 15 * mh)
        XCTAssertGreaterThanOrEqual(h15, WeekGridMath.minimumHeight(scale: 1))
    }

    func testABlockNeverSpillsPastItsSlot() {
        for minutes in [15, 30, 45, 60, 90, 120] {
            let v = WeekGridMath.vertical(start: 600, end: 600 + minutes, minuteHeight: mh)
            XCTAssertLessThanOrEqual(v.y + v.height, CGFloat(600 + minutes) * mh, "\(minutes) min")
            XCTAssertGreaterThanOrEqual(v.y, 600 * mh)
        }
    }

    func testMeetingsShorterThan15MinutesFillOneSlotAndStackWithoutOverlap() {
        XCTAssertEqual(height(5), height(15))
        XCTAssertEqual(WeekGridMath.visualSpan(start: 600, end: 605).end, 615)
        // Two 5-minute meetings 5 minutes apart do not share a lane's pixels.
        let slots = WeekGridLanes.assign([WeekGridMath.visualSpan(start: 600, end: 605),
                                          WeekGridMath.visualSpan(start: 605, end: 610)].map { ($0.start, $0.end) })
        XCTAssertNotEqual(slots[0].lane, slots[1].lane)
    }

    func testTextScaleGrowsTheMinimumHeightNotBelow13() {
        XCTAssertEqual(WeekGridMath.minimumHeight(scale: 1), 13)
        XCTAssertGreaterThan(WeekGridMath.minimumHeight(scale: 1.5), 13)
        XCTAssertEqual(WeekGridMath.vertical(start: 0, end: 15, minuteHeight: mh, minimumHeight: 19).height, 19)
    }

    func testOverlappingMeetingsSplitTheColumnIntoEqualLanes() {
        for n in 2...4 {
            let slots = WeekGridLanes.assign(Array(repeating: (600, 660), count: n))
            XCTAssertEqual(Set(slots.map(\.lane)).count, n)
            XCTAssertTrue(slots.allSatisfy { $0.lanes == n && $0.span == 1 })
            let width: CGFloat = 200
            let frames = slots.map { WeekGridMath.horizontal(lane: $0.lane, lanes: $0.lanes, span: $0.span, width: width) }
                .sorted { $0.x < $1.x }
            let expected = (width - CGFloat(n + 1) * WeekGridMath.laneGap) / CGFloat(n)
            for f in frames { XCTAssertEqual(f.width, expected, accuracy: 0.001, "\(n) lanes") }
            for (a, b) in zip(frames, frames.dropFirst()) { XCTAssertLessThanOrEqual(a.x + a.width, b.x, "\(n) lanes overlap") }
            XCTAssertEqual(frames.last!.x + frames.last!.width, width - WeekGridMath.laneGap, accuracy: 0.001)
        }
    }

    func testAMeetingWidensOverFreeLanesToItsRight() {
        // Roadmap 10:00-11:30 has two shorter meetings on top of it in the
        // middle; the 11:00 one after them is alone again and takes the
        // width the earlier lanes freed.
        let s = WeekGridLanes.assign([(600, 690), (630, 660), (645, 660), (660, 675)])
        XCTAssertEqual(s.map(\.lanes), [3, 3, 3, 3])
        XCTAssertEqual(s.map(\.lane), [0, 1, 2, 1])
        XCTAssertEqual(s[3].span, 2, "11:00 meeting: lane 2 is free then")
        XCTAssertEqual(s[0].span, 1, "the long meeting is blocked by lanes 1 and 2")
        let f = WeekGridMath.horizontal(lane: 1, lanes: 3, span: 2, width: 200)
        let last = WeekGridMath.horizontal(lane: 2, lanes: 3, width: 200)
        XCTAssertEqual(f.x + f.width, last.x + last.width, accuracy: 0.001)
    }

    func testSeparateMeetingsKeepTheFullWidth() {
        let s = WeekGridLanes.assign([(540, 570), (600, 660)])
        XCTAssertEqual(s, [.init(lane: 0, lanes: 1, span: 1), .init(lane: 0, lanes: 1, span: 1)])
        XCTAssertEqual(WeekGridMath.horizontal(lane: 0, lanes: 1, width: 100).width, 100 - 2 * WeekGridMath.laneGap)
    }

    /// The view uses the pure math (not its own floor) and shows the full
    /// title on hover.
    func testGridViewUsesTheMathAndHasATooltip() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/BetterTeamsUI/Sections/Calendar/CalendarWeekGrid.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("WeekGridMath.vertical"), "layout must use WeekGridMath")
        XCTAssertTrue(text.contains("WeekGridMath.horizontal"))
        XCTAssertFalse(text.contains("max(18,"), "the old 18 pt floor made 15-minute blocks too tall")
        XCTAssertTrue(text.contains(".help("), "a truncated title needs a hover tooltip")
    }
}
