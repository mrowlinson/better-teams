// AppNative6Tests.swift — APPNATIVE6: the Teams web app never loads in
// any frame of a pane, in an app's popup or auth sheet, or as a browser
// fallback (R8, R13); Office documents from Files open read-only in the
// window (R9). No network: every Teams request is refused before it is
// sent; the control frames go to a reserved, unresolvable host.
import AppKit
import WebKit
import XCTest
import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class AppNative6Tests: XCTestCase {
    private let teamsWeb = URL(string: "https://teams.microsoft.com/v2/")!
    private let control = URL(string: "https://an6-control.example.invalid/x")!

    func testGuardRefusesTeamsWebInEveryFrame() {
        for main in [true, false] {
            XCTAssertTrue(TeamsWebGuard.refuses(teamsWeb, mainFrame: main, iframeHostDocument: false), "main=\(main)")
            XCTAssertFalse(TeamsWebGuard.refuses(control, mainFrame: main, iframeHostDocument: false), "control main=\(main)")
            // App pages Microsoft hosts on a Teams host are apps.
            XCTAssertFalse(TeamsWebGuard.refuses(URL(string: "https://teams.cloud.microsoft/shifts-web-app/")!,
                                                 mainFrame: main, iframeHostDocument: false), "control app page")
        }
        // The iframe transport's own host document: main frame only.
        let hostDoc = URL(string: "https://teams.microsoft.com/")!
        XCTAssertFalse(TeamsWebGuard.refuses(hostDoc, mainFrame: true, iframeHostDocument: true))
        XCTAssertTrue(TeamsWebGuard.refuses(hostDoc, mainFrame: false, iframeHostDocument: true))
    }

    /// No Teams address ever goes to the default browser, whether a page
    /// went there by itself, the user clicked it, or no native view exists.
    func testTeamsLinksNeverFallBackToTheBrowser() {
        let host = FrameHost(accountKey: "an6-browser", store: .nonPersistent())
        var external: [URL] = []
        host.openExternal = { external.append($0) }
        XCTAssertFalse(host.openTeamsLink(teamsWeb), "no window: no native view")
        host.refuseTeamsWeb(teamsWeb, userInitiated: true)
        host.refuseTeamsWeb(URL(string: "https://teams.microsoft.com/l/chat/0/0")!, userInitiated: false)
        XCTAssertEqual(external, [])
        XCTAssertEqual(host.refusedTeamsWeb, 2)
        // Control: the seam records what does go out.
        host.openExternal(control)
        XCTAssertEqual(external, [control])
    }

    private func page(iframes: [URL]) -> String {
        "<!doctype html><html><body>" + iframes.map { "<iframe src=\"\($0.absoluteString)\"></iframe>" }.joined()
            + "</body></html>"
    }

    private func waitFor(_ seconds: Double, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    /// A pane's subframes (R8): a Teams web iframe is refused, the
    /// control iframe on another host is not.
    func testPaneSubframesNeverLoadTeamsWeb() async throws {
        let account = "an6-subframe"
        UserDefaults.standard.set(true, forKey: "bt.webStore.ssoMigrated.\(account)")
        defer { UserDefaults.standard.removeObject(forKey: "bt.webStore.ssoMigrated.\(account)") }
        let host = FrameHost(accountKey: account, store: .nonPersistent())
        host.openExternal = { _ in XCTFail("nothing opens in the browser") }
        var seen: [(URL, Bool)] = []
        host.navigationGate = { a in
            if let u = a.request.url, u.host != "an6-page.example.invalid" { seen.append((u, a.targetFrame?.isMainFrame ?? true)) }
            return true
        }
        let key = FrameKey.tab("an6-subframes")
        let base = URL(string: "https://an6-page.example.invalid/")!
        host.registerTab(key, url: base, title: "t")
        host.attach(key, to: NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200)))
        let web = try XCTUnwrap(host.webView(key))
        web.loadHTMLString(page(iframes: [teamsWeb, control]), baseURL: base)
        await waitFor(10) { seen.count >= 2 }
        XCTAssertEqual(Set(seen.map(\.0)), [teamsWeb, control])
        XCTAssertTrue(seen.allSatisfy { !$0.1 }, "both are subframes")
        XCTAssertEqual(host.refusedTeamsWeb, 1, "only the Teams web frame is refused")
        host.unload(key)
    }

    /// An app popup's or auth sheet's own navigations (R8): the sheet is
    /// the popup's navigation delegate and refuses Teams web in any frame.
    func testPopupSheetRefusesTeamsWeb() async throws {
        let host = FrameHost(accountKey: "an6-popup", store: .nonPersistent())
        host.openExternal = { _ in XCTFail("nothing opens in the browser") }
        var seen: [URL] = []
        host.navigationGate = { a in
            if let u = a.request.url, u.host != "an6-popup.example.invalid" { seen.append(u) }
            return true
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let child = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: config)
        let sheet = WebAuthSheet(web: child, start: nil, redirectURI: "") { _ in }
        sheet.guardHost = host
        XCTAssertTrue(child.navigationDelegate === sheet, "a popup child has a navigation delegate")
        child.loadHTMLString(page(iframes: [teamsWeb, control]),
                             baseURL: URL(string: "https://an6-popup.example.invalid/")!)
        await waitFor(10) { seen.count >= 2 }
        XCTAssertEqual(Set(seen), [teamsWeb, control])
        XCTAssertEqual(host.refusedTeamsWeb, 1)
        // A popup's main frame going to Teams web is refused too.
        child.load(URLRequest(url: URL(string: "https://teams.microsoft.com/_#/conversations")!))
        await waitFor(10) { host.refusedTeamsWeb >= 2 }
        XCTAssertEqual(host.refusedTeamsWeb, 2)
        XCTAssertNotEqual(child.url.map(TeamsWebGuard.isTeamsWeb), true)
    }

    // MARK: R9 Office documents

    func testOfficeDocumentsOpenReadOnly() throws {
        let doc = URL(string: "https://contoso.sharepoint.com/sites/x/_layouts/15/Doc.aspx?sourcedoc=%7Babc%7D&file=a.docx&action=default&mobileredirect=true")!
        let view = try XCTUnwrap(OfficeDocumentView.viewURL(doc))
        let items = try XCTUnwrap(URLComponents(url: view, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.filter { $0.name == "action" }.map(\.value), ["view"])
        XCTAssertEqual(items.first { $0.name == "sourcedoc" }?.value, "{abc}")
        XCTAssertEqual(OfficeDocumentView.viewURL(view), view, "already read-only: unchanged (no loop)")
        let file = URL(string: "https://contoso-my.sharepoint.com/personal/u/Documents/Budget.xlsx")!
        XCTAssertEqual(OfficeDocumentView.viewURL(file)?.query, "web=1")
        // Controls: other hosts and non-Office files are left alone.
        XCTAssertNil(OfficeDocumentView.viewURL(URL(string: "https://example.com/a.docx")!))
        XCTAssertNil(OfficeDocumentView.viewURL(URL(string: "https://contoso.sharepoint.com/sites/x/a.pdf")!))

        // Files ▸ Open: one pane per document, a plain page, read-only.
        let host = FrameHost(accountKey: "an6-docs", store: .nonPersistent())
        let app = try XCTUnwrap(host.library.document(name: "Budget.xlsx", webURL: file))
        XCTAssertEqual(host.library.document(name: "Budget.xlsx", webURL: file)?.id, app.id)
        XCTAssertNotEqual(host.library.document(name: "Plan.docx", webURL: doc)?.id, app.id)
        XCTAssertNil(host.library.document(name: "a.pdf", webURL: URL(string: "https://contoso.sharepoint.com/a.pdf")!))
        guard case .direct(let u) = app.launch else { return XCTFail("\(app.launch)") }
        XCTAssertEqual(u.query, "web=1")
        host.registerApp(app)
        let p = try XCTUnwrap(host.page(.app(app.id)))
        XCTAssertEqual(host.documentViewRedirect(p, doc, mainFrame: true), view, "edit hop → view")
        XCTAssertNil(host.documentViewRedirect(p, view, mainFrame: true))
        XCTAssertNil(host.documentViewRedirect(p, doc, mainFrame: false), "subframes are the viewer's own")
        // Any plain page that is an Office document (a file tab, a web
        // link) opens read-only too, and its edit hops go back to view.
        host.registerTab(.tab("an6-filetab"), url: doc, title: "d")
        let tab = try XCTUnwrap(host.page(.tab("an6-filetab")))
        XCTAssertEqual(tab.url, view)
        XCTAssertEqual(host.documentViewRedirect(tab, doc, mainFrame: true), view)
        // Control: an ordinary SharePoint page is not rewritten.
        let site = URL(string: "https://contoso.sharepoint.com/sites/x/SitePages/Home.aspx")!
        host.registerTab(.tab("an6-plain"), url: site, title: "p")
        let plain = try XCTUnwrap(host.page(.tab("an6-plain")))
        XCTAssertEqual(plain.url, site)
        XCTAssertNil(host.documentViewRedirect(plain, doc, mainFrame: true))
    }

    /// An app's openLink / executeDeepLink to a Teams address never opens
    /// the default browser (R8): an unrouted deep link and a plain Teams
    /// web address open nothing and the app is told so. Control: any other
    /// https link still opens outside.
    func testAppTeamsLinksNeverOpenTheBrowser() throws {
        let launch = TeamsAppLaunch(appID: "an6-links", entityID: "home", contentTemplate: "https://tasks.example.com/tab",
                                    resource: nil, validDomains: ["tasks.example.com"], transport: .frameless)
        let js = TeamsJSHost(transport: .frameless, launch: launch, context: TeamsJSAppContext())
        var opened: [URL] = [], routerAsked: [URL] = [], events: [TeamsJSEvent] = []
        js.openExternal = { opened.append($0) }
        js.onDeepLink = { routerAsked.append($0); return false }
        js.onEvent = { events.append($0) }
        let origin = try XCTUnwrap(URL(string: "https://tasks.example.com/tab"))
        func send(_ fn: String, _ link: String) throws {
            let body = try JSONSerialization.data(withJSONObject: ["id": 1, "func": fn, "args": [link]] as [String: Any])
            js.receive(String(decoding: body, as: UTF8.self), isMainFrame: true, origin: origin)
        }
        try send("executeDeepLink", "https://teams.microsoft.com/l/app/an6-unknown-app")
        try send("openLink", teamsWeb.absoluteString)
        XCTAssertEqual(routerAsked.count, 2, "both went to the native router first")
        XCTAssertTrue(opened.isEmpty, "no Teams address reached the browser: \(opened)")
        XCTAssertEqual(events.filter { $0.function == "deepLink.teams" }.map(\.detail), ["refused", "refused"])
        try send("openLink", "https://www.example.com/help")
        XCTAssertEqual(opened, [URL(string: "https://www.example.com/help")!], "control: other links still open outside")
    }

    /// Two pages on one SharePoint host (a document from Files and the
    /// OneDrive app at launch): the second waits for the sign-in the first
    /// started, instead of loading before its cookies land (R9).
    func testSecondSharePointPageWaitsForTheSignInInFlight() async {
        @MainActor final class Gate: TeamsJSTokenBroker {
            var calls = 0
            var release: CheckedContinuation<Void, Never>?
            func authToken(resource: String) async -> TeamsJSTokenResult {
                calls += 1
                await withCheckedContinuation { release = $0 }
                return .failure("test: no token", transient: false)
            }
            func naaToken(clientID: String, scopes: String, origin: String) async -> TeamsJSTokenResult {
                .failure("n/a", transient: false)
            }
        }
        @MainActor final class Flag { var done = false }
        let broker = Gate(), second = Flag()
        let sessions = SharePointSessions()
        let hosts = ["an6-contoso.sharepoint.com"]
        let store = WKWebsiteDataStore.nonPersistent()
        XCTAssertTrue(sessions.mustWait(hosts), "never tried: the page waits")
        let first = Task { @MainActor in await sessions.prepare(hosts, broker: broker, store: store) }
        for _ in 0 ..< 100 where broker.release == nil { await Task.yield() }
        XCTAssertNotNil(broker.release, "first sign-in is running")
        XCTAssertTrue(sessions.mustWait(hosts), "sign-in in flight: a second page waits (was: loaded at once)")
        let next = Task { @MainActor in
            await sessions.prepare(hosts, broker: broker, store: store)
            second.done = true
        }
        for _ in 0 ..< 100 { await Task.yield() }
        XCTAssertFalse(second.done, "the second page did not go ahead before the sign-in finished")
        broker.release?.resume()
        await first.value
        await next.value
        XCTAssertTrue(second.done)
        XCTAssertEqual(broker.calls, 1, "one sign-in serves both pages")
        XCTAssertFalse(sessions.mustWait(hosts), "control: tried and finished, no wait")
    }
}
