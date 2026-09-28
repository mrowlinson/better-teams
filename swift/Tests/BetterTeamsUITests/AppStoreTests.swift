// AppStoreTests.swift — APPHOST-B2: Teams deep link parsing, channel tab
// → catalog app matching, store routes, navigateToApp link building and
// the demo store (install stays in memory).
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class AppStoreTests: XCTestCase {
    func testDeepLinksParse() {
        func p(_ s: String) -> TeamsDeepLink? { TeamsDeepLink.parse(URL(string: s)!) }
        let ctx = "%7B%22subEntityId%22%3A%22task-9%22%2C%22channelId%22%3A%2219%3Aabc%40thread.tacv2%22%7D"
        XCTAssertEqual(p("https://teams.microsoft.com/l/entity/app-1/home?context=\(ctx)"),
                       .entity(appID: "app-1", entityID: "home", subEntityID: "task-9",
                               channelID: "19:abc@thread.tacv2"))
        XCTAssertEqual(p("https://teams.microsoft.com/_#/l/entity/app-1/home"),
                       .entity(appID: "app-1", entityID: "home", subEntityID: nil, channelID: nil))
        XCTAssertEqual(p("https://teams.microsoft.com/l/chat/19:c1@thread.v2/conversations"),
                       .chat(chatID: "19:c1@thread.v2", users: []))
        XCTAssertEqual(p("https://teams.microsoft.com/l/chat/0/0?users=a@x.com,b@x.com"),
                       .chat(chatID: nil, users: ["a@x.com", "b@x.com"]))
        XCTAssertEqual(p("https://teams.microsoft.com/l/message/19:t@thread.tacv2/1700?parentMessageId=1600"),
                       .message(threadID: "19:t@thread.tacv2", messageID: "1700", parentMessageID: "1600"))
        XCTAssertEqual(p("https://teams.microsoft.com/l/team/19:g@thread.tacv2/conversations?groupId=G1"),
                       .team(threadID: "19:g@thread.tacv2", groupID: "G1"))
        XCTAssertEqual(p("https://teams.microsoft.com/l/channel/19:ch@thread.tacv2/General?groupId=G1"),
                       .channel(threadID: "19:ch@thread.tacv2", name: "General", groupID: "G1"))
        if case .meetupJoin = p("https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0") {} else {
            XCTFail("meetup-join")
        }
        XCTAssertNil(p("https://teams.microsoft.com/l/unknown/x"))
        XCTAssertNil(p("https://evil.example.com/l/chat/19:c1@thread.v2/conversations"))
        XCTAssertNil(p("https://teams.microsoft.com.evil.example/l/chat/1/2"))
    }

    func testNavigateToAppBuildsEntityLink() throws {
        let raw = try XCTUnwrap(TeamsJSHost.linkArg("pages.navigateToApp",
                                                    [["appId": "app-1", "pageId": "home", "subPageId": "s1"]]))
        XCTAssertEqual(TeamsDeepLink.parse(URL(string: raw)!),
                       .entity(appID: "app-1", entityID: "home", subEntityID: "s1", channelID: nil))
        XCTAssertEqual(TeamsJSHost.linkArg("openLink", ["https://example.com"]), "https://example.com")
    }

    func testChannelTabMatchesCatalogApp() {
        let store = AppStoreModel(accountKey: "demo")
        let team = TeamItem(teamId: "T1", name: "Marketing", channels: [])
        let channel = TeamChannel(channelId: "19:c@thread.tacv2", name: "Launch")
        // By teamsAppId.
        let byID = ChannelTab(id: "t1", name: "Board", appID: DemoAppStore.sprintBoardID,
                              contentURL: "https://other.example/x", entityID: "e1")
        let l = store.launch(forTab: byID, team: team, channel: channel)
        XCTAssertEqual(l?.appID, DemoAppStore.sprintBoardID)
        XCTAssertEqual(l?.entityID, "e1")
        XCTAssertEqual(l?.channel?.channelID, "19:c@thread.tacv2")
        XCTAssertTrue(l?.validDomains.contains("other.example") ?? false)
        // By content host vs validDomains; placeholders in the template.
        let byHost = ChannelTab(id: "t2", name: "Board",
                                contentURL: "https://sprintboard.northwind.example/tab?c={channelId}")
        XCTAssertEqual(store.app(forTab: byHost)?.id, DemoAppStore.sprintBoardID)
        // Unmatched and standalone hosts keep the Teams-shell page.
        XCTAssertNil(store.app(forTab: ChannelTab(id: "t3", name: "X", contentURL: "https://unknown.example/")))
        XCTAssertNil(store.app(forTab: ChannelTab(id: "t4", name: "Wiki",
                                                  contentURL: "https://contoso.sharepoint.com/x")))
        XCTAssertTrue(AppStoreModel.domain("*.northwind.example", matches: "sprintboard.northwind.example"))
        XCTAssertFalse(AppStoreModel.domain("*.northwind.example", matches: "northwind.example.evil.com"))
    }

    func testStoreRoutesAndDemoInstallStayLocal() {
        let section = AppsSection()
        XCTAssertEqual(section.selection(for: Route(path: ["apps", "detail"], query: ["id": "demo-app-forms"])),
                       AppStoreRoute.detail("demo-app-forms"))
        XCTAssertEqual(AppStoreRoute.page(AppStoreRoute.detail("x")), .detail("x"))
        XCTAssertEqual(AppStoreRoute.page(nil), .home(category: nil))
        XCTAssertEqual(AppStoreRoute.page(AppStoreRoute.category("Finance")), .home(category: "Finance"))
        XCTAssertNil(AppStoreRoute.page(SectionSelection(["web-demo"])))

        let lib = AppsLibrary(accountKey: "demo")
        XCTAssertTrue(lib.store.isInstalled(DemoAppStore.plannerID))
        XCTAssertNotNil(lib.hostedApp(forCatalogApp: DemoAppStore.plannerID))
        let forms = try? XCTUnwrap(lib.store.manifest("demo-app-forms"))
        XCTAssertFalse(lib.store.isInstalled("demo-app-forms"))
        lib.store.install(forms!)
        XCTAssertTrue(lib.store.isInstalled("demo-app-forms"))
        XCTAssertNotNil(lib.hostedApp(forCatalogApp: "demo-app-forms"))
        XCTAssertEqual(lib.store.shelves.first?.title, "Installed")
    }
}
