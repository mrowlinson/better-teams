// NoTeamsWebTests.swift — APPNATIVE4: no app, tab, file or link route
// resolves to the Teams web app ("we should never be loading the full
// webapp"). Every route either hosts the app's own page natively, loads
// the tab's own page, or shows a native pane; a Teams address never
// becomes a page.
import AppKit
import XCTest
import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class NoTeamsWebTests: XCTestCase {
    private let teamsURLs = [
        "https://teams.microsoft.com/_#/l/entity/app/home",
        "https://teams.microsoft.com/l/entity/f/x?context=%7B%7D",
        "https://teams.cloud.microsoft/l/app/abc",
        "https://teams.live.com/l/chat/0/0",
        "https://gov.teams.microsoft.us/l/channel/19:x/General",
    ]

    func testGuardMatchesEveryTeamsWebHostOnly() {
        for raw in teamsURLs { XCTAssertTrue(TeamsWebGuard.isTeamsWeb(URL(string: raw)!), raw) }
        for raw in ["https://contoso.sharepoint.com/", "https://tasks.office.com/x", "https://login.microsoftonline.com/",
                    "https://example.com/teams.microsoft.com",
            // App pages Microsoft hosts on the Teams hosts are apps, not the web app.
            "https://teams.cloud.microsoft/shifts-web-app/?tid=1", "https://flw.teams.microsoft.com/tab/home"] {
            XCTAssertFalse(TeamsWebGuard.isTeamsWeb(URL(string: raw)!), "control: \(raw)")
        }
        for raw in ["https://teams.microsoft.com", "https://teams.microsoft.com/", "https://teams.microsoft.com/v2/",
                    "https://teams.microsoft.com/_#/conversations", "https://teams.microsoft.com/dl/launcher/launcher.html"] {
            XCTAssertTrue(TeamsWebGuard.isTeamsWeb(URL(string: raw)!), raw)
        }
        XCTAssertTrue(ChatTabCatalog.isTeamsTemplate("https://teams.microsoft.com/l/entity/{appId}/{entityId}"))
        XCTAssertTrue(ChatTabCatalog.isTeamsTemplate("https://teams.microsoft.com:443/_#/tab"))
        XCTAssertTrue(ChatTabCatalog.isTeamsTemplate("https://teams.microsoft.com?x=1"))
        XCTAssertFalse(ChatTabCatalog.isTeamsTemplate("https://teams.cloud.microsoft/shifts-web-app?tid={tid}"), "control")
        XCTAssertFalse(ChatTabCatalog.isTeamsTemplate("https://{teamSiteDomain}/l/x"), "control")
    }

    /// Links and web links: a Teams address is a link, never a page; a
    /// registered one stays unloaded with its native explanation.
    func testTeamsLinksNeverBecomePages() throws {
        let host = FrameHost(accountKey: "demo")
        for (i, raw) in teamsURLs.enumerated() {
            let launch = try XCTUnwrap(FramePolicy.launch(url: raw), raw)
            guard case .teamsLink = launch else { return XCTFail("\(raw) → \(launch)") }
            let app = FrameApp(id: "nt.\(i)", label: "L\(i)", symbol: "link", source: .webLink, launch: launch)
            host.registerApp(app)
            host.attach(.app(app.id), to: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200)))
            let page = try XCTUnwrap(host.page(.app(app.id)))
            XCTAssertFalse(TeamsWebGuard.isTeamsWeb(page.url), raw)
            XCTAssertNotEqual(host.webView(.app(app.id))?.url.map(TeamsWebGuard.isTeamsWeb), true, raw)
            guard case .failed = page.state else { return XCTFail("\(raw): \(page.state)") }
            // A web tab registered with a Teams address: the same.
            host.registerTab(.tab("nt-\(i)"), url: URL(string: raw)!, title: "T\(i)")
            XCTAssertFalse(TeamsWebGuard.isTeamsWeb(try XCTUnwrap(host.page(.tab("nt-\(i)"))).url), raw)
        }
        guard case .direct = try XCTUnwrap(FramePolicy.launch(url: "https://contoso.sharepoint.com/sites/x")) else {
            return XCTFail("control: a standalone page loads directly")
        }
    }

    /// Chat and channel tabs (apps, Office files, whiteboards, websites):
    /// hosted natively, their own page, or a native placeholder, never a
    /// Teams page, with or without a catalog manifest.
    func testTabRoutesNeverResolveToTeamsWeb() throws {
        let json = """
            {"ok":true,"chat_id":"19:abc@thread.v2","tabs":[\
            {"id":"a","name":"Board","app_id":"3p","content_url":"https://teams.microsoft.com/l/entity/3p/board",\
            "website_url":"https://teams.microsoft.com/l/entity/3p/board","teams_url":"https://teams.microsoft.com/l/entity/3p/board"},\
            {"id":"f","name":"Budget.xlsx","app_id":"com.microsoft.teamspace.tab.file.staticviewer.excel",\
            "teams_url":"https://teams.microsoft.com/l/entity/f"},\
            {"id":"w","name":"Site","app_id":"com.microsoft.teamspace.tab.web","content_url":"https://teams.live.com/v2/x",\
            "teams_url":"https://teams.microsoft.com/l/entity/w"},\
            {"id":"ok","name":"Reminders","app_id":"3p","content_url":"https://example.com/r",\
            "teams_url":"https://teams.microsoft.com/l/entity/ok"}]}
            """
        let tabs = try JSONDecoder().decode(TabsResponse.self, from: Data(json.utf8)).tabs
        for t in tabs {
            for manifest in [true, false] {
                let route = ChatTabCatalog.route(for: t, hasManifest: manifest)
                if case .web(let u) = route { XCTAssertFalse(TeamsWebGuard.isTeamsWeb(u), "\(t.id) \(u)") }
                if t.id != "ok" { XCTAssertEqual(route, .placeholder, "\(t.id) manifest=\(manifest)") }
            }
        }
        XCTAssertEqual(ChatTabCatalog.route(for: tabs[3], hasManifest: true), .hosted, "control")
        XCTAssertFalse(AppStoreModel.hostableTabPage("https://teams.microsoft.com/l/entity/x/{entityId}"))
        XCTAssertTrue(AppStoreModel.hostableTabPage("https://{teamSiteDomain}/_layouts/15/x"), "control")

        // A hosted tab whose manifest content is a Teams page never loads it.
        let host = FrameHost(accountKey: "demo")
        host.registerHostedTab(.tab("nt-hosted"), launch: TeamsAppLaunch(
            appID: "nt-hosted", entityID: "e", contentTemplate: "https://teams.microsoft.com/_#/tab/{entityId}"), title: "H")
        XCTAssertFalse(TeamsWebGuard.isTeamsWeb(try XCTUnwrap(host.page(.tab("nt-hosted"))).url))
    }

    /// Catalog apps: the launch URL is the app's own content page.
    func testManifestAppsLaunchTheirOwnPage() throws {
        let json = """
        {"ok":true,"pinned":["a"],"entitlements":[],"apps":[
         {"id":"a","name":"Alpha","static_tabs":[{"entity_id":"home","name":"Home",
           "content_url":"https://a.example.com/t?tid={tid}","website_url":null,"scopes":["personal"]}],
          "configurable_tabs":[],"web_application_info":null,"valid_domains":[]}]}
        """
        let r = try JSONDecoder().decode(TeamsAppCatalogResponse.self, from: Data(json.utf8))
        for app in AppsLibrary.apps(from: TeamsAppCatalogCache.Entry(pinned: r.pinned, apps: r.apps)) {
            XCTAssertFalse(TeamsWebGuard.isTeamsWeb(app.launch.url), app.id)
            guard case .teamsApp = app.launch else { return XCTFail(app.id) }
        }
    }

    /// Session-only Microsoft sign-in cookies are kept past quit (zero
    /// second login without "Stay signed in"); other cookies are not.
    func testWebSessionKeeperPersistsOnlySessionLoginCookies() throws {
        func cookie(_ domain: String, expires: Date? = nil) -> HTTPCookie {
            var p: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: "/", .name: "n", .value: "v", .secure: "TRUE"]
            if let expires { p[.expires] = expires }
            return HTTPCookie(properties: p)!
        }
        let session = cookie("login.microsoftonline.com")
        XCTAssertTrue(session.isSessionOnly)
        XCTAssertTrue(WebSessionKeeper.needsKeeping(session))
        XCTAssertTrue(WebSessionKeeper.needsKeeping(cookie(".login.microsoftonline.com")))
        let kept = try XCTUnwrap(WebSessionKeeper.persistent(session, now: Date(timeIntervalSince1970: 0)))
        XCTAssertFalse(kept.isSessionOnly)
        XCTAssertEqual(kept.expiresDate, Date(timeIntervalSince1970: WebSessionKeeper.lifetime))
        XCTAssertEqual(kept.domain, session.domain)
        XCTAssertTrue(kept.isSecure)
        XCTAssertFalse(WebSessionKeeper.needsKeeping(kept), "already persistent")
        XCTAssertFalse(WebSessionKeeper.needsKeeping(cookie("contoso.sharepoint.com")), "control: other hosts")
        XCTAssertFalse(WebSessionKeeper.needsKeeping(cookie("evil-login.microsoftonline.com.example")), "control: lookalike")
    }
}
