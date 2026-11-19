// BreakoutRoomsTests: the local rooms plan (create/assign/open/close
// + state display). Pure store transitions; no roster store, no core,
// no network.
import XCTest

@testable import OstMacCore

@MainActor
final class BreakoutRoomsTests: XCTestCase {
    private func store() -> BreakoutRoomsStore { BreakoutRoomsStore() }

    // MARK: create

    func testCreateNamesRoomsInOrder() {
        let s = store()
        s.create(count: 3, mode: .manual)
        XCTAssertTrue(s.isActive)
        XCTAssertEqual(s.rooms.map({ $0.name }), ["Room 1", "Room 2", "Room 3"])
        XCTAssertEqual(s.rooms.map({ $0.id }), ["room-1", "room-2", "room-3"])
        XCTAssertTrue(s.rooms.allSatisfy({ !$0.isOpen }))
    }

    func testCreateClampsToOneThroughMax() {
        let s = store()
        s.create(count: 0, mode: .manual)
        XCTAssertEqual(s.rooms.count, 1)
        s.create(count: 999, mode: .manual)
        XCTAssertEqual(s.rooms.count, BreakoutRoomsStore.maxRooms)
    }

    func testCreateReplacesTheOldPlan() {
        let s = store()
        s.create(count: 2, mode: .manual)
        s.assign("p1", to: "room-1")
        s.setOpen("room-1", true)
        s.create(count: 4, mode: .manual)
        XCTAssertEqual(s.rooms.count, 4)
        XCTAssertTrue(s.rooms.allSatisfy({ !$0.isOpen }))
        XCTAssertNil(s.room(for: "p1"))
    }

    func testAutomaticDealsRosterRoundRobin() {
        let s = store()
        s.create(count: 2, mode: .automatic, rosterIDs: ["a", "b", "c"])
        XCTAssertEqual(s.rooms[0].assigneeIDs, ["a", "c"])
        XCTAssertEqual(s.rooms[1].assigneeIDs, ["b"])
        XCTAssertTrue(s.unassigned(rosterIDs: ["a", "b", "c"]).isEmpty)
    }

    func testManualLeavesEveryoneUnassigned() {
        let s = store()
        s.create(count: 2, mode: .manual, rosterIDs: ["a", "b"])
        XCTAssertEqual(s.unassigned(rosterIDs: ["a", "b"]), ["a", "b"])
    }

    // MARK: assign

    func testAssignMovesBetweenRooms() {
        let s = store()
        s.create(count: 2, mode: .manual, rosterIDs: ["a"])
        s.assign("a", to: "room-1")
        XCTAssertEqual(s.room(for: "a")?.id, "room-1")
        s.assign("a", to: "room-2")
        XCTAssertEqual(s.room(for: "a")?.id, "room-2")
        XCTAssertTrue(s.rooms[0].assigneeIDs.isEmpty)
    }

    func testAssignIgnoresUnknownRoomsAndBlankIDs() {
        let s = store()
        s.create(count: 1, mode: .manual)
        s.assign("a", to: "room-9")
        s.assign("  ", to: "room-1")
        XCTAssertNil(s.room(for: "a"))
        XCTAssertTrue(s.rooms[0].assigneeIDs.isEmpty)
    }

    func testUnassignFreesTheSeat() {
        let s = store()
        s.create(count: 2, mode: .automatic, rosterIDs: ["a"])
        s.unassign("a")
        XCTAssertNil(s.room(for: "a"))
        XCTAssertEqual(s.unassigned(rosterIDs: ["a"]), ["a"])
    }

    // MARK: open/close + state display

    func testOpenCloseOneRoom() {
        let s = store()
        s.create(count: 3, mode: .manual)
        s.setOpen("room-2", true)
        XCTAssertEqual(s.openCount, 1)
        XCTAssertTrue(s.rooms[1].isOpen)
        s.setOpen("room-2", false)
        XCTAssertEqual(s.openCount, 0)
    }

    func testOpenAllCloseAll() {
        let s = store()
        s.create(count: 3, mode: .manual)
        s.openAll()
        XCTAssertEqual(s.openCount, 3)
        s.closeAll()
        XCTAssertEqual(s.openCount, 0)
    }

    func testSetOpenIgnoresUnknownRooms() {
        let s = store()
        s.create(count: 1, mode: .manual)
        s.setOpen("room-9", true)
        XCTAssertEqual(s.openCount, 0)
    }

    func testResetEndsThePlan() {
        let s = store()
        s.create(count: 2, mode: .automatic, rosterIDs: ["a"])
        s.openAll()
        s.reset()
        XCTAssertFalse(s.isActive)
        XCTAssertEqual(s.openCount, 0)
    }

    // MARK: modes

    func testAssignModeTitles() {
        XCTAssertEqual(BreakoutAssignMode.automatic.title, "Assign automatically")
        XCTAssertEqual(BreakoutAssignMode.manual.title, "Assign manually")
    }
}
