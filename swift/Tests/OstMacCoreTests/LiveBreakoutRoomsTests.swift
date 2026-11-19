// LiveBreakoutRoomsTests: the live rooms store over the demo
// transport (load/create/assign/open/close/settings/announce +
// error wording + participant mapping), the coords JSON, and the
// Swift→core request-preview wiring (pure FFI, no network).
import XCTest

@testable import OstMacCore

@MainActor
final class LiveBreakoutRoomsTests: XCTestCase {
    private func store(_ t: DemoLiveBreakoutTransport = DemoLiveBreakoutTransport.seeded())
        -> LiveBreakoutRoomsStore {
        LiveBreakoutRoomsStore(coords: .demo, transport: t)
    }

    /// Poll until the store settles (demo answers are instant; the hop
    /// through Task.blocking still needs a turn).
    private func settle(_ s: LiveBreakoutRoomsStore, timeout: TimeInterval = 5) async throws {
        let end = Date().addingTimeInterval(timeout)
        while (s.loading || s.working) && Date() < end {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(s.loading || s.working, "store settled")
    }

    // MARK: load

    func testLoadAdoptsRoomsSettingsAndAssignees() async throws {
        let s = store()
        s.load()
        try await settle(s)
        XCTAssertEqual(s.rooms.count, 4)
        XCTAssertEqual(s.rooms.map(\.roomName), ["Room 1", "Room 2", "Room 3", "Room 4"])
        XCTAssertTrue(s.isActive)
        XCTAssertEqual(s.openCount, 0)
        XCTAssertNotNil(s.settings)
        XCTAssertEqual(s.assignees.count, 4)
        XCTAssertNil(s.error)
    }

    func testUnassignedDerivesFromRoster() async throws {
        let s = store()
        s.load()
        try await settle(s)
        let ids = ["8:orgid:ava", "8:orgid:hannah", "8:orgid:tom", "8:orgid:megan"]
        XCTAssertEqual(s.unassigned(rosterIDs: ids), ids)
        XCTAssertNil(s.room(for: "8:orgid:ava"))
    }

    // MARK: create + assign + remove

    func testCreateReplacesThePlan() async throws {
        let t = DemoLiveBreakoutTransport()
        let s = store(t)
        s.load()
        try await settle(s)
        XCTAssertFalse(s.isActive)
        s.create(count: 2, mode: .manual, roster: [])
        try await settle(s)
        XCTAssertEqual(s.rooms.count, 2)
        XCTAssertNil(s.error)
    }

    func testCreateClampsToOneThroughMax() async throws {
        let t = DemoLiveBreakoutTransport()
        let s = store(t)
        s.load()
        try await settle(s)
        s.create(count: 999, mode: .manual, roster: [])
        try await settle(s)
        XCTAssertEqual(s.rooms.count, LiveBreakoutRoomsStore.maxRooms)
    }

    func testAssignMovesTheSeatBetweenRooms() async throws {
        let s = store()
        s.load()
        try await settle(s)
        let ava = MeetingParticipant(id: "8:orgid:ava", name: "Ava Lindqvist")
        s.assign(ava, to: s.rooms[0].id)
        try await settle(s)
        XCTAssertEqual(s.room(for: "8:orgid:ava")?.id, s.rooms[0].id)
        s.assign(ava, to: s.rooms[1].id)
        try await settle(s)
        XCTAssertEqual(s.room(for: "8:orgid:ava")?.id, s.rooms[1].id)
        // Single-homed: the first room let go.
        XCTAssertFalse(s.rooms[0].participants.contains { $0.matches(rosterID: "8:orgid:ava") })
        XCTAssertNil(s.error)
    }

    func testUnassignFreesTheSeat() async throws {
        let s = store()
        s.load()
        try await settle(s)
        let ava = MeetingParticipant(id: "8:orgid:ava", name: "Ava Lindqvist")
        s.assign(ava, to: s.rooms[0].id)
        try await settle(s)
        s.unassign("8:orgid:ava")
        try await settle(s)
        XCTAssertNil(s.room(for: "8:orgid:ava"))
    }

    // MARK: open/close/reset

    func testOpenCloseOneRoom() async throws {
        let s = store()
        s.load()
        try await settle(s)
        s.setOpen(s.rooms[2].id, true)
        try await settle(s)
        XCTAssertEqual(s.openCount, 1)
        XCTAssertTrue(s.rooms[2].isOpened)
        s.setOpen(s.rooms[2].id, false)
        try await settle(s)
        XCTAssertEqual(s.openCount, 0)
    }

    func testOpenAllCloseAll() async throws {
        let s = store()
        s.load()
        try await settle(s)
        s.openAll()
        try await settle(s)
        XCTAssertEqual(s.openCount, 4)
        s.closeAll()
        try await settle(s)
        XCTAssertEqual(s.openCount, 0)
    }

    func testResetEndsThePlan() async throws {
        let s = store()
        s.load()
        try await settle(s)
        s.openAll()
        try await settle(s)
        s.reset()
        try await settle(s)
        XCTAssertFalse(s.isActive)
    }

    // MARK: settings + announce

    func testSaveSettingsRoundTrips() async throws {
        let s = store()
        s.load()
        try await settle(s)
        s.saveSettings(allowChoose: true, roomDuration: "PT15M")
        try await settle(s)
        XCTAssertEqual(s.settings?.allowChoose, true)
        XCTAssertEqual(s.settings?.roomDuration, "PT15M")
        XCTAssertNil(s.error)
    }

    func testAnnounceReachesOpenRoomsOnly() async throws {
        let t = DemoLiveBreakoutTransport.seeded()
        let s = store(t)
        s.load()
        try await settle(s)
        s.setOpen(s.rooms[0].id, true)
        try await settle(s)
        let open = s.rooms.filter(\.isOpened).map(\.id)
        s.announce("Back in 5", roomIDs: open)
        try await settle(s)
        let log = t.announceLog()
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log[0].message, "Back in 5")
        XCTAssertEqual(log[0].threads, ["19:demo_room1@thread.v2"])
        // Blank messages and empty rooms never send.
        s.announce("   ", roomIDs: open)
        s.announce("hi", roomIDs: [])
        XCTAssertEqual(t.announceLog().count, 1)
    }

