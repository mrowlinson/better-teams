// TeamsTabsTests.swift — om-h4-tabs lane: wire decode, target mapping, store open.
import Foundation
import XCTest

@testable import OstMacCore

@MainActor
final class TeamsTabsTests: XCTestCase {
    nonisolated static func tabsJSON() -> TabsResponse {
        let json = """
            {"ok":true,"channel_id":"19:abc@thread.tacv2","tabs":[\
            {"id":"tab-posts","name":"Posts","app_id":null,\
            "content_url":null,"website_url":null},\
            {"id":"tab-files","name":"Files",\
            "app_id":"com.microsoft.teamspace.tab.files.sharepoint",\
            "content_url":null,"website_url":null},\
            {"id":"tab-notes","name":"Notes","app_id":"0d820ecd-def2-4297-a09a-912c7e06f45b",\
            "content_url":null,\
            "website_url":"https://example.sharepoint.com/notes"},\
            {"id":"tab-web","name":"Dashboard",\
            "app_id":"com.example.dashboard",\
            "content_url":"https://example.com/app","website_url":null}]}
            """
        return try! decodeOrThrow(TabsResponse.self, from: Data(json.utf8))
    }

    func waitFor(_ what: String, _ cond: @escaping () -> Bool) async throws {
        if try await TestWait.untilThrowing({ cond() }) { return }
        XCTFail("timed out waiting for \(what)")
    }

    func testDecodeTabs() {
        let response = Self.tabsJSON()
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.tabs.count, 4)
        XCTAssertEqual(response.tabs[0].id, "tab-posts")
        XCTAssertEqual(response.tabs[1].name, "Files")
        XCTAssertEqual(
            response.tabs[1].appID, "com.microsoft.teamspace.tab.files.sharepoint")
        XCTAssertEqual(
            response.tabs[3].contentURL, "https://example.com/app")
    }

    func testTargetMapping() {
        let tabs = Self.tabsJSON().tabs
        XCTAssertEqual(tabs[0].target, .chat)
        XCTAssertEqual(tabs[1].target, .shared)
        XCTAssertEqual(tabs[2].target, .notes)
        XCTAssertEqual(tabs[3].target, .web(URL(string: "https://example.com/app")!))
    }

    func testIsChannelID() {
        XCTAssertTrue(ChannelTabsStore.isChannelID("19:abc@thread.tacv2"))
        XCTAssertFalse(ChannelTabsStore.isChannelID("19:abc@thread.v2"))
        XCTAssertFalse(ChannelTabsStore.isChannelID("demo"))
        XCTAssertFalse(ChannelTabsStore.isChannelID(""))
    }

    func testOpenReplacesTabs() async throws {
        let resp = Self.tabsJSON()
        let store = ChannelTabsStore(list: { _ in resp })
        store.open(channelID: "19:abc@thread.tacv2")
        try await waitFor("loaded") { store.state == .loaded }
        XCTAssertEqual(store.tabs.count, 4)
        XCTAssertEqual(store.channelID, "19:abc@thread.tacv2")
    }

    func testOpenErrorSurfaces() async throws {
        let store = ChannelTabsStore(list: { _ in
            throw CoreCallError.failed("nope")
        })
        store.open(channelID: "19:abc@thread.tacv2")
        try await waitFor("error") {
            if case .error = store.state { return true }
            return false
        }
        XCTAssertTrue(store.tabs.isEmpty)
    }

    // TABS-MGMT: add/rename/remove mutate the open channel's rows.
    private nonisolated static func webTab(id: String, name: String) -> ChannelTab {
        ChannelTab(id: id, name: name, appID: ChatTabCatalog.websiteAppID,
                   contentURL: "https://example.com/x")
    }

    func testAddAppendsAndSelectsLoaded() async throws {
        let resp = Self.tabsJSON()
        let added = Self.webTab(id: "t-web2", name: "Board")
        let store = ChannelTabsStore(
            list: { _ in resp },
            add: { _, name, _, _ in TabManageResponse(ok: true, tab: Self.webTab(id: "t-web2", name: name)) },
            rename: { _, id, name in TabManageResponse(ok: true, tab: Self.webTab(id: id, name: name)) },
            remove: { _, tab in TabRemoveResponse(ok: true, tabId: tab) }
        )
        store.open(channelID: "19:abc@thread.tacv2")
        try await waitFor("loaded") { store.state == .loaded }
        await store.add(name: "Board", url: "https://example.com/x")
        XCTAssertNil(store.manageError)
        XCTAssertTrue(store.tabs.contains(added))
        await store.rename(tabID: "t-web2", name: "Renamed")
        XCTAssertNil(store.manageError)
        XCTAssertEqual(store.tabs.first { $0.id == "t-web2" }?.name, "Renamed")
        await store.remove(tabID: "t-web2")
        XCTAssertNil(store.manageError)
        XCTAssertFalse(store.tabs.contains { $0.id == "t-web2" })
    }

    func testManageFailureKeepsRows() async throws {
        let resp = Self.tabsJSON()
        let store = ChannelTabsStore(
            list: { _ in resp },
            add: { _, _, _, _ in throw CoreCallError.failed("denied") },
            rename: { _, _, _ in throw CoreCallError.failed("denied") },
            remove: { _, _ in throw CoreCallError.failed("denied") }
        )
        store.open(channelID: "19:abc@thread.tacv2")
        try await waitFor("loaded") { store.state == .loaded }
        let before = store.tabs
        await store.add(name: "Nope", url: nil)
        XCTAssertEqual(store.manageError, "denied")
        XCTAssertEqual(store.tabs, before)
        await store.rename(tabID: "tab-web", name: "Nope")
        XCTAssertEqual(store.manageError, "denied")
        XCTAssertEqual(store.tabs, before)
        await store.remove(tabID: "tab-web")
        XCTAssertEqual(store.manageError, "denied")
        XCTAssertEqual(store.tabs, before)
    }
}

