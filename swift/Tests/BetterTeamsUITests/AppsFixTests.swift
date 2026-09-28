// AppsFixTests.swift — APPSFIX pins (UI-SPEC §6.2, §7.2, §7.3, §8 DL1):
// the conversation toolbar's Audio Call starts a session in the host
// Settings ▸ Calls chose, Reload validates off on the browser-only pane,
// a web app's load error never raises the window's offline state, and
// Add Web Link keeps the picked symbol.
import AppKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class AppsFixTests: XCTestCase {
    private func makeModel() -> WindowModel {
        let chats = ChatListViewModel(fetcher: { _ in ChatsResponse(ok: true, chats: []) })
        let graph = AccountWindowGraph(account: AccountRecord(id: "appsfix-test", displayName: "Test"), chats: chats)
        let model = WindowModel(graph: graph, accountKey: "appsfix-test", options: LaunchOptions(args: ["--evidence"]))
        let nav = Navigator(model: model)
        model.navigator = nav
        addTeardownBlock { _ = nav }
        return model
    }

    /// §6.2 Audio Call → a call on the conversation's thread, placed on
    /// the core slot, hosted per Settings ▸ Calls ▸ Show calls (DL1).
    func testAudioCallStartsSessionInChosenHost() {
        let model = makeModel()
        CallSettings.shared.useVolatileStorage(.separateWindow)
        defer { CallSettings.shared.useVolatileStorage() }
        model.navigator?.select(section: .chat)
        model.navigator?.select(SectionSelection(id: "19:appsfix"), in: .chat)

        let store = CallStore(demo: true)
        let a = ConversationToolbar.startAudioCall(model, show: false, store: store)
        XCTAssertEqual(a?.presentation, .separateWindow)
        XCTAssertEqual(a?.kind, .person(name: "Call", thread: "19:appsfix"))
        XCTAssertEqual(store.lastAction, "demo:place-live")
        a?.leave()

        CallSettings.shared.presentation = .mainWindow
        let b = ConversationToolbar.startAudioCall(model, store: CallStore(demo: true))
        XCTAssertEqual(b?.presentation, .mainWindow)
        XCTAssertEqual(model.nav.section, .call)
        b?.leave()

        // Video Call carries help text.
        XCTAssertNotNil(CommandCatalog.command(ChatCommands.videoCall)?.help)
    }

    /// VIDEO1 + MEETVIDEO: Video Call starts a video session (camera on)
    /// through the core's video place path; a group chat gets the tile
    /// grid (demo roster, never the core's video queues), a 1:1 chat the
    /// 1:1 stage.
    func testVideoCallStartsInOneOnOneAndGroupChats() {
        let model = makeModel()
        CallSettings.shared.useVolatileStorage(.separateWindow)
        defer { CallSettings.shared.useVolatileStorage() }
        model.graph.chats.insertLocally(ChatItem(chatId: "19:peer", name: "Ava Lindqvist"))
        model.graph.chats.insertLocally(ChatItem(chatId: "19:group", name: "Standup", is_group: true))
        model.navigator?.select(section: .chat)

        model.navigator?.select(SectionSelection(id: "19:group"), in: .chat)
        let groupStore = CallStore(demo: true)
        let g = ConversationToolbar.startVideoCall(model, show: false, store: groupStore)
        XCTAssertEqual(g?.group, true)
        XCTAssertEqual(groupStore.lastAction, "demo:place-video")
        XCTAssertEqual(g?.meetingVideo?.tiles.count, MeetingVideoModel.demoRoster.count)
        XCTAssertEqual(g?.meetingVideo?.tiles.filter(\.videoOn).count, 3, "a mix of cameras on and off")
        XCTAssertTrue(g?.meetingVideo?.videos.isEmpty ?? false, "demo never decodes core video")
        g?.leave()
        XCTAssertFalse(groupStore.cameraOn)

        model.navigator?.select(SectionSelection(id: "19:peer"), in: .chat)
        let store = CallStore(demo: true)
        let s = ConversationToolbar.startVideoCall(model, show: false, store: store)
        XCTAssertEqual(s?.video, true)
        XCTAssertEqual(s?.group, false)
        XCTAssertNil(s?.meetingVideo)
        XCTAssertEqual(store.lastAction, "demo:place-video")
        XCTAssertTrue(store.cameraOn)
        XCTAssertEqual(s?.connected, true)
        XCTAssertTrue(s?.remoteVideos.isEmpty ?? false, "demo never decodes core video")
        s?.leave()
        XCTAssertFalse(store.cameraOn, "the next demo call starts camera-off")
    }

    /// §7.3: nothing to reload on "Opens in Your Browser", even with a
    /// resident view for that key.
    func testReloadDisabledOnBrowserOnlyPane() {
        let app = AppState(args: ["--demo"])
        let m = WindowModel(graph: app, accountKey: "demo", options: LaunchOptions(args: ["--demo"]))
        let id = "web-demo-status"
        guard let external = m.frameHost.library.app(id) else { return XCTFail("demo app missing") }
        XCTAssertFalse(external.launch.runsInApp)
        m.frameHost.registerApp(external)
        m.frameHost.attach(.app(id), to: NSView())
        XCTAssertNotNil(m.frameHost.webView(.app(id)))
        XCTAssertFalse(WebAppSection(appID: id).validate(AppsCommands.reload, arg: nil, m).enabled)
    }

    /// A web app's own load error ("Couldn't Load") is not the window's
    /// connection; other sections' forced errors stay the offline failure.
    func testWebAppLoadErrorDoesNotRaiseOffline() {
        XCTAssertNil(Route(string: "app/web-demo?state=error")?.forcedConnection)
        XCTAssertEqual(Route(string: "chat?state=error")?.forcedConnection, "offline")
        XCTAssertEqual(Route(string: "app/web-demo?connection=offline")?.forcedConnection, "offline")
    }

    /// §7.2 Add Web Link: URL, name, symbol — the symbol is the link's glyph.
    func testAddWebLinkKeepsSymbol() {
        let library = AppsLibrary(accountKey: "demo")
        let app = library.addWebLink(name: "Wiki", url: "https://contoso.sharepoint.com/wiki", symbol: "book")
        XCTAssertEqual(app?.symbol, "book")
        XCTAssertEqual(library.addWebLink(name: "", url: "https://contoso.sharepoint.com/x")?.symbol, "link")
    }
}
