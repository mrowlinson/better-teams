// ChatTabsTests.swift — CHATTABS: chat kinds, pinned tab routes, the
// tab row fold, and the pinned-tab wire decode.
import Foundation
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

@MainActor
final class ChatTabsTests: XCTestCase {
    func testChatKindsAndBuiltins() {
        XCTAssertEqual(ChatKind.of(chatID: "48:notes", isGroup: false), .selfChat)
        XCTAssertEqual(ChatKind.of(chatID: "19:meeting_abc@thread.v2", isGroup: true), .meeting)
        XCTAssertEqual(ChatKind.of(chatID: "19:a_b@unq.gbl.spaces", isGroup: false), .oneOnOne)
        XCTAssertEqual(ChatKind.of(chatID: "19:abc@thread.v2", isGroup: true), .group)
        XCTAssertEqual(ChatTabCatalog.builtins(for: .meeting), ["chat", "files", "notes", "recap"])
        XCTAssertEqual(ChatTabCatalog.builtins(for: .group), ["chat", "files", "notes"])
        XCTAssertEqual(ConversationTab.files.title, "Shared")
    }

    func testPinnedTabDecodeAndRoutes() throws {
        let json = """
            {"ok":true,"chat_id":"19:abc@thread.v2","tabs":[\
            {"id":"t1","name":"Whiteboard","app_id":"95de633a-083e-42f5-b444-a4295d8e9314",\
            "content_url":"https://app.whiteboard.microsoft.com/x","website_url":null,"entity_id":null,\
            "app_name":"Whiteboard","teams_url":"https://teams.microsoft.com/l/entity/wb"},\
            {"id":"t2","name":"Roster","app_id":"1c256a65-83a6-4b5c-9ccf-78f8afb6f1e8",\
            "content_url":"https://www.microsoft365.com/x","teams_url":"https://teams.microsoft.com/l/entity/f"},\
            {"id":"t3","name":"Board","app_id":"com.microsoft.teamspace.tab.web","content_url":"https://example.com/b"},\
            {"id":"t4","name":"Reminders","app_id":"3p","content_url":"https://example.com/r"}]}
            """
        let tabs = try JSONDecoder().decode(TabsResponse.self, from: Data(json.utf8)).tabs
        XCTAssertEqual(tabs[0].appName, "Whiteboard")
        XCTAssertEqual(tabs[0].teamsURL, "https://teams.microsoft.com/l/entity/wb")
        XCTAssertEqual(ChatTabCatalog.kind(of: tabs[0]), .whiteboard)
        XCTAssertEqual(ChatTabCatalog.kind(of: tabs[1]), .file)
        // Matched app (Office file tabs too) → host; unmatched → its own
        // page; never the Teams web app (APPNATIVE4).
        XCTAssertEqual(ChatTabCatalog.route(for: tabs[0], hasManifest: true), .hosted)
        XCTAssertEqual(ChatTabCatalog.route(for: tabs[0], hasManifest: false),
                       .web(URL(string: "https://app.whiteboard.microsoft.com/x")!))
        XCTAssertEqual(ChatTabCatalog.route(for: tabs[1], hasManifest: true), .hosted)
        XCTAssertEqual(ChatTabCatalog.route(for: tabs[1], hasManifest: false),
                       .web(URL(string: "https://www.microsoft365.com/x")!))
        XCTAssertEqual(ChatTabCatalog.route(for: tabs[2], hasManifest: false), .web(URL(string: "https://example.com/b")!))
        XCTAssertEqual(ChatTabCatalog.route(for: tabs[3], hasManifest: false), .web(URL(string: "https://example.com/r")!))
    }

    func testFoldKeepsSelectedVisibleAndOverflowsRest() {
        let tabs = (1...5).map { ChannelTab(id: "t\($0)", name: "Tab \($0)", appID: "3p") }
        let layout = ChatTabLayout(kind: .meeting, tabs: tabs)
        let f = layout.folds(selected: .builtin(.chat), opened: nil)
        // Widest fold: built-ins + 3 pinned; each next one drops the last segment.
        XCTAssertEqual(f.first?.segments.map(\.name), ["Chat", "Shared", "Notes", "Recap", "Tab 1", "Tab 2", "Tab 3"])
        XCTAssertEqual(f.first?.more.map(\.name), ["Tab 4", "Tab 5"])
        XCTAssertEqual(f.last?.segments.map(\.name), ["Chat"])
        let g = layout.folds(selected: .pinned("t5"), opened: .pinned("t5"))
        XCTAssertEqual(g.first?.segments.suffix(2).map(\.name), ["Tab 3", "Tab 5"])
        XCTAssertEqual(g.first?.more.map(\.name), ["Tab 4"])
        XCTAssertEqual(g.last?.segments.map(\.name), ["Tab 5"])
        // A gone pinned tab or a built-in this kind lacks resolves to Chat.
        let group = ChatTabLayout(kind: .group, tabs: [])
        XCTAssertEqual(group.resolve(builtin: .recap, pinned: nil), .builtin(.chat))
        XCTAssertEqual(group.resolve(builtin: .files, pinned: "gone"), .builtin(.files))
    }

    func testStoreKeepsTabsOnFailureAndSkipsNonThreads() async {
        final class Box: @unchecked Sendable { var fail = false; var calls = 0 }
        let box = Box()
        let store = ChatTabsStore { id in
            box.calls += 1
            if box.fail { throw CoreCallError.failed("boom") }
            return TabsResponse(ok: true, tabs: [ChannelTab(id: "x", name: "X")])
        }
        await store.load(chatID: "19:abc@thread.v2", demo: false)
        XCTAssertEqual(store.tabs(for: "19:abc@thread.v2").map(\.id), ["x"])
        box.fail = true
        await store.load(chatID: "19:abc@thread.v2", demo: false)
        XCTAssertEqual(store.tabs(for: "19:abc@thread.v2").map(\.id), ["x"])
        await store.load(chatID: "48:notes", demo: false)
        await store.load(chatID: "19:gen@thread.tacv2", demo: false)
        XCTAssertEqual(box.calls, 2)
        await store.load(chatID: "demo", demo: true)
        XCTAssertEqual(store.tabs(for: "demo").count, 5)
    }
}
