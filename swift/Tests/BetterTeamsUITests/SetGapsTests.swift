// SetGapsTests.swift — Settings gaps (UI-SPEC §9.2–§9.4, §7.3): account
// reorder, mention switches and the banner's sender, apps in memory,
// downloads folder, Teams links that never load as pages, demo-inert
// maintenance, and the Dock and menu bar extra menus.
import AppKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class SetGapsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppSettings.useDemoStorage()
        CallSettings.useDemoStorage()
    }

    private let teamsApp = FrameApp(
        id: "sg.board", label: "Launch Board", symbol: "square.grid.2x2", source: .webLink,
        launch: .direct(URL(string: "https://contoso.sharepoint.com/sites/board")!))

    /// §9.4 Accounts: drag reorder persists; out-of-range offsets are a no-op.
    func testAccountReorderPersists() throws {
        let d = MemoryDefaults()
        let list = [AccountRecord(id: "a", displayName: "Claire Dawson"),
                    AccountRecord(id: "b", displayName: "Owen Parker"),
                    AccountRecord(id: "c", displayName: "Grace Mitchell")]
        d.set(try JSONEncoder().encode(list), forKey: AccountStore.listKey)
        let s = AccountStore(defaults: d)
        XCTAssertEqual(s.accounts.map(\.id), ["a", "b", "c"], "control: seeded order")
        s.move(fromOffsets: [2], toOffset: 0)
        XCTAssertEqual(AccountStore(defaults: d).accounts.map(\.id), ["c", "a", "b"])
        s.move(fromOffsets: [0], toOffset: 3)
        XCTAssertEqual(s.accounts.map(\.id), ["a", "b", "c"])
        s.move(fromOffsets: [7], toOffset: 0)
        XCTAssertEqual(AccountStore(defaults: d).accounts.map(\.id), ["a", "b", "c"])
    }

    /// §9.4 Notifications ▸ Mention Alerts edit one rule per switch; §9.3
    /// message banners carry the sender, never on a locked screen.
    func testMentionSwitchesAndBannerSender() {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("setgaps-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let rules = RulesStore(path: path)
        XCTAssertTrue(rules.config.noisyChannelMentions, "control: absent rule = on")
        XCTAssertTrue(rules.config.matchByDisplayName, "control: absent rule = on")
        rules.setSwitch(NotifyRule.noisyChannel, on: false)
        rules.setSwitch(NotifyRule.nameBackup, on: false)
        let reloaded = RulesStore(path: path).config
        XCTAssertFalse(reloaded.noisyChannelMentions)
        XCTAssertFalse(reloaded.matchByDisplayName)
        rules.setSwitch(NotifyRule.noisyChannel, on: true)
        XCTAssertTrue(rules.config.noisyChannelMentions)
        XCTAssertEqual(rules.config.notifyRules.filter { NotifyRule.canonicalKind($0.kind) == NotifyRule.noisyChannel }.count,
                       1, "a switch edits its rule, never stacks another")

        let msg = RealtimeMessage(chatID: "19:sg", msgId: "m1", sender: "Laura Bennett", senderID: "8:orgid:lb",
                                  text: "hello", time: "2026-09-28T10:00:00Z", isEdit: false)
        let note = MessageNotifications.makeNotification(for: msg)
        XCTAssertEqual(note?.sender, "Laura Bennett")
        XCTAssertEqual(note?.senderID, "8:orgid:lb")
        let locked = MessageNotifications.makeNotification(for: msg, screenLocked: true)
        XCTAssertNotNil(locked, "control: locked screens still post")
        XCTAssertNil(locked?.sender, "a locked screen never names or pictures the sender")
        XCTAssertNotNil(NotificationRouter.avatarPNG("Laura Bennett"))
    }

    /// §9.4 Apps: apps in memory list residents with Unload; the view
    /// fills its clipping container; demo never reads a saved downloads
    /// folder.
    func testAppsResidentsAndUnload() {
        let host = FrameHost(accountKey: "demo")
        let key = FrameKey.app(teamsApp.id)
        host.registerApp(teamsApp)
        XCTAssertTrue(host.residentPages.isEmpty, "control: registered is not resident")
        let container = FrameContainerView(key: key, host: host)
        container.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        host.attach(key, to: container)
        XCTAssertEqual(host.residentPages.map(\.key), [key])
        XCTAssertFalse(host.residentPages[0].isOnScreen)
        XCTAssertTrue(container.clipsToBounds)
        XCTAssertEqual(host.webView(key)?.frame, container.bounds, "the view fills its pane (no crops: APPNATIVE4)")

        host.detach(key, from: container)
        host.unload(key)
        XCTAssertTrue(host.residentPages.isEmpty)
        XCTAssertEqual(host.downloadsFolder, FrameHost.defaultDownloads())
    }

    /// APPNATIVE4: a Teams link saved as an app never loads the Teams
    /// web app: its pane stays unloaded and says where the link goes;
    /// a standalone page (control) loads as it is.
    func testTeamsLinkAppNeverLoadsTeamsWeb() throws {
        let host = FrameHost(accountKey: "demo")
        let link = FrameApp(id: "sg.link", label: "Board", symbol: "doc", source: .webLink,
                            launch: try XCTUnwrap(FramePolicy.launch(url: "https://teams.microsoft.com/_#/l/entity/sg-board")))
        let direct = FrameApp(id: "sg.sheet", label: "Budget Sheet", symbol: "doc", source: .webLink,
                              launch: .direct(URL(string: "https://contoso.sharepoint.com/sites/budget")!))
        for a in [link, direct] {
            host.registerApp(a)
            host.attach(.app(a.id), to: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200)))
        }
        let page = try XCTUnwrap(host.page(.app(link.id)))
        XCTAssertFalse(TeamsWebGuard.isTeamsWeb(page.url), page.url.absoluteString)
        guard case .failed(let message, _) = page.state else { return XCTFail("\(page.state)") }
        XCTAssertEqual(message, FrameHost.failureMessage("teams web link"))
        let control = try XCTUnwrap(host.page(.app(direct.id)))
        XCTAssertEqual(control.url.host, "contoso.sharepoint.com", "control: a standalone page loads")
        if case .failed = control.state { XCTFail("control failed") }
    }

    /// §9.4 Advanced: Rebuild Offline Index and Reset Caches do nothing
    /// in demo (the demo index stays; no disk is touched).
    func testMaintenanceIsInertInDemo() async {
        defer { RichMediaCache.memoryOnly = false }
        let app = AppState(args: ["--demo"])
        let docs = app.localSearch.docCount
        XCTAssertGreaterThan(docs, 0, "control: demo threads are indexed")
        app.rebuildSearchIndex()
        await app.resetCaches()
        XCTAssertEqual(app.localSearch.docCount, docs)
        XCTAssertEqual(LogsFolder.url.lastPathComponent, AppIdentity.name)
    }

    /// §9.2: Dock menu = New Chat, Set Status ▸, up to five unread chats;
    /// menu bar extra = Presence ▸, the same chats, New Chat, Open, Quit.
    func testDockAndStatusMenuContents() async {
        defer { RichMediaCache.memoryOnly = false }
        let app = AppState(args: ["--demo"])
        await app.chats.load()
        let wc = ShellWindowController(graph: app, options: LaunchOptions(args: ["--demo", "--evidence"]))
        func titles(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }

        let ids = app.chats.chats.map(\.id)
        XCTAssertGreaterThan(ids.count, 5, "control: more chats than the cap")
        for id in ids { app.unread.markUnread(chatID: id) }
        let unread = DockMenu.unreadChats(wc.model).map(\.name)
        XCTAssertEqual(unread.count, 5)

        let dock = DockMenu.build(wc)
        XCTAssertEqual(titles(dock), ["New Chat", "Set Status", "-"] + unread)
        XCTAssertNotNil(dock.items[1].submenu)

        let status = NSMenu()
        StatusItemController.build(status, wc)
        XCTAssertEqual(titles(status),
                       ["Presence", "-"] + unread + ["-", "New Chat", "Open Better Teams", "-", "Quit Better Teams"])
        XCTAssertNotNil(status.items[0].submenu)
    }
}
