// AppEffTests.swift — guards for the app panes' CPU / memory policy
// (APPEFF): pane cap + restore, hidden panes out of the view tree and
// suspended, memory pressure, telemetry content rules, lean bridge
// scripts, evicted views released. Offline; no window is ever shown
// (windows here are never ordered front).
import AppKit
import WebKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class AppEffTests: XCTestCase {
    private func waitFor(_ seconds: Double, _ cond: @MainActor () -> Bool) async {
        // `seconds` is ignored: wait on the condition, ceiling only bounds a hang.
        // Callers assert the outcome themselves.
        await TestWait.until(interval: 0.05) { cond() }
    }

    private func hostedDemoApp(_ id: String) -> FrameApp {
        FrameApp(id: id, label: "Eff \(id)", symbol: "app", source: .personal,
                 launch: .teamsApp(TeamsAppLaunch(appID: id, entityID: "e", contentTemplate: "https://\(id).example.invalid/",
                                                  demoHTML: "<html><body><p>\(id)</p></body></html>")))
    }

    /// A window that is never shown, holding `container`.
    private func offscreenWindow(_ container: NSView) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300), styleMask: [.borderless],
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        container.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        w.contentView = container
        return w
    }

    // MARK: R2 cap + restore

    func testKeepInMemoryDefaultsToThree() {
        let d = UserDefaults(suiteName: "appeff-cap-\(UUID().uuidString)")!
        XCTAssertEqual(FramePolicy.keepInMemory(d), 3)
        d.set(6, forKey: FramePolicy.keepInMemoryKey)
        XCTAssertEqual(FramePolicy.keepInMemory(d), 6)
        d.set(42, forKey: FramePolicy.keepInMemoryKey)
        XCTAssertEqual(FramePolicy.keepInMemory(d), 3, "only Low 1 / Balanced 3 / High 6")
    }

    func testIframeHostPagesLoadAfreshInsteadOfRestoring() {
        XCTAssertFalse(FrameHost.restoresInteraction(transport: .iframe))
        XCTAssertTrue(FrameHost.restoresInteraction(transport: .frameless))
        XCTAssertTrue(FrameHost.restoresInteraction(transport: nil), "plain pages restore address + scroll")
    }

    /// An evicted iframe-hosted app comes back loaded. Before: its saved
    /// state (an HTML-string top document) restored to a blank view that
    /// never loaded, so the pane stayed "loading" behind its snapshot.
    func testEvictedIframeAppComesBackLoaded() async throws {
        let account = "appeff-iframe"
        UserDefaults.standard.set(true, forKey: "bt.webStore.ssoMigrated.\(account)")
        defer { UserDefaults.standard.removeObject(forKey: "bt.webStore.ssoMigrated.\(account)") }
        let host = FrameHost(accountKey: account, store: .nonPersistent())
        host.openExternal = { _ in XCTFail("nothing opens in the browser") }
        let id = "appeff-ifr-\(UUID().uuidString.prefix(8))"
        let app = FrameApp(id: id, label: "Eff", symbol: "app", source: .personal,
                           launch: .teamsApp(TeamsAppLaunch(appID: id, entityID: "e", contentTemplate: "https://appeff-ifr.example.invalid/",
                                                            transport: .iframe)))
        host.registerApp(app)
        let key = FrameKey.app(id)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        host.attach(key, to: box)
        await waitFor(10) { host.page(key)?.state == .loaded }
        XCTAssertEqual(host.page(key)?.state, .loaded)
        XCTAssertEqual(host.teamsJSHost(key)?.transport, .iframe)
        host.keepInMemory = 0
        host.detach(key, from: box)
        XCTAssertNil(host.webView(key), "evicted beyond the cap")
        host.keepInMemory = 3
        host.attach(key, to: box)
        await waitFor(10) { host.page(key)?.state == .loaded }
        XCTAssertEqual(host.page(key)?.state, .loaded, "loads again, never stuck loading")
        host.unload(key)
    }

    // MARK: R3 hidden panes

    func testHiddenPaneLeavesTheViewTreeAndIsSuspendable() throws {
        let host = FrameHost(accountKey: "demo")
        let app = DemoFrameApps.webLinks[0]
        host.registerApp(app)
        let key = FrameKey.app(app.id)
        let container = FrameContainerView(key: key, host: host)
        let root = NSView()
        let win = offscreenWindow(root)
        root.addSubview(container)
        host.attach(key, to: container)
        let web = try XCTUnwrap(host.webView(key))
        XCTAssertTrue(web.superview === container)
        XCTAssertEqual(web.configuration.preferences.inactiveSchedulingPolicy, .suspend)
        XCTAssertTrue(host.page(key)?.isOnScreen ?? false)
        // The pane's container leaves the window without being dismantled.
        container.removeFromSuperview()
        XCTAssertNil(web.superview, "hidden: out of the view tree")
        XCTAssertTrue(host.webView(key) === web, "still resident (no reload)")
        XCTAssertFalse(host.page(key)?.isOnScreen ?? true)
        // Back in the window: the same view returns.
        root.addSubview(container)
        XCTAssertTrue(web.superview === container)
        host.unload(key)
        withExtendedLifetime(win) {}
    }

    // MARK: R4 memory pressure

    /// Warning takes only suspended panes (a recently hidden pane keeps its
    /// in-page state); critical takes every hidden pane.
    func testMemoryPressureWarningTakesSuspendedCriticalTakesEveryHiddenPane() {
        let t = Date()
        let rs = [
            FramePolicy.Resident(key: "a", visible: false, lastUsed: t.addingTimeInterval(-30)),
            FramePolicy.Resident(key: "b", visible: true, lastUsed: t.addingTimeInterval(-60)),
            FramePolicy.Resident(key: "c", visible: false, lastUsed: t.addingTimeInterval(-10), suspended: true),
        ]
        XCTAssertEqual(FramePolicy.evict(rs, cap: 3), [])
        XCTAssertEqual(FramePolicy.evict(rs, cap: 3, pressure: .warning), ["c"])
        XCTAssertEqual(Set(FramePolicy.evict(rs, cap: 3, pressure: .critical)), ["a", "c"])
    }

    func testPressureHandlerKeepsOnlyTheVisiblePane() throws {
        let host = FrameHost(accountKey: "demo")
        let apps = Array(DemoFrameApps.webLinks.prefix(3))
        for a in apps { host.registerApp(a) }
        let keys = apps.map { FrameKey.app($0.id) }
        let shown = NSView()
        let win = offscreenWindow(shown)
        host.attach(keys[0], to: NSView())
        host.attach(keys[1], to: NSView())
        host.attach(keys[2], to: shown)
        XCTAssertEqual(host.residents.count, 3, "within the cap")
        host.handleMemoryPressure(.normal)
        XCTAssertEqual(host.residents.count, 3, "normal: nothing")
        host.handleMemoryPressure(.warning)
        XCTAssertEqual(host.residents.count, 3, "warning: recently hidden panes (not suspended) stay")
        host.handleMemoryPressure(.critical)
        XCTAssertEqual(host.residents.map(\.key), [keys[2].raw], "critical: all but the visible pane")
        XCTAssertNotNil(host.webView(keys[2]))
        for k in keys { host.unload(k) }
        withExtendedLifetime(win) {}
    }

    // MARK: R5 content rules

    private func blocks(_ url: String) -> Bool {
        PaneContentRules.blockedHosts.contains { h in
            let re = try! NSRegularExpression(pattern: PaneContentRules.urlFilter(h), options: [.caseInsensitive])
            return re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
        }
    }

    func testTelemetryHostsAreBlockedAndAppHostsAreNot() {
        for u in ["https://browser.events.data.microsoft.com/OneCollector/1.0/",
                  "https://eu-mobile.events.data.microsoft.com:443/x",
                  "https://browser.pipe.aria.microsoft.com/Collector/3.0/",
                  "https://westeurope-5.in.applicationinsights.azure.com/v2/track",
                  "https://dc.services.visualstudio.com/v2/track",
                  "https://nexus.officeapps.live.com/nexus/rules",
                  "https://y.clarity.ms/collect",
                  "https://a38151b40bf6fe782783ca79b582ee9d.fp.measure.office.com/probe",
                  "https://csp.microsoft.com/report/OneDrive",
                  "https://www.google-analytics.com/g/collect"] {
            XCTAssertTrue(blocks(u), u)
        }
        // What apps need: sign-in, data, code, config, experiments, SDK
        // scripts they may call directly.
        for u in ["https://login.microsoftonline.com/common/oauth2/v2.0/token",
                  "https://graph.microsoft.com/v1.0/me",
                  "https://contoso.sharepoint.com/sites/x",
                  "https://contoso-my.sharepoint.com/personal/x",
                  "https://tasks.office.com/x", "https://tasks.teams.microsoft.com/x",
                  "https://planner.cloud.microsoft/x", "https://hosted.loop.cloud.microsoft/x",
                  "https://whiteboard.cloud.microsoft/x", "https://approvals.teams.microsoft.com/x",
                  "https://res.cdn.office.net/x", "https://statics.teams.cdn.office.net/x",
                  "https://ecs.office.com/config/v1/", "https://config.edge.skype.com/config/v1/",
                  "https://substrate.office.com/x", "https://outlook.office.com/x",
                  "https://js.monitor.azure.com/scripts/b/ai.3.gbl.min.js",
                  "https://api.applicationinsights.io/v1/apps",
                  "https://www.googletagmanager.com/gtag/js", "https://cdn.segment.com/analytics.js",
                  "https://events.microsoft.com/", "https://myevents.data.microsoft.com.example.com/",
                  "https://notclarity.ms/",
                  // Every other host the 10 inventoried apps loaded (APPEFF hosts-norules).
                  "https://res.public.onecdn.static.microsoft/x", "https://createcatalog.public.onecdn.static.microsoft/x",
                  "https://static2.sharepointonline.com/x", "https://owl.officeapps.live.com/x",
                  "https://webshell.suite.office.com/x", "https://amcdn.msftauth.net/x", "https://r4.res.office365.com/x",
                  "https://api.planner.svc.cloud.microsoft/x", "https://project.microsoft.com/x", "https://admin.microsoft.com/x",
                  "https://messaging.engagement.office.com/x", "https://clients.config.office.net/x",
                  "https://go.trouter.communications.svc.cloud.microsoft/x", "https://communications.svc.cloud.microsoft/x",
                  "https://roaming.officeapps.live.com/x", "https://ocws.officeapps.live.com/x", "https://odc.officeapps.live.com/x",
                  "https://hubblecontent.osi.office.net/x", "https://pus4-collabhubrtc.officeapps.live.com/x",
                  "https://whiteboard.microsoft.com/x", "https://learningapp.microsoft.com/x",
                  "https://client.learningapp.microsoft.com/x", "https://media.licdn.com/x", "https://support.microsoft.com/x",
                  "https://learn.microsoft.com/x", "https://config.teams.microsoft.com/x", "https://www.linkedin.com/x",
                  "https://flw.teams.cloud.microsoft/x", "https://m365.cloud.microsoft/x", "https://loki.delve.office.com/x",
                  "https://nam.loki.delve.office.com/x", "https://updates.teams.cloud.microsoft/x",
                  "https://afdcanary.office.svc.cloud.microsoft/x", "https://tr-officehomeccm-afd.office.com/x",
                  "https://arc.msn.com/x", "https://cxcs.microsoft.net/x"] {
            XCTAssertFalse(blocks(u), u)
        }
    }

    final class SchemeLog: NSObject, WKURLSchemeHandler {
        var hosts: [String] = []
        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            let url = task.request.url!
            hosts.append(url.host ?? "")
            let html = url.path == "/" ? """
                <html><body><img src="bt-eff://browser.events.data.microsoft.com/p.gif">
                <img src="bt-eff://control.example/p.gif"></body></html>
                """ : ""
            task.didReceive(URLResponse(url: url, mimeType: url.path == "/" ? "text/html" : "image/gif",
                                        expectedContentLength: html.utf8.count, textEncodingName: "utf-8"))
            task.didReceive(Data(html.utf8))
            task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }

    /// The compiled list really blocks in WebKit: a telemetry request is
    /// never made, the control request next to it is.
    func testCompiledRulesBlockInWebKit() async throws {
        PaneContentRules.prepare()
        await waitFor(10) { PaneContentRules.compiled != nil }
        let rules = try XCTUnwrap(PaneContentRules.compiled, "rules compile")
        let log = SchemeLog()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(log, forURLScheme: "bt-eff")
        config.userContentController.add(rules)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), configuration: config)
        web.load(URLRequest(url: URL(string: "bt-eff://app.example/")!))
        await waitFor(10) { log.hosts.contains("control.example") }
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(log.hosts.contains("control.example"), "control loads")
        XCTAssertFalse(log.hosts.contains("browser.events.data.microsoft.com"), "telemetry blocked")
    }

    func testEveryPaneGetsTheRulesAndNoAutoplay() throws {
        let src = try source("Frame/FrameHost.swift")
        XCTAssertTrue(src.contains("PaneContentRules.apply(to: config.userContentController)"))
        XCTAssertTrue(src.contains("config.mediaTypesRequiringUserActionForPlayback = .all"))
        XCTAssertTrue(src.contains("config.preferences.inactiveSchedulingPolicy = .suspend"))
        XCTAssertTrue(src.contains("makeMemoryPressureSource(eventMask: [.warning, .critical]"))
        XCTAssertTrue(src.contains("handleMemoryPressure(critical ? .critical : .warning)"))
        XCTAssertTrue(src.contains("retire(web)"))
    }

    // MARK: R6 lean bridge

    func testBridgeScriptsAreSmallAndShared() throws {
        XCTAssertLessThan(TeamsJSHost.paintProbe.utf8.count, 2048)
        XCTAssertLessThan(TeamsJSHost.framelessShim.utf8.count, 2048)
        let src = try source("AppHost/TeamsJSHost.swift")
        // Static strings: nothing per pane is baked into a page script.
        XCTAssertTrue(src.contains("static let paintProbe = \"\"\""))
        XCTAssertTrue(src.contains("static let framelessShim = \"\"\""))
        XCTAssertEqual(src.components(separatedBy: "WKUserScript(").count - 1, 2, "two page scripts, no more")
        XCTAssertTrue(src.contains("controller.addUserScript(Self.paintProbeScript)"), "one shared instance per script")
        XCTAssertTrue(src.contains("controller.addUserScript(Self.framelessShimScript)"))
        XCTAssertTrue(TeamsJSHost.paintProbeScript === TeamsJSHost.paintProbeScript)
    }

    // MARK: R7 no leaks

    func testScriptHandlersAreWeakEverywhere() throws {
        let dir = sourcesRoot().appendingPathComponent("Sources/BetterTeamsUI")
        let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50)
        var registrations = 0
        for f in files {
            let src = try String(contentsOf: f, encoding: .utf8)
            for line in src.split(separator: "\n") where line.contains(".add(") && line.contains("name:") {
                registrations += 1
                XCTAssertTrue(line.contains("WeakScriptHandler("), "\(f.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
            XCTAssertFalse(src.contains("addScriptMessageHandler(self"), f.lastPathComponent)
        }
        XCTAssertGreaterThan(registrations, 0, "the scan sees the bridge's registrations")
    }

    /// 20 panes opened and closed: every view, bridge host and content
    /// controller is released; nothing stays resident or retiring.
    func testTwentyPanesOpenedAndClosedLeaveNothing() async throws {
        let host = FrameHost(accountKey: "demo")
        final class W { weak var web: WKWebView?; weak var js: TeamsJSHost?; weak var ucc: WKUserContentController? }
        var weaks: [W] = []
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        for i in 0..<20 {
            let app = i.isMultiple(of: 2) ? hostedDemoApp("appeff-\(i)") : FrameApp(
                id: "appeff-\(i)", label: "Eff \(i)", symbol: "globe", source: .webLink,
                launch: .direct(URL(string: "https://contoso.sharepoint.com/sites/eff\(i)")!))
            host.registerApp(app)
            let key = FrameKey.app(app.id)
            host.attach(key, to: box)
            await waitFor(5) { host.page(key)?.state == .loaded }
            autoreleasepool {
                let w = W()
                w.web = host.webView(key)
                w.js = host.teamsJSHost(key)
                w.ucc = host.webView(key)?.configuration.userContentController
                weaks.append(w)
            }
            if i.isMultiple(of: 2) { XCTAssertNotNil(weaks.last?.js, "hosted demo app has a bridge") }
            host.detach(key, from: box)
            host.unload(key)
        }
        await waitFor(8) { host.retiringCount == 0 && weaks.allSatisfy { $0.web == nil && $0.js == nil && $0.ucc == nil } }
        XCTAssertEqual(host.retiringCount, 0)
        XCTAssertEqual(host.residents.count, 0)
        XCTAssertEqual(weaks.filter { $0.web != nil }.count, 0, "views released")
        XCTAssertEqual(weaks.filter { $0.js != nil }.count, 0, "bridge hosts released")
        XCTAssertEqual(weaks.filter { $0.ucc != nil }.count, 0, "content controllers released")
    }

    /// An evicted view is held only until its page answers once.
    func testEvictedViewIsRetiredThenReleased() async throws {
        let host = FrameHost(accountKey: "demo")
        let app = DemoFrameApps.webLinks[1]
        host.registerApp(app)
        let key = FrameKey.app(app.id)
        host.attach(key, to: NSView())
        await waitFor(5) { host.page(key)?.state == .loaded }
        weak var web = host.webView(key)
        XCTAssertNotNil(web)
        host.unload(key)
        XCTAssertNil(host.webView(key))
        XCTAssertEqual(host.retiringCount, 1)
        await waitFor(6) { host.retiringCount == 0 && web == nil }
        XCTAssertEqual(host.retiringCount, 0)
        XCTAssertNil(web)
    }

    // MARK: helpers

    private func sourcesRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ rel: String) throws -> String {
        try String(contentsOf: sourcesRoot().appendingPathComponent("Sources/BetterTeamsUI/" + rel), encoding: .utf8)
    }
}
