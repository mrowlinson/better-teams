// P4cSystemTests.swift — P4c pins (UI-SPEC §8, §9.2–§9.4, DL1): demo
// never posts system notifications, the Dock badge is the rail's Chat +
// Teams numbers, an accepted incoming call opens in the host Settings ▸
// Calls chose, and demo settings live in memory only.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class P4cSystemTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Never the person's settings (the app does this for --demo).
        AppSettings.useDemoStorage()
        CallSettings.useDemoStorage()
    }

    private func demoModel(_ app: AppState, evidence: Bool = true) -> WindowModel {
        let m = WindowModel(graph: app, accountKey: "demo",
                            options: LaunchOptions(args: evidence ? ["--demo", "--evidence"] : ["--demo"]))
        let nav = Navigator(model: m)
        m.navigator = nav
        addTeardownBlock { _ = nav }
        return m
    }

    /// §9.3: demo and evidence runs never post a system notification or
    /// ask for permission: the core's ring banner hook stays unset, the
    /// router reports no system posting and schedules no meeting reminder.
    func testDemoNeverPostsSystemNotifications() {
        defer { RichMediaCache.memoryOnly = false }
        XCTAssertTrue(NotificationRouter.postsSystemNotifications(LaunchOptions(args: [])), "control: live posts")
        XCTAssertFalse(NotificationRouter.postsSystemNotifications(LaunchOptions(args: ["--demo"])))
        XCTAssertFalse(NotificationRouter.postsSystemNotifications(LaunchOptions(args: ["--demo", "--evidence"])))

        let app = AppState(args: ["--demo"])
        XCTAssertNil(app.call.onIncomingRing, "demo ring must not post the CALL banner")
        app.call.seedDemo(state: "incoming")
        XCTAssertEqual(app.call.phase, .inviting)
        let wc = ShellWindowController(graph: app, options: LaunchOptions(args: ["--demo", "--evidence"]))
        let router = NotificationRouter(shell: wc)
        XCTAssertNil(router.reminders, "demo must not schedule MEETING notifications")
    }

    /// §9.3: Dock badge = unread chats + channels with unread mentions,
    /// the same numbers the rail shows on Chat and Teams; General ▸
    /// Dock badge off clears it.
    func testDockBadgeEqualsRailSum() {
        defer { RichMediaCache.memoryOnly = false }
        let app = AppState(args: ["--demo"])
        let m = demoModel(app)
        app.unread.markUnread(chatID: "p4c-a")
        app.unread.markUnread(chatID: "p4c-b")
        func rail() -> Int { [SectionID.chat, .teams].compactMap { m.provider($0).badge(m) }.reduce(0, +) }
        XCTAssertGreaterThanOrEqual(rail(), 2, "control: unread chats badge the rail")

        let dock = DockBadge(model: m, tile: nil)
        XCTAssertEqual(dock.shown, String(rail()))
        app.unread.markRead(chatID: "p4c-a")
        dock.refresh()
        XCTAssertEqual(DockBadge.count(m), rail())
        XCTAssertEqual(dock.shown, String(rail()))
        AppSettings.shared.showDockBadge = false
        dock.refresh()
        XCTAssertNil(dock.shown)
    }

    /// §8, DL1: Accept goes to the core call slot; the host reacts and
    /// shows the call in the presentation Settings ▸ Calls chose, read
    /// when the call starts. Ringing alone shows no custom UI.
    func testAcceptUsesTheShowCallsHost() {
        let chats = ChatListViewModel(fetcher: { _ in ChatsResponse(ok: true, chats: []) })
        let graph = AccountWindowGraph(account: AccountRecord(id: "p4c-test", displayName: "Test"), chats: chats)
        let model = WindowModel(graph: graph, accountKey: "p4c-test", options: LaunchOptions(args: ["--evidence"]))
        let nav = Navigator(model: model)
        model.navigator = nav
        addTeardownBlock { _ = nav }
        let store = CallStore(demo: true)
        let host = IncomingCallHost(model: model, store: store, show: false)

        func settle() {
            let hop = expectation(description: "main hop")
            DispatchQueue.main.async { hop.fulfill() }
            wait(for: [hop], timeout: 2)
        }

        CallSettings.shared.presentation = .separateWindow
        store.seedDemo(state: "incoming")
        settle()
        XCTAssertNil(model.call, "ringing: the notification is the UI")
        store.accept()
        settle()
        XCTAssertEqual(model.call?.presentation, .separateWindow)
        XCTAssertEqual(model.call?.connected, true)
        XCTAssertEqual(host.hostedCallID, "demo-call")

        store.end()
        settle()
        XCTAssertNil(model.call)
        CallSettings.shared.presentation = .mainWindow
        store.seedDemo(state: "incoming")
        store.accept()
        settle()
        XCTAssertEqual(model.call?.presentation, .mainWindow)
    }

    /// Demo settings live in `MemoryDefaults`: a change never reaches
    /// `.standard`; the demo core stores the panes bind to are in memory.
    func testDemoSettingsStayInMemory() {
        defer { RichMediaCache.memoryOnly = false }
        let s = AppSettings.shared
        XCTAssertTrue(s.isMemory)
        let key = AppSettings.Key.menuBar
        let before = UserDefaults.standard.object(forKey: key) as? Bool
        s.showInMenuBar.toggle()
        XCTAssertEqual(s.defaults.object(forKey: key) as? Bool, s.showInMenuBar)
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, before, "demo wrote real defaults")

        let app = AppState(args: ["--demo"])
        XCTAssertTrue(app.storageDefaults is MemoryDefaults)
        let apps = AppsPane(host: FrameHost(accountKey: "demo"), defaults: s.defaults)
        XCTAssertTrue(apps.defaults is MemoryDefaults)
        let callBefore = UserDefaults.standard.string(forKey: CallPresentation.defaultsKey)
        CallSettings.shared.presentation = CallSettings.shared.presentation == .mainWindow ? .separateWindow : .mainWindow
        XCTAssertEqual(UserDefaults.standard.string(forKey: CallPresentation.defaultsKey), callBefore)
    }
}
