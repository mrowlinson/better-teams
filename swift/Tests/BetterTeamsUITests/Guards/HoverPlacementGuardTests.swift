// Guards: hover-card placement never covers its own anchor (chat-list card
// near the window bottom), and the hide-on-scroll watcher ignores scroll
// views that are not in any window.
import XCTest
import AppKit
@testable import BetterTeamsUI

@MainActor
final class HoverPlacementGuardTests: XCTestCase {
    private let win = CGRect(x: 100, y: 100, width: 1000, height: 700)

    /// Chat-list avatar near the window bottom: AppKit put the 320x500 card
    /// beside/below it hanging off the bottom; the plain clamp pushed it up
    /// over the avatar. Placement must flip clear of the anchor instead.
    func testCardNearWindowBottomFlipsInsteadOfCoveringAnchor() {
        let anchor = CGRect(x: 120, y: 130, width: 36, height: 36)   // near bottom-left
        let card = CGRect(x: 100, y: -60, width: 320, height: 500)    // hangs off the bottom
        // Control: the old clamp does cover the anchor.
        let old = PopoverClamp.clamped(card, in: win)
        XCTAssertTrue(old.intersects(anchor), "control: plain clamp covers the anchor")
        let placed = PopoverPlacement.place(card, anchor: anchor, in: win)
        XCTAssertFalse(placed.intersects(anchor), "card must not cover its anchor")
        XCTAssertTrue(win.insetBy(dx: 6, dy: 6).contains(placed), "card stays inside the window")
    }

    func testFlipsToTheSideWhenNoRoomAboveOrBelow() {
        // Anchor mid-height; card nearly window-tall: only a side fits.
        let anchor = CGRect(x: 150, y: 400, width: 36, height: 36)
        let card = CGRect(x: 100, y: 60, width: 320, height: 680)
        let placed = PopoverPlacement.place(card, anchor: anchor, in: win)
        XCTAssertFalse(placed.intersects(anchor))
        XCTAssertGreaterThanOrEqual(placed.minX, anchor.maxX)
    }

    func testCardAlreadyClearIsUntouchedAndClampIsLastResort() {
        let anchor = CGRect(x: 120, y: 500, width: 36, height: 36)
        let ok = CGRect(x: 300, y: 200, width: 320, height: 400)
        XCTAssertEqual(PopoverPlacement.place(ok, anchor: anchor, in: win), ok)
        // Nothing fits (card fills the window): falls back to the clamp.
        let huge = CGRect(x: 100, y: 100, width: 1000, height: 700)
        XCTAssertEqual(PopoverPlacement.place(huge, anchor: anchor, in: win),
                       PopoverClamp.clamped(huge, in: win))
        XCTAssertEqual(PopoverPlacement.place(ok, anchor: nil, in: win), ok)
    }

    /// HOVERFIX rule 2: a clip view in no window is not a scroll under the
    /// anchor. Control: the same move in a window hides the card.
    func testScrollViewOutsideAnyWindowIsIgnoredByHideOnScroll() {
        let hover = ContactHover(observeScrolling: true)
        let spin = { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }

        let detached = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        detached.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 1000))
        XCTAssertNil(detached.contentView.window)
        hover.pointer(true, anchor: "a")
        XCTAssertEqual(hover.pointerAnchor, "a")
        detached.contentView.scroll(to: NSPoint(x: 0, y: 200))
        spin()
        XCTAssertEqual(hover.pointerAnchor, "a", "window-less scroll must not cancel the hover")

        let window = OffscreenWindow(contentRect: NSRect(x: -30000, y: -30000, width: 100, height: 100),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        let inWindow = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        inWindow.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 1000))
        window.contentView = inWindow
        inWindow.contentView.scroll(to: NSPoint(x: 0, y: 300))
        spin()
        XCTAssertNil(hover.pointerAnchor, "control: a scroll in a window cancels the hover")
    }
}
