// AppSignInTests.swift — APPSIGNIN: sign-in for apps on the Teams frame
// stays in the window. A local harness page opens a scripted popup that
// posts back to its opener and closes itself (MSAL / TeamsJS auth popup
// shape); no network, no browser.
import XCTest
import AppKit
import WebKit

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class AppSignInTests: XCTestCase {
    private let account = "appsignin-harness"

    private static let harness = """
    <!doctype html><html><body><script>
    window.__got = "";
    addEventListener("message", function (e) { window.__got = String(e.data); });
    function openPopup() {
      var w = window.open("", "auth", "width=480,height=600");
      if (!w) { return "blocked"; }
      w.document.write('<script>window.opener.postMessage("signed-in", "*"); window.close();<\\/script>');
      w.document.close();
      return "opened";
    }
    </script></body></html>
    """

    /// A scripted popup opens as an in-app child view: `window.opener`
    /// works, its message reaches the page, `window.close()` closes the
    /// sheet, and the page itself stays put.
    func testScriptedPopupCompletesInApp() async throws {
        let defaults = UserDefaults.standard
        let migrated = "bt.webStore.ssoMigrated.\(account)"
        defaults.set(true, forKey: migrated)
        let chats = ChatListViewModel(fetcher: { _ in ChatsResponse(ok: true, chats: []) })
        let graph = AccountWindowGraph(account: AccountRecord(id: account, displayName: "Test"), chats: chats)
        let model = WindowModel(graph: graph, accountKey: account, options: LaunchOptions(args: ["--evidence"]))
        let window = OffscreenWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSViewController()
        root.view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window.contentViewController = root
        let sheets = SheetPresenter(model: model) { [weak window] in window?.contentViewController }
        model.presenter = sheets
        let host = model.frameHost
        let key = FrameKey.app("appsignin-harness")
        defer {
            host.unload(key)
            defaults.removeObject(forKey: migrated)
            let storeKey = "bt.webStore.\(account)"
            if let raw = defaults.string(forKey: storeKey), let id = UUID(uuidString: raw) {
                WKWebsiteDataStore.remove(forIdentifier: id) { _ in }
            }
            defaults.removeObject(forKey: storeKey)
        }
        addTeardownBlock { @MainActor in XCTAssertTrue(TestDisplayGuard.windowsOnDisplay().isEmpty, "test window reached a display") }
        host.registerTab(key, url: URL(string: "about:blank")!, title: "Harness")
        host.attach(key, to: root.view)
        let web = try XCTUnwrap(host.webView(key))
        // Any app page (never the Teams web app: APPNATIVE4 cancels it).
        let base = URL(string: "https://contoso.sharepoint.com/harness/")!
        web.loadHTMLString(Self.harness, baseURL: base)
        try await until { (try? await web.evaluateJavaScript("typeof openPopup") as? String) == "function" }

        let opened = try await web.evaluateJavaScript("openPopup()") as? String
        XCTAssertEqual(opened, "opened", "window.open returned no window")
        try await until { (try? await web.evaluateJavaScript("window.__got") as? String) == "signed-in" }
        try await until { !sheets.isPresenting }
        XCTAssertEqual(web.url, base, "the page must not be replaced by its popup")
        XCTAssertNil(model.sheet)
    }

    /// Federated sign-in (the owner's bug): Microsoft's account picker
    /// hands off to the tenant's IdP, which is not on the frame
    /// allowlist. It stays in the frame, as do the IdP's own hops, until
    /// the round trip lands back on an allowed host.
    func testFederatedSignInStaysInFrame() {
        let ms = URL(string: "https://login.microsoftonline.com/common/oauth2/authorize?client_id=x")!
        let idp = URL(string: "https://sts.contoso-idp.example/adfs/ls/?wa=wsignin1.0")!
        let mfa = URL(string: "https://mfa.vendor.example/frame")!
        let teams = URL(string: "https://teams.microsoft.com/v2/")!
        let other = URL(string: "https://news.example.com/story")!
        typealias R = FrameHost.MainFrameRoute
        // Leaving a Microsoft sign-in page: stays, realm known or not.
        XCTAssertEqual(FrameHost.mainFrameRoute(to: idp, allowed: false, from: ms, signingIn: false, signInHosts: []),
                       R.frame(signingIn: true))
        XCTAssertEqual(FrameHost.mainFrameRoute(to: idp, allowed: false, from: teams, signingIn: false,
                                                signInHosts: ["sts.contoso-idp.example"]), R.frame(signingIn: true))
        // The IdP's own hop while signing in stays; back home clears it.
        XCTAssertEqual(FrameHost.mainFrameRoute(to: mfa, allowed: false, from: idp, signingIn: true, signInHosts: []),
                       R.frame(signingIn: true))
        XCTAssertEqual(FrameHost.mainFrameRoute(to: ms, allowed: true, from: idp, signingIn: true, signInHosts: []),
                       R.frame(signingIn: false))
        // Outside a sign-in: unknown hosts still go to the browser.
        XCTAssertEqual(FrameHost.mainFrameRoute(to: other, allowed: false, from: teams, signingIn: false, signInHosts: []),
                       R.browser)
        XCTAssertEqual(FrameHost.mainFrameRoute(to: URL(string: "http://sts.contoso-idp.example/")!, allowed: false,
                                                from: ms, signingIn: false, signInHosts: []), R.browser)
    }

    /// Popups: sign-in popups get the in-app sheet (opener kept); plain
    /// new-window links keep §7.3 (in place if allowed, else browser).
    func testPopupRoutes() {
        typealias P = FrameHost.PopupRoute
        let ms = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        let app = URL(string: "https://app.vendor.example/auth-start")!
        let sp = URL(string: "https://contoso.sharepoint.com/doc")!
        XCTAssertEqual(FrameHost.popupRoute(to: ms, sized: false, allowed: true, fromSignIn: false, signInHosts: []), P.sheet)
        XCTAssertEqual(FrameHost.popupRoute(to: app, sized: true, allowed: false, fromSignIn: false, signInHosts: []), P.sheet)
        XCTAssertEqual(FrameHost.popupRoute(to: nil, sized: false, allowed: false, fromSignIn: false, signInHosts: []), P.sheet)
        XCTAssertEqual(FrameHost.popupRoute(to: URL(string: "about:blank"), sized: true, allowed: true, fromSignIn: false,
                                            signInHosts: []), P.sheet)
        XCTAssertEqual(FrameHost.popupRoute(to: app, sized: false, allowed: false, fromSignIn: true, signInHosts: []), P.sheet)
        XCTAssertEqual(FrameHost.popupRoute(to: app, sized: false, allowed: false, fromSignIn: false, signInHosts: []), P.browser)
        XCTAssertEqual(FrameHost.popupRoute(to: sp, sized: false, allowed: true, fromSignIn: false, signInHosts: []), P.frame)
        XCTAssertEqual(FrameHost.popupRoute(to: URL(string: "mailto:a@b.example"), sized: true, allowed: false,
                                            fromSignIn: false, signInHosts: []), P.browser)
    }

    private func until(_ timeout: TimeInterval = 5, _ check: () async -> Bool) async throws {
        // `timeout` is ignored: wait on the condition, ceiling only bounds a hang.
        let t0 = DispatchTime.now().uptimeNanoseconds
        while Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e9 < TestWait.hangCeiling {
            if await check() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out")
        throw CancellationError()
    }
}
