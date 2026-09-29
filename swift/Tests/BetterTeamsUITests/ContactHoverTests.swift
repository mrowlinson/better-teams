// ContactHoverTests.swift — contact hover card timing (1 s dwell, warm
// switch, grace into the card, scroll cancel), evidence pin, mention
// links and which names get a card.
import OstMacCore
import XCTest

@testable import BetterTeamsUI

@MainActor
final class ContactHoverTests: XCTestCase {
    func testShowsAfterDwellAndNotBefore() {
        let clock = ManualHoverScheduler()
        let hover = ContactHover(scheduler: clock)
        hover.pointer(true, anchor: "a")
        XCTAssertEqual(clock.delay, ContactHoverTiming.showDelay)
        XCTAssertEqual(ContactHoverTiming.showDelay, 1000)
        XCTAssertFalse(hover.isShown("a"))
        clock.fire()
        XCTAssertTrue(hover.isShown("a"))
    }

    func testLeavingBeforeDwellCancels() {
        let clock = ManualHoverScheduler()
        let hover = ContactHover(scheduler: clock)
        hover.pointer(true, anchor: "a")
        hover.pointer(false, anchor: "a")
        XCTAssertNil(clock.delay)
        XCTAssertFalse(hover.isShown("a"))
    }

    func testGraceLetsPointerMoveIntoCard() {
        let clock = ManualHoverScheduler()
        let hover = ContactHover(scheduler: clock)
        hover.pointer(true, anchor: "a"); clock.fire()
        hover.pointer(false, anchor: "a")
        XCTAssertEqual(clock.delay, ContactHoverTiming.hideGrace)
        hover.card(true)                     // crossed into the card in time
        XCTAssertNil(clock.delay)
        XCTAssertTrue(hover.isShown("a"))
        hover.card(false)                    // left the card too
        XCTAssertEqual(clock.delay, ContactHoverTiming.hideGrace)
        clock.fire()
        XCTAssertFalse(hover.isShown("a"))
    }

    func testWarmSwitchAndScrollCancel() {
        let clock = ManualHoverScheduler()
        let hover = ContactHover(scheduler: clock)
        hover.pointer(true, anchor: "a"); clock.fire()
        hover.pointer(false, anchor: "a")
        hover.pointer(true, anchor: "b")
        XCTAssertEqual(clock.delay, ContactHoverTiming.warmDelay)
        clock.fire()
        XCTAssertTrue(hover.isShown("b"))
        hover.scrolled()
        XCTAssertFalse(hover.isShown("b"))
        XCTAssertNil(clock.delay, "scroll drops the pending dwell too")
    }

    func testEvidencePinClaimsFirstMatchingAnchor() {
        let hover = ContactHover(scheduler: ManualHoverScheduler())
        hover.pinnedName = "Tom Becker"
        hover.claimPin(anchor: "x", name: "Ava Lindqvist")
        hover.claimPin(anchor: "y", name: "tom becker")
        hover.claimPin(anchor: "z", name: "Tom Becker")
        XCTAssertTrue(hover.isShown("y"))
        XCTAssertFalse(hover.isShown("z"))
        hover.dismiss()
        XCTAssertFalse(hover.isShown("y"))
    }

    func testMentionLinkRoundTripsAndRules() throws {
        let url = try XCTUnwrap(ContactLinks.url(name: "@Megan Harper"))
        XCTAssertEqual(ContactLinks.name(from: url), "Megan Harper")
        XCTAssertNil(ContactLinks.name(from: URL(string: "https://example.com")!))
        XCTAssertTrue(ContactHoverRules.isPerson("Tom Becker"))
        XCTAssertFalse(ContactHoverRules.isPerson("Build Bot"))
        XCTAssertFalse(ContactHoverRules.isPerson("?"))
        XCTAssertFalse(ContactHoverRules.isPerson(""))
    }

    /// New Chat picker (directory hits and To: tokens) hovers with the
    /// hit's id + email, and lands on the same card as a sender name.
    func testNewChatPickerRefMatchesSenderCard() {
        let hit = TeamMember(id: "row-1", displayName: "Tom Becker", userId: "u-tom", email: "tom@example.com")
        let ref = ContactRef(hit)
        XCTAssertEqual(ref.userID, "u-tom")
        XCTAssertEqual(ref.email, "tom@example.com")
        let dir = ContactDirectory()
        dir.learn([hit])
        XCTAssertEqual(dir.enrich(ContactRef(name: "Tom Becker")).key, ref.key)
    }

    func testPopoverClampKeepsCardInsideWindow() {
        let win = CGRect(x: 100, y: 100, width: 1000, height: 700)
        // Hangs off the bottom-left: pulled back inside with the 6 pt margin.
        let low = PopoverClamp.clamped(CGRect(x: 75, y: -80, width: 320, height: 500), in: win)
        XCTAssertEqual(low.minX, 106)
        XCTAssertEqual(low.minY, 106)
        // Already inside: untouched.
        let ok = CGRect(x: 300, y: 200, width: 320, height: 400)
        XCTAssertEqual(PopoverClamp.clamped(ok, in: win), ok)
        // Off the right and top.
        let hi = PopoverClamp.clamped(CGRect(x: 1000, y: 600, width: 320, height: 400), in: win)
        XCTAssertEqual(hi.maxX, 1094)
        XCTAssertEqual(hi.maxY, 794)
        // Taller than the window: top-aligned.
        let tall = PopoverClamp.clamped(CGRect(x: 300, y: 0, width: 320, height: 900), in: win)
        XCTAssertEqual(tall.maxY, 794)
    }
}
