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
                  "about:blank", "https://contoso.sharepoint.com/sites/x/Doc.aspx", "https://loop.cloud.microsoft/p/x"]
        let no = ["https://contoso.com/", "https://evil.example.net/", "https://teams.microsoft.com/", "file:///etc/hosts",
                  "http://contoso.sharepoint.com/", "https://sharepoint.com.evil.example.net/"]
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
        XCTAssertEqual(apps[1].launch.url.host, "a.example.com", "its own page, never the Teams web app")
        XCTAssertFalse(TeamsWebGuard.isTeamsWeb(apps[1].launch.url))
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

    /// No Teams web page (APPNATIVE4): every mode runs the app natively,
    /// a saved Teams Page choice reads as Automatic, and an app that
    /// fails shows its reason in its own pane, never another page.
    func testFailureStaysInPaneNeverTeamsWeb() async throws {
        var unverified = launch()
        unverified.appID = "b3-unverified"
        XCTAssertEqual(TeamsJSTransportChoice.resolve(unverified, demo: true), .frameless, "own sign-in app runs natively")
        TeamsJSTransportChoice.setMode(.iframe, app: unverified.appID, demo: true)
        XCTAssertEqual(TeamsJSTransportChoice.resolve(unverified, demo: true), .iframe, "control: a forced mode applies")
        TeamsJSTransportChoice.setMode(.automatic, app: unverified.appID, demo: true)
        XCTAssertNil(TeamsJSHostMode(rawValue: "teamsWeb"), "no Teams Page mode")

        XCTAssertEqual(TeamsJSPolicy.signInFailure(URL(string: "https://a.example.com/cb#error=consent_required&error_description=AADSTS65001%3a+The+user")!),
                       "sign-in error AADSTS65001")
        XCTAssertNil(TeamsJSPolicy.signInFailure(URL(string: "https://a.example.com/cb?code=abc")!), "control")
        XCTAssertFalse(TeamsJSPolicy.isFailure("appInitialization.expectedFailure", reason: "Offline"))

        // A native (demo) page that reports a failure keeps its pane and
        // says why, with Retry; its address is still its own page.
        let host = FrameHost(accountKey: "demo")
        var failing = launch()
        failing.appID = "b3-failing"
        failing.demoHTML = "<html><body>x<script>window.nativeInterface.framelessPostMessage(JSON.stringify({id: 1, func: 'appInitialization.failure', args: ['Other', 'x']}));</script></body></html>"
        let fkey = FrameKey.app("b3-failing")
        host.registerApp(FrameApp(id: "b3-failing", label: "F", symbol: "app", source: .personal, launch: .teamsApp(failing)))
        XCTAssertTrue(host.isNativelyHosted(fkey), "control: demo app starts natively")
        host.attach(fkey, to: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        func failedMessage() -> String? {
            if case .failed(let m, _) = host.page(fkey)?.state { return m }
            return nil
        }
        let deadline = Date().addingTimeInterval(10)
        while failedMessage() == nil, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(failedMessage(), "The app reported a problem: Other.")
        XCTAssertEqual(host.hostFailure(appID: "b3-failing"), "app reported Other")
        XCTAssertTrue(host.isNativelyHosted(fkey), "still the native host")
        let url = try XCTUnwrap(host.page(fkey)?.url)
        XCTAssertFalse(TeamsWebGuard.isTeamsWeb(url), url.absoluteString)
        XCTAssertEqual(url.host, "tasks.example.com")
        host.unload(fkey)
    }

    /// APPHOST-B3 B/C/D/F: SharePoint placeholders fill host/path raw
    /// before the query and encoded after; resources and validDomains
    /// resolve; consent page; realm discovery; channel-tab link refs.
    func testSitePlaceholdersConsentRealmAndTabLinks() throws {
        var c = TeamsJSAppContext()
        c.teamSiteDomain = "contoso.sharepoint.com"
        c.teamSitePath = "/sites/Team A"
        c.teamSiteUrl = "https://contoso.sharepoint.com/sites/Team A"
        c.channelName = "General"
        c.locale = "en-us"
        let url = TeamsJSPolicy.expand("https://{teamSiteDomain}{teamSitePath}/_layouts/15/x.aspx?u={teamSiteUrl}&c={channelName}&l={locale}", c)
        XCTAssertEqual(url, "https://contoso.sharepoint.com/sites/Team%20A/_layouts/15/x.aspx?u=https:%2F%2Fcontoso.sharepoint.com%2Fsites%2FTeam%20A&c=General&l=en-us")
        var l = launch(resource: "https://{teamSiteDomain}\u{200B}", domains: ["{teamSiteDomain}", "*.example.com"])
        l.contentTemplate = "https://{teamSiteDomain}/_layouts/15/teamslogon.aspx"
        XCTAssertTrue(TeamsJSPolicy.needsSite(l))
        XCTAssertFalse(TeamsJSPolicy.needsSite(launch()), "control")
        let r = TeamsJSPolicy.resolved(l, c)
        XCTAssertEqual(r.resource, "https://contoso.sharepoint.com")
        XCTAssertEqual(r.validDomains, ["contoso.sharepoint.com", "*.example.com"])
        XCTAssertEqual(TeamsJSPolicy.mySitePath("https://contoso-my.sharepoint.com/personal/a_b_com/Documents"), "/personal/a_b_com")
        XCTAssertEqual(TeamsJSPolicy.siteParts("https://contoso.sharepoint.com/sites/X/").path, "/sites/X")

        let consent = try XCTUnwrap(TeamsJSPolicy.consentURL(resource: "api://cal.example.com/abc", tenant: "t1", loginHint: "a@b.example"))
        let q = URLComponents(url: consent, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(consent.host, "login.microsoftonline.com")
        XCTAssertEqual(consent.path, "/t1/oauth2/v2.0/authorize")
        XCTAssertEqual(q.first { $0.name == "scope" }?.value, "api://cal.example.com/abc/.default")
        XCTAssertEqual(q.first { $0.name == "prompt" }?.value, "consent")
        XCTAssertTrue(TeamsJSPolicy.needsConsent("token grant failed (HTTP 400): invalid_grant AADSTS65001: The user"))
        XCTAssertFalse(TeamsJSPolicy.needsConsent("AADSTS50076"), "control")

        let fed = Data(#"{"NameSpaceType":"Federated","AuthURL":"https://sts.contoso.example/adfs/ls/?username=x"}"#.utf8)
        XCTAssertEqual(TeamsJSPolicy.federatedHost(realmJSON: fed), "sts.contoso.example")
        XCTAssertNil(TeamsJSPolicy.federatedHost(realmJSON: Data(#"{"NameSpaceType":"Managed"}"#.utf8)), "control")
        let sts = URL(string: "https://sts.contoso.example/adfs/ls/")!
        XCTAssertTrue(TeamsJSPolicy.allowsNavigation(sts, launch: launch(), signInHosts: ["sts.contoso.example"]))
        XCTAssertFalse(TeamsJSPolicy.allowsNavigation(sts, launch: launch()), "control: not without the realm")

        XCTAssertEqual(TeamsDeepLink.tabRef("tab::1a2b-3c"), "1a2b-3c")
        XCTAssertNil(TeamsDeepLink.tabRef("General"), "control")
    }

    // MARK: APPNATIVE2

    /// v2 dotted placeholders (Copilot, Engage, Calendar), a JSON literal
    /// in OneDrive's query kept verbatim, a zero-width space inside a
    /// key (Visio), `{sourceOrigin}` and `{sharePointDomains}`.
    func testDottedPlaceholdersJSONLiteralAndSharePointDomains() throws {
        var c = TeamsJSAppContext()
        c.tenantId = "t-1"
        c.userObjectId = "u-1"
        c.mySiteDomain = "contoso-my.sharepoint.com"
        c.teamSiteDomain = "contoso.sharepoint.com"
        XCTAssertEqual(TeamsJSPolicy.expand("https://o.example.com/c/'OID:{user.id}@{user.tenant.id}'?h={app.host.name}&k={app.host.clientType}", c),
                       "https://o.example.com/c/'OID:u-1@t-1'?h=Teams&k=desktop")
        XCTAssertEqual(TeamsJSPolicy.expand("https://x.example.com/?u={userObjectId}&fb={\"sdk\":\"1.0\",\"e\":{}}", c),
                       "https://x.example.com/?u=u-1&fb={\"sdk\":\"1.0\",\"e\":{}}", "JSON literal kept")
        XCTAssertEqual(TeamsJSPolicy.expand("https://{\u{200B}\u{200B}teamSiteDomain}\u{200B}/", c, encode: false),
                       "https://contoso.sharepoint.com/")
        XCTAssertEqual(TeamsJSPolicy.expand("?s={sourceOrigin}", c), "?s=https:%2F%2Fteams.microsoft.com")
        XCTAssertEqual(TeamsJSPolicy.expand("?x={nope}", c), "?x=", "control: unknown names still empty")
        let sp = TeamsJSPolicy.resolved(launch(domains: ["{sharePointDomains}", "securebroker.example.com"]), c)
        XCTAssertEqual(sp.validDomains, ["contoso.sharepoint.com", "contoso-my.sharepoint.com", "securebroker.example.com"])
        XCTAssertTrue(TeamsJSPolicy.needsSite(launch(domains: ["{sharePointDomains}"])))
    }

    /// One host for every app (APPNATIVE3/4): Automatic runs any app
    /// natively, whatever it signs in with; nothing resolves to the
    /// Teams web page.
    func testEveryAppRunsNativelyByDefault() {
        func l(_ id: String, _ content: String, resource: String? = nil, webApp: String? = nil) -> TeamsAppLaunch {
            TeamsAppLaunch(appID: id, entityID: "e", contentTemplate: content,
                           resource: resource, webAppID: webApp)
        }
        let shifts = l("an3-shifts", "https://flw.example.com/app?tid={tid}", resource: "https://api.example.com")
        let planner = l("an3-planner", "https://tasks.example.com/{tid}", webApp: "75efb5bc")
        let oneDrive = l("an3-od", "https://{mySiteDomain}{mySitePath}/_layouts/15/fb.aspx", resource: "https://{mySiteDomain}")
        let word = l("an3-word", "https://m365.example.com/launch/word?s={sourceOrigin}", resource: "https://{teamSiteDomain}")
        let polly = l("an3-polly", "https://polly.example.com/tab?theme={theme}")
        let forms = l("81FEF3A6-72AA-4648-A763-DE824AEAFB7D", "https://forms.example.com/", resource: "https://forms.example.com")
        for app in [shifts, planner, oneDrive, word, polly, forms] {
            XCTAssertEqual(TeamsJSTransportChoice.resolve(app, demo: true), .frameless, app.appID)
        }
        TeamsJSTransportChoice.setUsesWebsite(true, app: word.appID, demo: true)
        XCTAssertEqual(TeamsJSTransportChoice.resolve(word, demo: true), .frameless, "a website stand-in is still native")
        TeamsJSTransportChoice.forgetFailure(app: word.appID, demo: true)
        XCTAssertFalse(TeamsJSTransportChoice.usesWebsite(word.appID, demo: true), "Try Again retries the Teams page too")
    }

    /// The runtime version matches the app's TeamsJS (APPNATIVE4): an
    /// older SDK throws on a newer runtime and never starts.
    func testRuntimeVersionFollowsAppSDK() throws {
        XCTAssertEqual(TeamsJSHost.runtimeAPIVersion(sdk: "2.19.0"), 3, "Polly's SDK")
        XCTAssertEqual(TeamsJSHost.runtimeAPIVersion(sdk: "2.20.0"), 4)
        XCTAssertEqual(TeamsJSHost.runtimeAPIVersion(sdk: "2.34.1"), 4)
        XCTAssertEqual(TeamsJSHost.runtimeAPIVersion(sdk: "2.14.0"), 2)
        XCTAssertEqual(TeamsJSHost.runtimeAPIVersion(sdk: "2.7.1"), 1)
        XCTAssertEqual(TeamsJSHost.runtimeAPIVersion(sdk: "1.12.0"), 1)
        XCTAssertEqual(TeamsJSHost.runtimeAPIVersion(sdk: "3.0.0-beta"), 4)
        XCTAssertEqual(TeamsJSHost.runtimeAPIVersion(sdk: ""), 4, "control: unknown = latest")
    }

    /// The app's own web page stands in for a blank embedded page only on
    /// the content page's host, over https, and when it is another page.
    func testWebsiteStandInIsSameHostOnly() {
        var c = TeamsJSAppContext()
        c.mySiteDomain = "contoso-my.sharepoint.com"
        var l = TeamsAppLaunch(appID: "an3-web", entityID: "e",
                               contentTemplate: "https://{mySiteDomain}/_layouts/15/fb.aspx?app=teams",
                               website: "https://{mySiteDomain}")
        XCTAssertEqual(TeamsJSPolicy.websiteURL(l, c)?.absoluteString, "https://contoso-my.sharepoint.com")
        l.websiteTemplate = "https://www.example.com/product"
        XCTAssertNil(TeamsJSPolicy.websiteURL(l, c), "vendor site on another host")
        l.websiteTemplate = "http://{mySiteDomain}/"
        XCTAssertNil(TeamsJSPolicy.websiteURL(l, c), "not https")
        l.websiteTemplate = l.contentTemplate
        XCTAssertNil(TeamsJSPolicy.websiteURL(l, c), "same page")
        l.websiteTemplate = nil
        XCTAssertNil(TeamsJSPolicy.websiteURL(l, c), "control: none")
    }

    /// SharePoint hosts of a resolved launch, and the session cookies
    /// kept from SharePoint's answer (its own domain only).
    func testSharePointSessionHostsAndCookies() throws {
        var od = launch(resource: "https://contoso-my.sharepoint.com",
                        domains: ["contoso-my.sharepoint.com", "*.sharepoint.com", "tasks.example.com"])
        od.contentTemplate = "https://contoso-my.sharepoint.com/personal/a/_layouts/15/fb.aspx"
        XCTAssertEqual(SharePointSession.hosts(for: od, content: URL(string: od.contentTemplate)), ["contoso-my.sharepoint.com"])
        XCTAssertEqual(SharePointSession.hosts(for: launch(), content: URL(string: "https://tasks.example.com/")), [],
                       "control: not SharePoint")
        let req = try XCTUnwrap(SharePointSession.request(host: "contoso.sharepoint.com", token: "t"))
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/_api/SP.OAuth.NativeClient/Authenticate")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        let resp = try XCTUnwrap(HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Set-Cookie": "SPOIDCRL=abc; path=/; secure; HttpOnly, evil=1; domain=.example.com; path=/",
        ]))
        let cookies = SharePointSession.cookies(from: resp, host: "contoso.sharepoint.com")
        XCTAssertEqual(cookies.map(\.name), ["SPOIDCRL"], "the other domain's cookie is dropped")
    }

    /// Shifts' start in a real web view: TeamsJS throws "not supported"
    /// unless the runtime advertises joined teams; the host answers
    /// getUserJoinedTeams and webStorage; an unknown API stays unanswered.
    func testJoinedTeamsAndStartCapabilitiesAnswered() async throws {
        let page = """
        <html><body><div id=o>start</div><script>
        var o=document.getElementById('o'), n=0, cb={};
        window.onNativeMessage=function(e){var m=e.data; if(cb[m.id]){var k=cb[m.id]; delete cb[m.id]; k(m.args);}};
        function send(f,a,k){n++; cb[n]=k; window.nativeInterface.framelessPostMessage(JSON.stringify({id:n,func:f,args:a||[]}));}
        send('initialize',['2.23.0'],function(a){
          var s=JSON.parse(a[3]).supports||{};
          if(!(s.teams&&s.teams.fullTrust&&s.teams.fullTrust.joinedTeams&&s.menus)){o.textContent='unsupported';return;}
          send('getUserJoinedTeams',[],function(r){
            o.textContent=(r&&r[0]&&Array.isArray(r[0].userJoinedTeams))?'joined ok':'bad reply';
            send('webStorage.isWebStorageClearedOnUserLogOut',[],function(w){o.textContent+=(w[0]===false?' storage ok':' storage bad');
              send('authentication.getUser',[],function(u){o.textContent+=(u[0]===true&&u[1]&&u[1].upn&&u[1].tid?' user ok':' user bad');});
            });
            send('an2.unknownApi',[],function(){o.textContent+=' unknown answered';});
          });
        });
        </script></body></html>
        """
        var l = launch(resource: "https://tasks.example.com")
        l.appID = "an2-joined"
        l.demoHTML = page
        let host = FrameHost(accountKey: "demo")
        let key = FrameKey.app(l.appID)
        host.registerApp(FrameApp(id: l.appID, label: "J", symbol: "app", source: .personal, launch: .teamsApp(l)))
        XCTAssertTrue(host.isNativelyHosted(key))
        host.attach(key, to: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        let web = try XCTUnwrap(host.webView(key))
        var text = ""
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            text = (try? await web.evaluateJavaScript("document.getElementById('o').textContent")) as? String ?? ""
            if text.contains("user") { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        text = (try? await web.evaluateJavaScript("document.getElementById('o').textContent")) as? String ?? ""
        XCTAssertEqual(text, "joined ok storage ok user ok", "control: unknown APIs stay unanswered")
        host.unload(key)
    }

    /// A meeting app (Q&A) opened outside a meeting calls a `meeting.*`
    /// API; the host marks it so a blank page shows Teams' "open in a
    /// meeting" empty state instead of a "couldn't load" error (R3).
    /// Negative control: an app that never calls `meeting.*` stays unmarked.
    func testMeetingContextIsMarkedOnlyByMeetingApps() async throws {
        func run(_ script: String, id: String) async throws -> Bool {
            var l = launch(resource: "https://tasks.example.com")
            l.appID = id
            l.demoHTML = "<html><body><script>var n=0;" +
                "function send(f,a){n++;window.nativeInterface.framelessPostMessage(JSON.stringify({id:n,func:f,args:a||[]}));}" +
                script + "</script></body></html>"
            let host = FrameHost(accountKey: "demo")
            let key = FrameKey.app(id)
            host.registerApp(FrameApp(id: id, label: "M", symbol: "app", source: .personal, launch: .teamsApp(l)))
            host.attach(key, to: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
            _ = try XCTUnwrap(host.webView(key))
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                if host.teamsJSHost(key)?.wantsMeetingContext == true { host.unload(key); return true }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let flag = host.teamsJSHost(key)?.wantsMeetingContext ?? false
            host.unload(key)
            return flag
        }
        let meeting = try await run("send('initialize',['2.49.0']);send('meeting.getMeetingDetails',[]);", id: "an5-meeting")
        XCTAssertTrue(meeting, "a meeting.* call marks the host as a meeting app")
        let plain = try await run("send('initialize',['2.49.0']);send('getContext',[]);", id: "an5-plain")
        XCTAssertFalse(plain, "control: an app with no meeting.* call is not a meeting app")
    }

    /// getContext carries the full `osLocaleInfo` Teams sends (Viva
    /// Learning calls `osLocaleInfo.shortDate.toUpperCase()` unguarded and
    /// showed its error page without it) (R5); a declined consent sheet
    /// leaves a permission message, not "showed nothing" (R8).
    func testContextLocaleInfoAndConsentDeclinedMessage() throws {
        let js = TeamsJSHost(transport: .frameless, launch: launch(), context: TeamsJSAppContext())
        let info = try XCTUnwrap(js.legacyContext()["osLocaleInfo"] as? [String: Any])
        for k in ["shortDate", "longDate", "shortTime", "longTime"] {
            XCTAssertFalse((info[k] as? String ?? "").isEmpty, "\(k) present")
        }
        XCTAssertEqual(info["platform"] as? String, "macos")
        let us = TeamsJSHost.osLocaleInfo(regionalFormat: "en-us", locale: Locale(identifier: "en_US"))
        XCTAssertEqual(us["shortDate"] as? String, "M/d/yy")
        XCTAssertTrue((us["shortTime"] as? String ?? "").hasPrefix("h:mm"))
        XCTAssertTrue(FrameHost.failureMessage("consent declined").contains("permission"))
        XCTAssertEqual(FrameHost.failureMessage("blank page"), "The app loaded but showed nothing.", "control")
    }

    /// The meeting-app empty state is an informational pane, never a
    /// `.failed` (which would show "Couldn't Load" + Retry) (R3).
    func testMeetingStateIsInformationalNotError() {
        let s = FrameLoadState.info(message: FrameHost.meetingAppMessage, systemImage: "video")
        if case .failed = s { XCTFail("meeting state must not be a failure state") }
        XCTAssertFalse(FrameHost.meetingAppMessage.isEmpty)
    }

    /// The blank check's pixel fallback: a solid page is 0, a page with
    /// content is above the threshold.
    func testInkFractionSeparatesBlankFromPainted() throws {
        func image(_ draw: (CGContext) -> Void) throws -> CGImage {
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 120, height: 90, bitsPerComponent: 8, bytesPerRow: 480,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
            draw(ctx)
            return try XCTUnwrap(ctx.makeImage())
        }
        let blank = try image { _ in }
        let painted = try image { ctx in
            ctx.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.3, alpha: 1))
            ctx.fill(CGRect(x: 10, y: 10, width: 40, height: 20))
        }
        XCTAssertEqual(FrameHost.inkFraction(blank), 0)
        XCTAssertGreaterThan(try XCTUnwrap(FrameHost.inkFraction(painted)), FrameHost.blankInk)
    }
}
