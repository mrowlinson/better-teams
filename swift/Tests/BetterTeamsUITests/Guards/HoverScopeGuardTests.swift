// Guards: the reaction hover menu arms ONLY from the message bubble.
// The bubble reports pointer via `MessageHover.pointer` (dwell to show,
// grace to hide); the toolbar itself reports via `MessageHover.bar`
// (keep-alive while the pointer travels onto it — it NEVER arms the menu).
// Row whitespace reports nothing, so hovering it never shows the menu.
import XCTest

@testable import BetterTeamsUI

@MainActor
final class HoverScopeGuardTests: XCTestCase {
    private func hover(_ clock: ManualHoverScheduler) -> MessageHover {
        MessageHover(scheduler: clock)
    }

    /// The toolbar alone never arms the menu (e.g. a stray bar-region
    /// event with no bubble hover shows nothing).
    func testBarHoverAloneNeverShowsTheMenu() {
        let clock = ManualHoverScheduler()
        let h = hover(clock)
        h.bar(true, id: "a")
        clock.fire()
        XCTAssertNil(h.shownID, "toolbar hover must never arm the menu")
        h.bar(false, id: "a")
        clock.fire()
        XCTAssertNil(h.shownID)
    }

    /// Control: the bubble dwell still arms the menu after scoping.
    func testBubbleDwellStillShowsTheMenu() {
        let clock = ManualHoverScheduler()
        let h = hover(clock)
        h.pointer(true, id: "a")
        XCTAssertNil(h.shownID)
        clock.fire()
        XCTAssertEqual(h.shownID, "a")
    }

    /// Bubble → gap → bar travel keeps the menu (the click path onto
    /// Reply/More must not fade the bar mid-travel).
    func testBubbleToBarTravelKeepsTheMenu() {
        let clock = ManualHoverScheduler()
        let h = hover(clock)
        h.pointer(true, id: "a")
        clock.fire()
        h.pointer(false, id: "a")
        h.bar(true, id: "a")
        clock.fire()
        XCTAssertEqual(h.shownID, "a", "travelling onto the toolbar must keep the menu")
    }

    /// Same travel with the two events reordered (one mouse-moved can
    /// deliver enter-before-leave): the menu still stays.
    func testReorderedTravelStillKeepsTheMenu() {
        let clock = ManualHoverScheduler()
        let h = hover(clock)
        h.pointer(true, id: "a")
        clock.fire()
        h.bar(true, id: "a")
        h.pointer(false, id: "a")
        clock.fire()
        XCTAssertEqual(h.shownID, "a")
    }

    /// Overlay placement: the bar sits over the bubble corner, so leaving
    /// the bar while still on the bubble must keep the menu.
    func testBarLeaveWhileOnBubbleKeepsTheMenu() {
        let clock = ManualHoverScheduler()
        let h = hover(clock)
        h.pointer(true, id: "a")
        clock.fire()
        h.bar(true, id: "a")
        h.bar(false, id: "a")
        clock.fire()
        XCTAssertEqual(h.shownID, "a")
    }

    /// Leaving both regions hides after the grace (whitespace ends it).
    func testLeavingBothRegionsHidesAfterGrace() {
        let clock = ManualHoverScheduler()
        let h = hover(clock)
        h.pointer(true, id: "a")
        clock.fire()
        h.pointer(false, id: "a")
        h.bar(true, id: "a")
        h.bar(false, id: "a")
        XCTAssertEqual(h.shownID, "a", "still up during the grace")
        clock.fire()
        XCTAssertNil(h.shownID)
    }

    /// Bubble leave with the bar never involved still hides (existing contract).
    func testBubbleLeaveAloneHidesAfterGrace() {
        let clock = ManualHoverScheduler()
        let h = hover(clock)
        h.pointer(true, id: "a")
        clock.fire()
        h.pointer(false, id: "a")
        clock.fire()
        XCTAssertNil(h.shownID)
    }

    /// Stale region events for other messages never disturb the shown one.
    func testStaleRegionEventsForOtherIDsAreIgnored() {
        let clock = ManualHoverScheduler()
        let h = hover(clock)
        h.pointer(true, id: "a")
        clock.fire()
        h.bar(false, id: "b")
        h.pointer(false, id: "b")
        clock.fire()
        XCTAssertEqual(h.shownID, "a")
    }
}
