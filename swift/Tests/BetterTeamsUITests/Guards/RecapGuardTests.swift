// RecapGuardTests — RECAP2 guards: the recap viewer's part switcher is a
// native segmented control (HIG, not text tabs or a custom capsule), and a
// Recaps route naming a meeting chat opens that chat's recap (capture route
// app/recaps/demo-3 showed "No Recap Selected"). No windows.
import AppKit
import SwiftUI
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class RecapGuardTests: XCTestCase {
    func testRecapPartSwitcherIsANativeSegmentedControl() throws {
        let (app, _, _) = GuardSupport.demoModel()
        let vm = app.meetingRecaps.model(threadID: DemoData.standupID, title: "Standup")
        let host = NSHostingView(rootView: MeetingRecapView(recap: vm, recordings: app.recordings)
            .frame(width: 900, height: 600))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        host.layoutSubtreeIfNeeded()
        let controls = GuardSupport.subviews(of: host).compactMap { $0 as? NSSegmentedControl }
        let control = try XCTUnwrap(controls.first, "an NSSegmentedControl switches the recap parts")
        XCTAssertEqual(controls.count, 1)
        let labels = (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
        XCTAssertEqual(labels, MeetingRecapTab.allCases.map(\.title))
        // Never the chat's own tab names (a meeting chat shows both bars).
        XCTAssertFalse(labels.contains("Notes") || labels.contains("Recap"), "\(labels)")
    }

    /// AI notes and follow-ups share one List: their row ids must not collide
    /// (offset ids did, and the follow-ups section showed the notes).
    func testAIRecapRowIdsAreUniqueAcrossSections() {
        let ids = MeetingRecapView.rows(["a", "b"], "note").map(\.id) + MeetingRecapView.rows(["c", "d"], "task").map(\.id)
        XCTAssertEqual(Set(ids).count, 4, "\(ids)")
        XCTAssertEqual(MeetingRecapView.rows(["c", "d"], "task").map(\.text), ["c", "d"])
    }

    func testRecapsRouteNamingAMeetingChatOpensItsRecap() {
        let rows = [
            Recap(id: "rec-1", title: "Standup", recording: nil, transcript: nil, date: nil, threadID: "19:meeting_a"),
            Recap(id: "19:meeting_b", title: "Review", recording: nil, transcript: nil, date: nil, threadID: "19:meeting_b"),
        ]
        XCTAssertEqual(RecapsSection.row("rec-1", in: rows)?.id, "rec-1")
        XCTAssertEqual(RecapsSection.row("19:meeting_a", in: rows)?.id, "rec-1", "thread id → the recap its chat matched")
        XCTAssertEqual(RecapsSection.row("19:meeting_b", in: rows)?.id, "19:meeting_b")
        XCTAssertNil(RecapsSection.row("nope", in: rows))
    }

    /// The rail is the owner's: a new account's rail starts with no apps
    /// pinned (Recaps was once pinned by default, unasked; reverted).
    func testNewRailHasNoAppsPinnedByDefault() {
        let account = "recap-guard-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "bt.rail.\(account)") }
        XCTAssertEqual(RailModel(accountKey: account, persist: true).pinned, [])
    }
}
