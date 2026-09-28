// LeanStartupTests.swift — top10-menubar: opt-in login item (never
// self-enables), cold-start probe, menu-bar math, deferred media
// session, deferred meeting-list load. No hardware/network: the camera
// assertions cover allocation only (never start()), login items run on
// a fake service, meetings on a stub fetcher.
import XCTest

@testable import OstMacCore

// MARK: - Fake login-item service

private final class FakeLoginItemService: LoginItemService, @unchecked Sendable {
    var registered = false
    var calls: [String] = []
    var shouldThrow = false

    func isRegistered() -> Bool {
        calls.append("status")
        return registered
    }

    func register() throws {
        calls.append("register")
        if shouldThrow {
            throw NSError(
                domain: "test", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "nope"])
        }
        registered = true
    }

    func unregister() throws {
        calls.append("unregister")
        if shouldThrow {
            throw NSError(
                domain: "test", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "nope"])
        }
        registered = false
    }
}

@MainActor
final class LeanStartupTests: XCTestCase {
    override func tearDown() {
        ColdStart.reset()
        super.tearDown()
    }

    // MARK: - Login item: opt-in, never self-enables

    func testLoginItemInitTouchesNothing() {
        let fake = FakeLoginItemService()
        let store = LoginItemStore(service: fake)
        XCTAssertFalse(store.enabled) // default off
        XCTAssertTrue(fake.calls.isEmpty) // no read, no register — ever
    }

    func testLoginItemSetTrueRegistersOnce() async {
        let fake = FakeLoginItemService()
        let store = LoginItemStore(service: fake)
        await store.set(true)
        XCTAssertEqual(fake.calls, ["register", "status"])
        XCTAssertTrue(store.enabled)
        XCTAssertNil(store.error)
    }

    func testLoginItemToggleRoundTrips() async {
        let fake = FakeLoginItemService()
        let store = LoginItemStore(service: fake)
        await store.set(true)
        XCTAssertTrue(store.enabled)
        await store.set(false)
        XCTAssertEqual(fake.calls, ["register", "status", "unregister", "status"])
        XCTAssertFalse(store.enabled)
        XCTAssertNil(store.error)
    }

    func testLoginItemRegisterFailureSurfacesAndStaysOff() async {
        let fake = FakeLoginItemService()
        fake.shouldThrow = true
        let store = LoginItemStore(service: fake)
        await store.set(true)
        XCTAssertFalse(store.enabled)
        XCTAssertNotNil(store.error)
    }

    func testLoginItemRefreshAdoptsWithoutWriting() {
        let fake = FakeLoginItemService()
        fake.registered = true // enabled externally (old install)
        let store = LoginItemStore(service: fake)
        store.refresh()
        XCTAssertTrue(store.enabled)
        XCTAssertEqual(fake.calls, ["status"]) // read-only, never registers
    }

    // MARK: - Cold-start probe

    func testColdStartMarkBeforeArmNoOps() {
        ColdStart.reset()
        ColdStart.mark("x") // must not crash previews/tests
        XCTAssertFalse(ColdStart.hasMarked("x"))
        XCTAssertTrue(ColdStart.timeline().isEmpty)
    }

    func testColdStartTimelineIsOrdered() {
        ColdStart.arm()
        ColdStart.mark("a")
        ColdStart.mark("b")
        let names = ColdStart.timeline().map(\.name)
        XCTAssertEqual(names, ["a", "b"])
        XCTAssertTrue(ColdStart.hasMarked("a"))
        XCTAssertFalse(ColdStart.hasMarked("zzz"))
        let ms = ColdStart.timeline().map(\.ms)
        XCTAssertLessThanOrEqual(ms[0], ms[1])
        XCTAssertNotNil(ColdStart.elapsedMs())
    }

    func testColdStartReportCarriesMarksAndMediaLine() {
        ColdStart.arm()
        ColdStart.mark("appstate.init")
        var report = ColdStart.report()
        XCTAssertTrue(report.contains("appstate.init"))
        XCTAssertTrue(report.contains("media.inits-before-join: 0"))
        ColdStart.noteMediaInit("camera.session")
        XCTAssertEqual(ColdStart.mediaInitCount(), 1)
        report = ColdStart.report()
        XCTAssertTrue(report.contains("media.inits-before-join: 1 (camera.session)"))
    }

    // MARK: - Menu-bar math

    func testMenuBarLabelText() {
        XCTAssertNil(MenuBarFormat.labelText(forTotal: 0))
        XCTAssertEqual(MenuBarFormat.labelText(forTotal: 3), "3")
    }

    func testMenuBarUnreadRows() {
        let chats = [
            ChatItem(chatId: "a", name: "Ava"),
            ChatItem(chatId: "b", name: "Ben"),
            ChatItem(chatId: "c", name: "Cat"),
        ]
        // Highest count first; override-only threads count 1; unknown
        // ids skipped; zero-count ids dropped.
        let rows = MenuBarFormat.unreadRows(
            chats: chats, counts: ["a": 2, "ghost": 9, "c": 0],
            overrides: ["b"])
        XCTAssertEqual(rows, [
            MenuBarUnreadRow(chatID: "a", name: "Ava", count: 2),
            MenuBarUnreadRow(chatID: "b", name: "Ben", count: 1),
        ])
    }

    func testMenuBarUnreadRowsObeyLimit() {
        let chats = (0..<10).map { ChatItem(chatId: "c\($0)", name: "C\($0)") }
        let counts = Dictionary(
            uniqueKeysWithValues: chats.map { ($0.chatId, 1) })
        let rows = MenuBarFormat.unreadRows(
            chats: chats, counts: counts, overrides: [])
        XCTAssertEqual(rows.count, 8) // default cap
        XCTAssertEqual(
            MenuBarFormat.unreadRows(
                chats: chats, counts: counts, overrides: [], limit: 3).count, 3)
    }

    // MARK: - Deferred media session

    func testCameraSessionUnallocatedAtInit() {
        let camera = CameraCapture()
        XCTAssertFalse(camera.sessionAllocated) // no AVFoundation at launch
    }

    func testCameraSessionAllocatesOnceOnFirstTouch() {
        let camera = CameraCapture()
        let first = camera.session
        XCTAssertTrue(camera.sessionAllocated)
        XCTAssertTrue(camera.session === first) // stable identity
    }

    // MARK: - Deferred window content

    // MARK: - Deferred meeting-list load

    func testMeetingsStartUnloadedAndLoadOnDemand() async {
        // The launch path never loads: the window-appear refresh is the
        // first fetch (this pins that the deferred path works standalone).
        let fetches = LockedBox(0)
        let vm = MeetingsViewModel(meetingsFetcher: {
            fetches.mutate { $0 += 1 }
            return MeetingsResponse(ok: true, meetings: [
                MeetingItem(meetingId: "E1", subject: "Standup"),
            ])
        })
        XCTAssertEqual(fetches.value, 0)
        XCTAssertTrue(vm.meetings.isEmpty)
        await vm.load()
        XCTAssertEqual(fetches.value, 1)
        XCTAssertEqual(vm.meetings.count, 1)
    }
}
