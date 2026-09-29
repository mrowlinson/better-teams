// MentionHoverTests.swift — hover cards on @mentions in message text
// (character hit test on the mention run, pointer transitions into the
// shared 1 s dwell coordinator) and the card's calendar-backed lines.
import AppKit
import OstMacCore
import SwiftUI
import XCTest

@testable import BetterTeamsUI

@MainActor
final class MentionHoverTests: XCTestCase {
    /// "Thanks @Megan Harper for the notes" styled the way message rows style it.
    private func body() -> AttributedString {
        var s = AttributedString("Thanks ")
        var m = AttributedString("@Megan Harper")
        m[MessageTextAttributes.MentionAttribute.self] = .other
        s.append(m)
        s.append(AttributedString(" for the notes"))
        return MessageRowView.segments(s, scale: 1)[0].text
    }

    private func mentionRect(_ layout: MentionLayout) -> CGRect {
        let text = layout.storage.string as NSString
        let r = text.range(of: "Megan")
        // Walk right from the leading edge until the hit lands on the mention.
        for x in stride(from: CGFloat(0), to: layout.width, by: 2) {
            if let hit = layout.hit(at: CGPoint(x: x, y: 8)), hit.range.location <= r.location { return hit.rect }
        }
        return .null
    }

    func testHitTestFindsMentionRunOnly() throws {
        let text = MentionLayout.attributed(body(), scale: 1)
        XCTAssertTrue(MentionLayout.hasMention(body()))
        XCTAssertFalse(MentionLayout.hasMention(AttributedString("no people here")))
        let layout = MentionLayout(text: text, width: 600)
        let rect = mentionRect(layout)
        XCTAssertFalse(rect.isNull, "the mention run is hit somewhere on the first line")
        let hit = layout.hit(at: CGPoint(x: rect.midX, y: rect.midY))
        XCTAssertEqual(hit?.name, "Megan Harper")
        XCTAssertEqual(hit?.range.length, ("@Megan Harper" as NSString).length)
        XCTAssertNil(layout.hit(at: CGPoint(x: 2, y: rect.midY)), "plain text before the mention")
        XCTAssertNil(layout.hit(at: CGPoint(x: 590, y: rect.midY)), "blank space past the line's end")
        XCTAssertNil(layout.hit(at: CGPoint(x: rect.midX, y: 400)), "below the last line")
        // Body font applied where the segment has none (layout matches the Text).
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, AppFont.nsBody(1).pointSize)
    }

    func testPointerTransitionsDriveTheDwellCoordinator() {
        let clock = ManualHoverScheduler()
        let hover = ContactHover(scheduler: clock)
        let view = MentionTrackingView(frame: CGRect(x: 0, y: 0, width: 600, height: 40))
        view.text = MentionLayout.attributed(body(), scale: 1)
        XCTAssertNil(view.hitTest(CGPoint(x: 10, y: 10)), "never takes clicks or selection from the text")
        var events: [String] = []
        view.onChange = { left, entered in
            if let left { events.append("out:\(left.name)"); hover.pointer(false, anchor: "m\(left.range.location)") }
            if let entered { events.append("in:\(entered.name)"); hover.pointer(true, anchor: "m\(entered.range.location)") }
        }
        let rect = mentionRect(MentionLayout(text: view.text, width: 600))
        view.pointer(at: CGPoint(x: 2, y: rect.midY))           // plain text: nothing
        view.pointer(at: CGPoint(x: rect.minX + 2, y: rect.midY))
        view.pointer(at: CGPoint(x: rect.maxX - 2, y: rect.midY)) // same run: no new event
        XCTAssertEqual(events, ["in:Megan Harper"])
        XCTAssertEqual(clock.delay, ContactHoverTiming.showDelay, "same 1 s dwell as names")
        let anchor = "m\(view.current?.range.location ?? -1)"
        XCTAssertFalse(hover.isShown(anchor))
        clock.fire()
        XCTAssertTrue(hover.isShown(anchor))
        view.pointer(at: CGPoint(x: 590, y: rect.midY))          // off the mention
        XCTAssertEqual(events, ["in:Megan Harper", "out:Megan Harper"])
        XCTAssertEqual(clock.delay, ContactHoverTiming.hideGrace, "grace to reach the card")
        hover.card(true)
        XCTAssertTrue(hover.isShown(anchor), "card stays while the pointer is on it")
        view.pointer(at: nil)
        XCTAssertEqual(events.count, 2, "already off the mention")
    }

    // MARK: card links

    func testContactLinksAndOrgChartTab() {
        XCTAssertEqual(ContactActions.telURL("+1 (555) 010-2000")?.absoluteString, "tel:+15550102000")
        XCTAssertEqual(ContactActions.telURL("0161 496 0000")?.absoluteString, "tel:01614960000")
        XCTAssertNil(ContactActions.telURL("ext."))
        let ref = ContactRef(name: "Tom Becker", userID: "u1", email: "tom@example.com")
        let arg = ContactActions.sheetArg(ref, tab: .organization)
        XCTAssertEqual(ContactRef(encoded: arg), ref, "the tab field doesn't disturb the ref")
        XCTAssertEqual(ContactCardSheet.tab(fromArg: arg), .organization, "org-chart icon opens Organization")
        XCTAssertEqual(ContactCardSheet.tab(fromArg: ContactActions.sheetArg(ref, tab: .overview)), .overview)
        XCTAssertEqual(ContactCardSheet.tab(fromArg: "Tom Becker"), .overview)
    }

    /// The hover card sizes to its content and scrolls past the cap.
    @MainActor
    func testCappedScrollSizesToContentUpToCap() {
        func height(_ content: CGFloat) -> CGFloat {
            NSHostingView(rootView: CappedScroll(maxHeight: 480) { Color.clear.frame(width: 320, height: content) })
                .fittingSize.height
        }
        XCTAssertEqual(height(300), 300, accuracy: 1, "short card: no blank space")
        XCTAssertEqual(height(900), 480, accuracy: 1, "tall card: capped, scrolls")
    }

    // MARK: card lines

    func testAvailabilityAndWorkingHoursLines() {
        let utc = TimeZone(identifier: "UTC")!
        let until = ISO8601DateFormatter().date(from: "2026-09-28T16:00:00Z")!
        var card = ContactCard(profile: ContactProfile(id: "u1", displayName: "Tom Becker"))
        XCTAssertNil(ContactActions.availability(for: card))
        card.schedule = ContactSchedule(timeZoneID: "Europe/Berlin", workStart: "09:00:00", workEnd: "17:30:00",
                                        state: .busy, until: until)
        XCTAssertEqual(ContactActions.availability(for: card, zone: utc), "Free at " + ContactActions.clock(until, in: utc),
                       "busy until 16:00 reads as Teams' \"Free at\"")
        let presence = ContactPresence(availability: "Busy", activity: "InACall")
        XCTAssertEqual(ContactActions.statusLine(presence: presence, card: card),
                       presence.label + " • Free at " + ContactActions.clock(until, in: .current))
        card.schedule?.state = .free
        card.schedule?.until = nil
        XCTAssertEqual(ContactActions.availability(for: card, zone: utc), "Free all day")
        let hours = ContactActions.workingHours(for: card)
        XCTAssertTrue(hours?.contains(" - ") == true, hours ?? "nil")
        let berlin = ContactActions.localTime(for: card, now: until, viewer: utc)
        XCTAssertTrue(berlin?.hasSuffix(" - 2 hr ahead of you") == true, berlin ?? "nil")
        let same = ContactActions.localTime(for: card, now: until, viewer: TimeZone(identifier: "Europe/Berlin")!)
        XCTAssertTrue(same?.hasSuffix(" - Same time zone as you") == true, same ?? "nil")
        XCTAssertTrue(ContactActions.localTime(for: card, now: until, viewer: TimeZone(identifier: "Asia/Tokyo")!)?
            .hasSuffix(" - 7 hr behind you") == true, "zone from the calendar, not only demo people")
        XCTAssertEqual(ContactCardSheet.tabs(for: card).map(\.rawValue), ["Overview", "Profile", "Organization", "LinkedIn"],
                       "Profile shows without about fields (live tenants return them unset); org still loading")
        card.orgLoaded = true
        XCTAssertEqual(ContactCardSheet.tabs(for: card).map(\.rawValue), ["Overview", "Profile", "LinkedIn"],
                       "empty org hidden")
        XCTAssertEqual(ContactActions.fileSymbol("Excel"), "tablecells")
        XCTAssertEqual(ContactActions.fileSymbol(nil), "doc")
    }
}
