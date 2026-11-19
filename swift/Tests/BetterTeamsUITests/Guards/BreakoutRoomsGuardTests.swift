// BreakoutRoomsGuardTests — BREAKOUT guard: the Call menu's
// Breakout Rooms entry (native label, group-meeting gate) and the
// sheet's static surface, plus the live gate (no rooms API: live
// disables every mutation, demo stays interactive). No windows, no
// network: the store drives everything, the section only validates
// and presents.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class BreakoutRoomsGuardTests: XCTestCase {
    private func window() -> WindowModel {
        let app = AppState(args: ["--demo"])
        let model = WindowModel(graph: app, accountKey: "demo",
                                options: LaunchOptions(args: ["--demo"]))
        let nav = Navigator(model: model)
        model.navigator = nav
        addTeardownBlock { _ = nav }
        return model
    }

    /// Live-flagged model without a live AppState (which needs an app
    /// bundle for notification center): the demo graph with non-demo
    /// options, the same shape FixPack3UITests uses. roomsLive reads
    /// only these two flags, so this pins the production predicate.
    private func liveWindow() -> WindowModel {
        let app = AppState(args: ["--demo"])
        let model = WindowModel(graph: app, accountKey: "live",
                                options: LaunchOptions(args: []))
        let nav = Navigator(model: model)
        model.navigator = nav
        addTeardownBlock { _ = nav }
        return model
    }

    func testRoomsCommandLabelIsNativeMenuTitle() {
        let entry = CallCommands.all.first { $0.id == CallCommands.rooms }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.title, "Breakout Rooms…")
    }

    func testRoomsRequiresARunningCall() {
        let section = CallSection()
        let m = window()
        let v = section.validate(CallCommands.rooms, arg: nil, m)
        XCTAssertFalse(v.enabled)
        XCTAssertNil(section.sheet(SheetRequest(CallCommands.roomsSheet, in: .call), m))
    }

    func testRoomsStaysOffForOneToOneCalls() {
        let section = CallSection()
        let m = window()
        let session = CallSession(kind: .person(name: "Ava Lindqvist", thread: "19:t"),
                                  presentation: .mainWindow, model: m)
        m.call = session
        addTeardownBlock { session.leave() }
        XCTAssertTrue(session.joined)
        XCTAssertFalse(session.group)
        XCTAssertFalse(section.validate(CallCommands.rooms, arg: nil, m).enabled)
    }

    func testRoomsStaysOffBeforeJoin() {
        let section = CallSection()
        let m = window()
        let session = CallSession(kind: .meeting(id: "mtg", subject: "Weekly Sync"),
                                  presentation: .mainWindow, model: m)
        m.call = session
        addTeardownBlock { session.leave() }
        XCTAssertFalse(session.joined)
        XCTAssertFalse(section.validate(CallCommands.rooms, arg: nil, m).enabled)
    }

    func testSheetPresentsOverTheRoster() {
        let section = CallSection()
        let m = window()
        let session = CallSession(kind: .meeting(id: "mtg", subject: "Weekly Sync"),
                                  presentation: .mainWindow, model: m)
        m.call = session
        addTeardownBlock { session.leave() }
        let body = section.sheet(SheetRequest(CallCommands.roomsSheet, in: .call), m)
        XCTAssertNotNil(body)
    }

    func testRoomsLiveGateFlagsOnlyNonDemoModels() {
        XCTAssertTrue(CallSection.roomsLive(liveWindow()))
        XCTAssertFalse(CallSection.roomsLive(window()))
    }

    func testRoomsMutationsDisabledInLive() {
        let live = BreakoutRoomsSheet(rooms: BreakoutRoomsStore(),
                                      roster: MeetingRosterStore(), live: true)
        XCTAssertTrue(live.mutationsDisabled)
        live.rooms.canManage = false
        XCTAssertTrue(live.mutationsDisabled,
                      "live disables mutations whatever the manager flag")
        XCTAssertFalse(BreakoutRoomsSheet.liveDisabledReason.isEmpty)
    }

    func testRoomsEvidenceForceLiveDefaultsOff() {
        XCTAssertFalse(CallEvidence.roomsForceLive,
                       "demo stays interactive unless a roomsLive=1 route says otherwise")
    }

    func testRoomsMutationsEnabledInDemo() {
        let demo = BreakoutRoomsSheet(rooms: BreakoutRoomsStore(),
                                      roster: MeetingRosterStore(), live: false)
        XCTAssertFalse(demo.mutationsDisabled)
    }

    func testCallEndsWithNoRoomsLeft() {
        let session = CallSession(kind: .meeting(id: "mtg", subject: "Weekly Sync"),
                                  presentation: .mainWindow, model: nil)
        session.breakoutRooms.create(count: 2, mode: .automatic, rosterIDs: ["a"])
        session.breakoutRooms.openAll()
        session.leave()
        XCTAssertFalse(session.breakoutRooms.isActive)
    }
}