    // MARK: participant mapping + wording (pure)

    func testWireParticipantPrefersAssigneeRecords() async throws {
        let s = store()
        s.load()
        try await settle(s)
        let hit = s.wireParticipant(for: MeetingParticipant(id: "8:orgid:ava", name: "Ava Lindqvist"))
        XCTAssertEqual(hit["mri"], "8:orgid:ava")
        XCTAssertEqual(hit["upn"], "ava.lindqvist@example.com")
        let miss = s.wireParticipant(for: MeetingParticipant(id: "8:orgid: stranger", name: "Zed"))
        XCTAssertEqual(miss, ["mri": "8:orgid: stranger"])
    }

    func testWordMapsAuthFailuresToReasons() {
        XCTAssertEqual(LiveBreakoutRoomsStore.word(CoreCallError.failed("HTTP 401 for u: x")),
                       "Sign in to manage live breakout rooms.")
        XCTAssertEqual(LiveBreakoutRoomsStore.word(CoreCallError.failed("No AAD token. Run login.")),
                       "Sign in to manage live breakout rooms.")
        XCTAssertTrue(LiveBreakoutRoomsStore.word(CoreCallError.failed("HTTP 403 for u: x"))
            .contains("organizer"))
        XCTAssertTrue(LiveBreakoutRoomsStore.word(CoreCallError.failed("boom"), what: "open")
            .contains("open"))
    }

    // MARK: coords JSON

    func testCoordsJSONRoundTripsSnakeKeys() throws {
        let c = BreakoutCoords.demo
        let data = c.jsonString.data(using: .utf8)!
        let back = try JSONDecoder().decode(BreakoutCoords.self, from: data)
        XCTAssertEqual(back, c)
        XCTAssertTrue(c.jsonString.contains("\"thread_id\""))
    }

    // MARK: request-preview wiring (pure FFI, no network)

    func testPreviewPinsListMethodAndPath() throws {
        let p = try BreakoutRequestPreview.preview(op: "list", coords: .demo, argsJSON: "{}")
        XCTAssertTrue(p.ok)
        XCTAssertEqual(p.method, "GET")
        XCTAssertTrue(p.url?.contains("beta/breakoutRoom/bulk/") ?? false)
        // Coords ride the path with the bundle encoding.
        XCTAssertTrue(p.url?.contains("demo-tenant/demo-organizer/19_demo_standup@thread.v2/1") ?? false)
    }

    func testPreviewPinsWriteOps() throws {
        let create = try BreakoutRequestPreview.preview(
            op: "create", coords: .demo, argsJSON: #"{"count":2,"preconfiguration":[]}"#)
        XCTAssertEqual(create.method, "POST")
        XCTAssertTrue(create.url?.contains("beta/breakoutRoom/demo-tenant/") ?? false)
        let bulk = try BreakoutRequestPreview.preview(
            op: "assign", coords: .demo, argsJSON: #"{"rooms":[],"total_participants":9}"#)
        XCTAssertEqual(bulk.method, "PUT")
        XCTAssertTrue(bulk.url?.contains("bulk/v2/") ?? false)
        let announce = try BreakoutRequestPreview.preview(op: "announce", coords: .demo, argsJSON: "{}")
        XCTAssertEqual(announce.method, "POST")
        XCTAssertFalse(announce.url?.contains("newVersion") ?? true)
    }

    func testPreviewRejectsUnknownOps() throws {
        // {ok:false} envelopes throw at decode: the throw IS the rejection.
        XCTAssertThrowsError(try BreakoutRequestPreview.preview(op: "nuke", coords: .demo, argsJSON: "{}"))
    }
}
