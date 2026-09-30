// ChatSurfaceGuardTests — R6/R7 (REGFIX-B): behavior lost in the 09-27
// rebuild, pinned so it cannot go silently again. SwiftUI draws its
// buttons without AppKit views or accessibility nodes under xctest, so
// these drive the logic each control is bound to (the same statics and
// stores the views call) and the AppKit chrome (image viewer) directly.
// Nothing is shown on screen.
import AppKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class ChatSurfaceGuardTests: XCTestCase {
    // MARK: R6 failed message: Retry on the bubble

    func testFailedBubbleRetryActionResendsInPlace() throws {
        let (_, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        let conv = ConversationStore()
        let failed = ChatMessage(id: "f1", sender: "Me", timestamp: "2026-09-29T10:00:00Z", content: "did not go", isOwn: true)
        conv.showDemo(chatID: "demo", chatName: "Demo", messages: [failed], failed: ["f1"])
        XCTAssertTrue(conv.failedIDs.contains("f1"))
        let actions = TimelineActions(conv: conv, model: model, services: ConversationServices.of(model))
        let retry = try XCTUnwrap(FailedSendStatus.retryAction(actions, failed), "a failed bubble must offer Retry")
        retry()
        XCTAssertFalse(conv.failedIDs.contains("f1"), "Retry must take the message out of the failed state")
        XCTAssertEqual(FailedSendStatus.text, "Message failed to send.")
        XCTAssertEqual(FailedSendStatus.retryTitle, "Retry")
        XCTAssertNil(FailedSendStatus.retryAction(nil, failed))
    }

    // MARK: R6 GIFs play/pause in chat

    func testGifClockPausesResumesAndLoops() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var c = GifPlaybackClock()
        XCTAssertFalse(c.playing)
        XCTAssertEqual(c.playhead(now: t0.addingTimeInterval(9), total: 1), 0, "paused GIF stays on its frame")
        c.play(now: t0)
        XCTAssertTrue(c.playing)
        XCTAssertEqual(c.playhead(now: t0.addingTimeInterval(0.5), total: 1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.playhead(now: t0.addingTimeInterval(2.25), total: 1), 0.25, accuracy: 1e-9, "loops")
        c.toggle(now: t0.addingTimeInterval(0.75), total: 1) // pause
        XCTAssertFalse(c.playing)
        XCTAssertEqual(c.playhead(now: t0.addingTimeInterval(50), total: 1), 0.75, accuracy: 1e-9, "frozen where paused")
        c.toggle(now: t0.addingTimeInterval(60), total: 1) // resume
        XCTAssertEqual(c.playhead(now: t0.addingTimeInterval(60.5), total: 1), 0.25, accuracy: 1e-9, "resumes from 0.75")
        XCTAssertEqual(c.playhead(now: t0, total: 0), 0)
    }

    // MARK: R6 image viewer zoom slider

    func testZoomSliderMappingIsLogarithmicAndRoundTrips() {
        let lo: CGFloat = 0.1, hi: CGFloat = 8
        XCTAssertEqual(ImageViewerZoomSlider.value(magnification: lo, min: lo, max: hi), 0, accuracy: 1e-9)
        XCTAssertEqual(ImageViewerZoomSlider.value(magnification: hi, min: lo, max: hi), 1, accuracy: 1e-9)
        for v in stride(from: 0.0, through: 1.0, by: 0.125) {
            let m = ImageViewerZoomSlider.magnification(value: v, min: lo, max: hi)
            XCTAssertEqual(ImageViewerZoomSlider.value(magnification: m, min: lo, max: hi), v, accuracy: 1e-6)
        }
        let a = ImageViewerZoomSlider.magnification(value: 0.25, min: lo, max: hi)
        let b = ImageViewerZoomSlider.magnification(value: 0.5, min: lo, max: hi)
        let c = ImageViewerZoomSlider.magnification(value: 0.75, min: lo, max: hi)
        XCTAssertEqual(b / a, c / b, accuracy: 1e-6, "equal slider steps = equal zoom factors")
    }

    func testViewerHasZoomSliderThatDrivesMagnification() throws {
        let viewer = ImageViewerController(viewerWindow: ImageViewerChrome.makeWindow {
            OffscreenWindow(contentRect: $0, styleMask: $1, backing: .buffered, defer: true)
        })
        let root = try XCTUnwrap(viewer.window?.contentView)
        let slider = try XCTUnwrap(GuardSupport.subviews(of: root).compactMap { $0 as? NSSlider }
            .first { $0.accessibilityLabel() == "Zoom" }, "no zoom slider in the image viewer bar")
        let scroll = try XCTUnwrap(GuardSupport.subviews(of: root).compactMap { $0 as? NSScrollView }.first)
        slider.doubleValue = 1
        _ = slider.sendAction(slider.action, to: slider.target)
        XCTAssertEqual(scroll.magnification, scroll.maxMagnification, accuracy: 0.01)
        slider.doubleValue = 0
        _ = slider.sendAction(slider.action, to: slider.target)
        XCTAssertEqual(scroll.magnification, scroll.minMagnification, accuracy: 0.01)
        // Moving the zoom by other means moves the slider.
        scroll.magnification = scroll.maxMagnification
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(slider.doubleValue, 1, accuracy: 0.01)
    }

    // MARK: R7 thread panel close button

    func testCloseThreadReturnsToTheChannelSelection() {
        let (_, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        model.navigator?.select(section: .teams)
        let open = TeamsSelection(teamID: "demo-team-eng", channelID: DemoTeams.threadedChannelID,
                                  threadID: DemoTeams.threadRootID)
        model.navigator?.select(open.selection, in: .teams)
        XCTAssertEqual(TeamsSelection(model.nav.selection(in: .teams))?.threadID, DemoTeams.threadRootID)
        ThreadInspectorHeader.closeThread(open, model)
        let after = TeamsSelection(model.nav.selection(in: .teams))
        XCTAssertNil(after?.threadID, "Close Thread must close the thread")
        XCTAssertEqual(after?.channelID, DemoTeams.threadedChannelID, "and stay on the channel")
        XCTAssertEqual(ThreadInspectorHeader.closeLabel, "Close Thread")
    }

    // MARK: R7 calendar event details show the join link text

    func testEventDetailsShowJoinLinkText() {
        let url = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0"
        let withLink = MeetingItem(meetingId: "m1", subject: "Standup", joinURL: url)
        let none = MeetingItem(meetingId: "m2", subject: "Lunch")
        XCTAssertEqual(JoinLinkRow.text(for: withLink), url)
        XCTAssertNil(JoinLinkRow.text(for: none))
    }
}
