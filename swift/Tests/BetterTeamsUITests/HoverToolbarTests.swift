// HoverToolbarTests.swift — hover toolbar timing (dwell, grace, warm
// switch, scroll) on a hand-stepped clock, and lane placement: the bar
// never overlaps the header or the bubble (HOVER).
import XCTest

@testable import BetterTeamsUI

/// Test clock: holds the one pending job; `fire()` runs it as if its
/// delay had elapsed.
@MainActor
final class ManualHoverScheduler: HoverScheduler {
    private(set) var delay: UInt64?
    private var work: (@MainActor () -> Void)?

    func schedule(after milliseconds: UInt64, _ work: @escaping @MainActor () -> Void) {
        delay = milliseconds
        self.work = work
    }

    func cancel() {
        delay = nil
        work = nil
    }

    func fire() {
        let w = work
        cancel()
        w?()
    }
}

@MainActor
final class HoverToolbarTests: XCTestCase {
    // MARK: timing

    func testShowsOnlyAfterDwellAndLeavingFirstCancels() {
        let clock = ManualHoverScheduler()
        let h = MessageHover(scheduler: clock)
        h.pointer(true, id: "a")
        XCTAssertNil(h.shownID)                        // not instant
        XCTAssertEqual(clock.delay, HoverTiming.showDelay)
        h.pointer(false, id: "a")                      // left before the dwell
        XCTAssertNil(clock.delay)
        clock.fire()
        XCTAssertNil(h.shownID)
        h.pointer(true, id: "a")
        clock.fire()
        XCTAssertEqual(h.shownID, "a")
    }

    func testGraceKeepsBarWhenPointerComesBack() {
        let clock = ManualHoverScheduler()
        let h = MessageHover(scheduler: clock)
        h.pointer(true, id: "a")
        clock.fire()
        h.pointer(false, id: "a")
        XCTAssertEqual(h.shownID, "a")                 // still up during grace
        XCTAssertEqual(clock.delay, HoverTiming.hideGrace)
        h.pointer(true, id: "a")                       // back in time
        XCTAssertNil(clock.delay)
        XCTAssertEqual(h.shownID, "a")
        h.pointer(false, id: "a")
        clock.fire()
        XCTAssertNil(h.shownID)
    }

    func testWarmSwitchUsesShortDwellAndKeepsOldBarMeanwhile() {
        let clock = ManualHoverScheduler()
        let h = MessageHover(scheduler: clock)
        h.pointer(true, id: "a")
        clock.fire()
        h.pointer(false, id: "a")
        h.pointer(true, id: "b")
        XCTAssertEqual(h.shownID, "a")                 // no blank gap
        XCTAssertEqual(clock.delay, HoverTiming.warmDelay)
        XCTAssertLessThan(HoverTiming.warmDelay, HoverTiming.showDelay)
        clock.fire()
        XCTAssertEqual(h.shownID, "b")
    }

    func testScrollHidesAndRearmsFullDwell() {
        let clock = ManualHoverScheduler()
        let h = MessageHover(scheduler: clock)
        h.pointer(true, id: "a")
        clock.fire()
        h.scrolled()
        XCTAssertNil(h.shownID)
        XCTAssertEqual(clock.delay, HoverTiming.showDelay)
        h.scrolled()                                   // still scrolling: re-armed
        XCTAssertNil(h.shownID)
        clock.fire()
        XCTAssertEqual(h.shownID, "a")
        h.pointer(false, id: "a")
        clock.fire()
        h.scrolled()                                   // pointer outside: nothing pending
        XCTAssertNil(clock.delay)
    }

    // MARK: placement

    private let tb = HoverToolbarRules.size(scale: 1)
    private let header = CGSize(width: 150, height: 17)

    private func plan(_ width: CGFloat, card: CGSize, header: CGSize? = nil, own: Bool,
                      topPadding: CGFloat = 2) -> LanePlan {
        LanePlan.make(width: width, header: header, card: card, toolbar: tb, ownTrailing: own,
                      slack: own ? MessageRowView.ownGutter : MessageRowView.otherGutter, topPadding: topPadding)
    }

    private func assertClear(_ p: LanePlan, file: StaticString = #filePath, line: UInt = #line) {
        guard let t = p.toolbar else { return XCTFail("no toolbar", file: file, line: line) }
        XCTAssertFalse(t.intersects(p.card), "covers bubble", file: file, line: line)
        if let h = p.header { XCTAssertFalse(t.intersects(h), "covers header", file: file, line: line) }
    }

    func testToolbarSizeIsItsItemFrames() {
        XCTAssertEqual(tb, CGSize(width: 24 * 9 + 5 + 12, height: 26))
    }

    func testShortBubbleGetsBarBesideOnFreeSide() {
        let others = plan(600, card: CGSize(width: 80, height: 33), header: header, own: false, topPadding: 8)
        XCTAssertEqual(others.placement, .side)
        XCTAssertGreaterThan(others.toolbar!.minX, others.card.maxX)
        XCTAssertEqual(others.toolbar!.minY, others.card.minY)
        assertClear(others)
        let own = plan(600, card: CGSize(width: 80, height: 33), own: true)
        XCTAssertEqual(own.placement, .side)
        XCTAssertLessThan(own.toolbar!.maxX, own.card.minX)
        XCTAssertEqual(own.size.height, 33)            // no reserved space
        assertClear(own)
    }

    func testWideBubbleWithHeaderUsesHeaderLine() {
        for own in [false, true] {
            let p = plan(600, card: CGSize(width: 600, height: 60), header: header, own: own, topPadding: 8)
            XCTAssertEqual(p.placement, .header)
            XCTAssertLessThanOrEqual(p.toolbar!.maxY, p.card.minY)
            XCTAssertGreaterThanOrEqual(p.toolbar!.minY, -8)   // inside its own row
            assertClear(p)
        }
    }

    func testWideContinuationReservesStripInsideItsRow() {
        for own in [false, true] {
            let p = plan(600, card: CGSize(width: 600, height: 60), own: own)
            XCTAssertEqual(p.placement, .strip)
            XCTAssertGreaterThanOrEqual(p.toolbar!.minY, -2)   // 2 pt row padding
            XCTAssertEqual(p.size.height, 60 + tb.height + 1 - 2)
            assertClear(p)
        }
    }

    func testNarrowWindowStillNeverOverlaps() {
        let p = plan(180, card: CGSize(width: 180, height: 90), header: header, own: false, topPadding: 8)
        XCTAssertEqual(p.placement, .strip)
        assertClear(p)
    }
}