@MainActor
final class ChatTabsManageTests: XCTestCase {
    func testChatAddRenameRemove() async throws {
        let chatID = "19:abc@thread.v2"
        let added = ChannelTab(id: "c1", name: "Board", appID: ChatTabCatalog.websiteAppID,
                               contentURL: "https://example.com/b")
        let store = ChatTabsStore(
            add: { _, name, _, _ in TabManageResponse(ok: true, tab: ChannelTab(
                id: "c1", name: name, appID: ChatTabCatalog.websiteAppID,
                contentURL: "https://example.com/b")) },
            rename: { _, id, name in TabManageResponse(ok: true, tab: ChannelTab(
                id: id, name: name, appID: ChatTabCatalog.websiteAppID,
                contentURL: "https://example.com/b")) },
            remove: { _, tab in TabRemoveResponse(ok: true, tabId: tab) }
        )
        await store.add(chatID: chatID, name: "Board", url: "https://example.com/b")
        XCTAssertNil(store.manageError[chatID])
        XCTAssertEqual(store.tabs(for: chatID), [added])
        await store.rename(chatID: chatID, tabID: "c1", name: "Renamed")
        XCTAssertEqual(store.tabs(for: chatID).first?.name, "Renamed")
        await store.remove(chatID: chatID, tabID: "c1")
        XCTAssertTrue(store.tabs(for: chatID).isEmpty)
    }

    func testChatManageFailureKeepsCache() async throws {
        let chatID = "19:abc@thread.v2"
        let store = ChatTabsStore(
            add: { _, _, _, _ in throw CoreCallError.failed("denied") },
            rename: { _, _, _ in throw CoreCallError.failed("denied") },
            remove: { _, _ in throw CoreCallError.failed("denied") }
        )
        await store.add(chatID: chatID, name: "Nope")
        XCTAssertNotNil(store.manageError[chatID])
        XCTAssertTrue(store.tabs(for: chatID).isEmpty)
    }

    func testChatManageIgnoresNonChatIDs() async throws {
        let store = ChatTabsStore(
            add: { _, name, _, _ in TabManageResponse(ok: true, tab: ChannelTab(id: "c1", name: name)) },
            rename: { _, id, name in TabManageResponse(ok: true, tab: ChannelTab(id: id, name: name)) },
            remove: { _, tab in TabRemoveResponse(ok: true, tabId: tab) }
        )
        // Channel ids carry no chat tabs; non-19 ids never fetch.
        await store.add(chatID: "19:abc@thread.tacv2", name: "Nope")
        await store.add(chatID: "48:notes", name: "Nope")
        XCTAssertTrue(store.byChat.isEmpty)
    }
}
