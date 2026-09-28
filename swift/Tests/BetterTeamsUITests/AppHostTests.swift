// AppHostTests.swift — APPHOST phase 1: native TeamsJS host rules
// (placeholders, validDomains navigation, getAuthToken resource), the
// catalog → library mapping, and the demo sample app's end-to-end
// handshake (initialize, getContext, getAuthToken, NAA) in a real
// WKWebView with no network.
import AppKit
import WebKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class AppHostTests: XCTestCase {
    private func launch(resource: String? = nil, domains: [String] = ["tasks.example.com", "*.contoso.com"],
                        transport: TeamsJSTransport = .frameless) -> TeamsAppLaunch {
        TeamsAppLaunch(appID: "app-1", entityID: "home",
                       contentTemplate: "https://tasks.example.com/tab/{tid}?l={locale}&u={userObjectId}&x={nope}",
                       fallback: TeamsAppLaunch.teamsEntityURL(appID: "app-1", entityID: "home"),
                       resource: resource, validDomains: domains, transport: transport)
    }

    func testPlaceholdersExpandEncodedInOnePass() {
        var c = TeamsJSAppContext()
        c.tenantId = "t-1"
        c.locale = "en-us"
        c.userObjectId = "a&b={tid}"
        let out = TeamsJSPolicy.expand(launch().contentTemplate, c)
        XCTAssertEqual(out, "https://tasks.example.com/tab/t-1?l=en-us&u=a%26b%3D%7Btid%7D&x=")
        XCTAssertEqual(TeamsJSPolicy.expand("https://x.example.com/{open", c), "https://x.example.com/{open")
        XCTAssertEqual(TeamsJSPolicy.expand("{ENTITYID}", { var c = c; c.entityId = "e"; return c }()), "e")
    }

    func testNavigationFollowsValidDomains() {
        let l = launch()
        let ok = ["https://tasks.example.com/next", "https://a.contoso.com/x", "https://login.microsoftonline.com/common",
                  "about:blank"]
        let no = ["https://contoso.com/", "https://evil.example.net/", "https://teams.microsoft.com/", "file:///etc/hosts"]
        for u in ok { XCTAssertTrue(TeamsJSPolicy.allowsNavigation(URL(string: u)!, launch: l), u) }
        for u in no { XCTAssertFalse(TeamsJSPolicy.allowsNavigation(URL(string: u)!, launch: l), u) }
        XCTAssertTrue(TeamsJSPolicy.allowsNavigation(URL(string: "https://teams.microsoft.com/")!,
                                                     launch: launch(transport: .iframe)))
        XCTAssertTrue(TeamsJSPolicy.domainMatches(host: "tasks.example.com", pattern: "https://tasks.example.com:443/p"))
        XCTAssertFalse(TeamsJSPolicy.domainMatches(host: "example.com", pattern: "*."))
    }

    func testAuthResourceIsManifestOrValidDomainOnly() {
        XCTAssertEqual(TeamsJSPolicy.authResource(requested: ["https://graph.microsoft.com"],
                                                  launch: launch(resource: "api://tasks.example.com/abc")),
                       "api://tasks.example.com/abc")
        XCTAssertEqual(TeamsJSPolicy.authResource(requested: ["https://graph.microsoft.com", "https://x.contoso.com"],
                                                  launch: launch()), "https://x.contoso.com")
        XCTAssertNil(TeamsJSPolicy.authResource(requested: ["https://graph.microsoft.com"], launch: launch()))
        XCTAssertNil(TeamsJSPolicy.authResource(requested: [], launch: launch()))
    }

    func testIframeHostRepliesToAppOriginOnly() {
        let html = TeamsJSHost.iframeHostHTML(src: URL(string: "https://tasks.example.com:8443/tab?a=1&b=\"2\"")!)
        XCTAssertTrue(html.contains("o = \"https://tasks.example.com:8443\""))
        XCTAssertFalse(html.contains("'*')"))
        XCTAssertTrue(html.contains("?a=1&amp;b="))
    }

    func testCatalogDecodesAndMapsToPersonalApps() throws {
        let json = """
        {"ok":true,"pinned":["B-APP","a-app","no-tab"],"entitlements":[],"apps":[
         {"id":"a-app","name":"Alpha","static_tabs":[{"entity_id":"conversations","name":"Chat","content_url":null,
           "website_url":null,"scopes":["personal"]},{"entity_id":"home","name":"Home",
           "content_url":"https://a.example.com/t?tid={tid}","website_url":null,"scopes":["personal"]}],
          "configurable_tabs":[],"web_application_info":{"id":"w","resource":"api://a.example.com/w"},
          "valid_domains":["a.example.com"]},
         {"id":"b-app","name":"Beta","static_tabs":[{"entity_id":"main","name":"Main",
           "content_url":"https://b.example.com/","website_url":null,"scopes":[]}],"configurable_tabs":[],
          "web_application_info":null,"valid_domains":[]},
         {"id":"no-tab","name":"Bot Only","static_tabs":[],"configurable_tabs":[],"web_application_info":null,
          "valid_domains":[]}]}
        """
        let r = try JSONDecoder().decode(TeamsAppCatalogResponse.self, from: Data(json.utf8))
        let entry = TeamsAppCatalogCache.Entry(pinned: r.pinned, apps: r.apps)
        let apps = AppsLibrary.apps(from: entry)
        XCTAssertEqual(apps.map(\.id), ["ta.b-app", "ta.a-app"], "hostable only, app bar order")
        guard case .teamsApp(let l) = apps[1].launch else { return XCTFail("not hosted") }
        XCTAssertEqual(l.entityID, "home")
        XCTAssertEqual(l.resource, "api://a.example.com/w")
        XCTAssertEqual(l.fallback.absoluteString, "https://teams.microsoft.com/_#/l/entity/a-app/home")
        XCTAssertEqual(AppsLibrary.pinnedIDs(entry), ["ta.b-app", "ta.a-app"])
        XCTAssertTrue(CoreTokenBroker.isTransient("token endpoint unreachable: error sending request"))
        XCTAssertFalse(CoreTokenBroker.isTransient("token grant failed (HTTP 400): invalid_grant"))
    }

    /// Demo sample app in a real web view: the page speaks TeamsJS to
    /// the native host and shows both token paths succeeding.
    func testDemoSampleAppHandshakeEndToEnd() async throws {
        for app in DemoTeamsJSApp.apps {
            let host = FrameHost(accountKey: "demo")
            host.registerApp(app)
            let key = FrameKey.app(app.id)
            XCTAssertTrue(host.isNativelyHosted(key))
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            host.attach(key, to: container)
            let web = try XCTUnwrap(host.webView(key))
            var text = ""
            let deadline = Date().addingTimeInterval(15)
            let probe = "(document.querySelector('iframe') ? document.querySelector('iframe').contentDocument.body.innerText : document.body.innerText)"
            while Date() < deadline {
                text = (try? await web.evaluateJavaScript(probe)) as? String ?? ""
                if text.components(separatedBy: "Token received").count == 3 { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertTrue(text.contains("Connected"), "\(app.id): \(text.prefix(300))")
            XCTAssertTrue(text.contains("alex.morgan@contoso.example"), app.id)
            XCTAssertEqual(text.components(separatedBy: "Token received").count, 3, "\(app.id): \(text.prefix(400))")
            host.unload(key)
        }
    }
}
