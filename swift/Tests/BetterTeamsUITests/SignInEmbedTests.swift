// SignInEmbedTests.swift — SIGNIN R5: Microsoft sign-in embedded in the
// window, end to end against a local fake login server (127.0.0.1, fake
// HTML page, redirect with a fake code). The core is faked at the VM
// seam; no Microsoft network, no browser, no real token store or
// keychain, no window on a display (offscreen windows, non-persistent
// web store).
import AppKit
import Network
import WebKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

/// Minimal HTTP/1.1 server on 127.0.0.1 (random port): GET /authorize =
/// fake login form, POST /login = 302 to /nativeclient with a fake code,
/// GET /blocked = a conditional-access error page. Records request lines.
final class FakeAuthServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "signin.fake-auth")
    private let lock = NSLock()
    private var seen: [String] = []
    private(set) var port: UInt16 = 0

    static let loginPage = """
    <!doctype html><html><head><title>Sign in to your account</title>
    <meta name="viewport" content="width=device-width">
    <style>
    body{font:15px -apple-system,sans-serif;margin:0;background:#f2f2f2;color:#1b1b1b}
    .card{width:360px;margin:56px auto;background:#fff;padding:36px 40px;box-shadow:0 2px 6px rgba(0,0,0,.2)}
    h1{font-size:22px;font-weight:600;margin:0 0 16px}
    input{width:100%;box-sizing:border-box;font:15px -apple-system;border:0;border-bottom:1px solid #666;padding:6px 0;margin-bottom:24px}
    button{float:right;background:#0067b8;color:#fff;border:0;padding:8px 28px;font:15px -apple-system}
    </style></head><body><div class="card"><div>Contoso</div><h1>Sign in</h1>
    <form id="f" method="post" action="/login">
    <input name="login" type="email" placeholder="Email, phone, or Skype" value="alex.morgan@contoso.example">
    <button id="go" type="submit">Next</button></form><div style="clear:both"></div></div></body></html>
    """

    static let blockedPage = """
    <!doctype html><html><body><h1>You cannot access this right now</h1>
    <p>Error code: AADSTS53003 Access has been blocked by Conditional Access policies.</p></body></html>
    """

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    var requests: [String] { lock.lock(); defer { lock.unlock() }; return seen }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + TestWait.hangCeiling) == .success, let p = listener.port?.rawValue else {
            throw NSError(domain: "FakeAuthServer", code: 1)
        }
        port = p
    }

    func stop() { listener.cancel() }

    var base: String { "http://127.0.0.1:\(port)" }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        read(conn, Data())
    }

    private func read(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, _ in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            guard let head = String(data: buf, encoding: .utf8), head.contains("\r\n\r\n") else {
                if done { conn.cancel() } else { self.read(conn, buf) }
                return
            }
            let line = head.components(separatedBy: "\r\n").first ?? ""
            self.lock.lock(); self.seen.append(line); self.lock.unlock()
            let parts = line.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1].split(separator: "?").first ?? "") : ""
            let response: String
            switch path {
            case "/authorize": response = Self.ok(Self.loginPage)
            case "/blocked": response = Self.ok(Self.blockedPage)
            case "/login":
                response = "HTTP/1.1 302 Found\r\nLocation: \(self.base)/nativeclient?code=FAKE-CODE&state=FAKE-STATE\r\n" +
                    "Content-Length: 0\r\nConnection: close\r\n\r\n"
            default: response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            }
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private static func ok(_ html: String) -> String {
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\n" +
            "Connection: close\r\n\r\n" + html
    }
}

/// Everything the fake core saw.
final class FakeCoreLog: @unchecked Sendable {
    var signedIn = false
    /// Status reports a present but expired AAD token (`.expired`).
    var expired = false
    var browserStarts = 0
    var callbacks: [String] = []
    var cancels = 0
    var deviceStarts = 0
    var opened: [URL] = []
}

@MainActor
final class SignInEmbedTests: XCTestCase {
    private var server: FakeAuthServer!

    override func setUp() async throws {
        server = try FakeAuthServer()
        try server.start()
    }

    override func tearDown() async throws {
        server.stop()
    }

    nonisolated static func status(signedIn: Bool, expired: Bool = false) -> StatusResponse {
        let slot = #"{"present":false,"expired":false}"#
        let aad = expired ? #"{"present":true,"expired":true}"# : slot
        let json = #"{"ok":true,"signed_in":\#(signedIn),"tokens":{"aad":\#(aad),"refresh_present":false,"# +
            #""graph":\#(slot),"ic3":\#(slot),"recorder":\#(slot),"skype":\#(slot),"region_gtms_present":false}}"#
        return try! JSONDecoder().decode(StatusResponse.self, from: Data(json.utf8))
    }

    /// A VM whose core is fake; `authorize` is the page the sign-in loads.
    static func fakeVM(authorize: String, redirect: String, log: FakeCoreLog) -> AuthViewModel {
        AuthViewModel(
            profile: "signin-lane-test",
            status: { status(signedIn: log.signedIn, expired: log.expired && !log.signedIn) },
            start: {
                log.deviceStarts += 1
                let json = #"{"ok":true,"session":"dc-1","verification_uri":"https://microsoft.com/devicelogin","# +
                    #""user_code":"ABCD-1234","message":"m","expires_in":900,"interval":5}"#
                return try JSONDecoder().decode(DeviceStart.self, from: Data(json.utf8))
            },
            openURL: { url in log.opened.append(url); return false },
            copy: { _ in },
            browserStart: {
                log.browserStarts += 1
                let json = #"{"ok":true,"session":"ba-test","authorize_url":"\#(authorize)","# +
                    #""redirect_uri":"\#(redirect)","expires_in":600}"#
                return try JSONDecoder().decode(AuthCodeStart.self, from: Data(json.utf8))
            },
            browserComplete: { _, callback in
                log.callbacks.append(callback)
                log.signedIn = true
                return try JSONDecoder().decode(AuthCodeComplete.self, from: Data(#"{"ok":true,"status":"complete"}"#.utf8))
            },
            browserCancel: { _ in
                log.cancels += 1
                return try JSONDecoder().decode(AuthCodeCancel.self, from: Data(#"{"ok":true,"cancelled":true}"#.utf8))
            })
    }

    /// Signed-out main window content, auto-starting, in an offscreen
    /// window. accountKey "demo" = non-persistent web store (never the
    /// owner's WebKit data); options are not demo, so the flow runs.
    private func mainWindow(_ vm: AuthViewModel) -> (SignInViewController, NSWindow) {
        let chats = ChatListViewModel(fetcher: { _ in ChatsResponse(ok: true, chats: []) })
        let graph = AccountWindowGraph(account: AccountRecord(id: "demo", displayName: "Test"), chats: chats)
        let model = WindowModel(graph: graph, accountKey: "demo", options: LaunchOptions(args: []))
        let vc = SignInViewController(model: model, evidence: nil, auth: vm, autoStart: true)
        let window = OffscreenWindow(contentRect: NSRect(x: -30000, y: -30000, width: 540, height: 400),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = vc
        addTeardownBlock { @MainActor in
            window.close()
            XCTAssertTrue(TestDisplayGuard.windowsOnDisplay().isEmpty, "test window reached a display")
        }
        return (vc, window)
    }

    /// The sheet variants (Sign In Again: `adding` nil, the window's own
    /// auth; Add Account: a fresh `adding` profile), hosted offscreen.
    private func sheetHost(_ vm: AuthViewModel, adding: Bool, otherUsable: Bool, autoStart: Bool = true) -> (SignInViewController, NSWindow) {
        let chats = ChatListViewModel(fetcher: { _ in ChatsResponse(ok: true, chats: []) })
        let graph = AccountWindowGraph(account: AccountRecord(id: "demo", displayName: "Test"), chats: chats)
        let model = WindowModel(graph: graph, accountKey: "demo", options: LaunchOptions(args: []))
        let vc = SignInViewController(model: model, evidence: nil, asSheet: true,
                                      adding: adding ? vm : nil, auth: adding ? nil : vm, autoStart: autoStart,
                                      otherAccountUsable: { otherUsable })
        let window = OffscreenWindow(contentRect: NSRect(x: -30000, y: -30000, width: 480, height: 420),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = vc
        addTeardownBlock { @MainActor in
            window.close()
            XCTAssertTrue(TestDisplayGuard.windowsOnDisplay().isEmpty, "test window reached a display")
        }
        return (vc, window)
    }

    private func until(_ timeout: TimeInterval = 10, _ what: String = "", _ check: () async -> Bool) async throws {
        // `timeout` is ignored: wait on the condition, ceiling only bounds a hang.
        let t0 = DispatchTime.now().uptimeNanoseconds
        while Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e9 < TestWait.hangCeiling {
            if await check() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out: \(what)")
        throw CancellationError()
    }

    // MARK: end to end

    /// 0 accounts: the window starts Microsoft sign-in by itself and shows
    /// it embedded; submitting the fake login redirects with a fake code,
    /// the redirect is caught before it loads, the code goes to the core
    /// and the VM lands signed in. The browser is never opened.
    func testFakeLoginSignsInEmbedded() async throws {
        let log = FakeCoreLog()
        let vm = Self.fakeVM(authorize: "\(server.base)/authorize", redirect: "\(server.base)/nativeclient", log: log)
        let (vc, window) = mainWindow(vm)
        try await until(10, "embedded web") { vc.webSignIn != nil }
        let web = try XCTUnwrap(vc.webSignIn?.web)
        XCTAssertTrue(web.isDescendant(of: try XCTUnwrap(window.contentView)), "sign-in web view must be in the main window")
        XCTAssertNil(window.attachedSheet)
        try await until(10, "login form") {
            (try? await web.evaluateJavaScript("document.getElementById('f') ? 'y' : 'n'") as? String) == "y"
        }
        _ = try? await web.evaluateJavaScript("document.getElementById('f').submit(); 1")
        try await until(10, "signed in") { vm.state == .signedIn }
        XCTAssertEqual(log.callbacks.count, 1)
        XCTAssertTrue(log.callbacks.first?.hasPrefix("\(server.base)/nativeclient?code=FAKE-CODE") == true)
        XCTAssertNil(vc.webSignIn, "the web view leaves once the redirect is caught")
        XCTAssertTrue(log.opened.isEmpty, "the in-app path must never open the browser")
        let lines = server.requests
        XCTAssertTrue(lines.contains { $0.hasPrefix("POST /login") })
        XCTAssertFalse(lines.contains { $0.contains("/nativeclient") }, "redirect must be intercepted, never loaded")
    }

    /// Cancel drops the core session and returns to the start screen.
    func testCancelReturnsToStartScreen() async throws {
        let log = FakeCoreLog()
        let vm = Self.fakeVM(authorize: "\(server.base)/authorize", redirect: "\(server.base)/nativeclient", log: log)
        let (vc, _) = mainWindow(vm)
        try await until(10, "embedded web") { vc.webSignIn != nil }
        vc.webSignIn?.finish(nil)
        XCTAssertNil(vc.webSignIn)
        XCTAssertEqual(vm.state, .signedOut)
        await vm.browserCancelTask?.value
        XCTAssertEqual(log.cancels, 1)
        XCTAssertTrue(log.callbacks.isEmpty)
    }

    /// "Use a Code Instead" leaves the web view for the device-code flow.
    func testUseCodeSwitchesToDeviceCode() async throws {
        let log = FakeCoreLog()
        let vm = Self.fakeVM(authorize: "\(server.base)/authorize", redirect: "\(server.base)/nativeclient", log: log)
        let (vc, _) = mainWindow(vm)
        try await until(10, "embedded web") { vc.webSignIn != nil }
        vc.webSignIn?.useCode()
        XCTAssertNil(vc.webSignIn)
        try await until(5, "device code") { if case .code = vm.state { return true }; return false }
        XCTAssertEqual(log.deviceStarts, 1)
        XCTAssertTrue(log.opened.isEmpty)
    }

    /// A conditional-access error page (AADSTS53003) offers the code flow.
    func testConditionalAccessPageOffersCode() async throws {
        let log = FakeCoreLog()
        let vm = Self.fakeVM(authorize: "\(server.base)/blocked", redirect: "\(server.base)/nativeclient", log: log)
        let (vc, _) = mainWindow(vm)
        try await until(10, "embedded web") { vc.webSignIn != nil }
        let chrome = try XCTUnwrap(vc.webSignIn?.chrome)
        try await until(10, "needs-browser problem") { chrome.problem == .needsBrowser }
    }

    /// A page that can't load shows the load problem (Try Again / code).
    func testUnreachablePageShowsLoadProblem() async throws {
        let log = FakeCoreLog()
        server.stop()
        let dead = "http://127.0.0.1:\(server.port)"
        let vm = Self.fakeVM(authorize: "\(dead)/authorize", redirect: "\(dead)/nativeclient", log: log)
        let (vc, _) = mainWindow(vm)
        try await until(10, "embedded web") { vc.webSignIn != nil }
        let chrome = try XCTUnwrap(vc.webSignIn?.chrome)
        try await until(10, "load problem") { chrome.problem == .loadFailed }
    }

    // MARK: expired / sheet variants (SIGNIN verifier notes)

    /// Expired with nothing else usable (the window's own sign-in screen):
    /// the sign-in itself is the only thing to show, so it starts.
    func testExpiredWindowWithNoUsableAccountAutoStartsEmbedded() async throws {
        let log = FakeCoreLog()
        log.expired = true
        let vm = Self.fakeVM(authorize: "\(server.base)/authorize", redirect: "\(server.base)/nativeclient", log: log)
        let (vc, _) = mainWindow(vm)
        try await until(10, "embedded web") { vc.webSignIn != nil }
        XCTAssertEqual(log.browserStarts, 1)
        XCTAssertTrue(log.opened.isEmpty)
    }

    /// Sign In Again sheet, the expired account is the only one: it starts.
    func testSignInAgainSheetWithNoOtherUsableAccountStartsEmbedded() async throws {
        let log = FakeCoreLog()
        log.expired = true
        let vm = Self.fakeVM(authorize: "\(server.base)/authorize", redirect: "\(server.base)/nativeclient", log: log)
        let (vc, _) = sheetHost(vm, adding: false, otherUsable: false)
        try await until(10, "embedded web") { vc.webSignIn != nil }
        XCTAssertEqual(vc.preferredContentSize, SignInWebController.contentSize)
    }

    /// Sign In Again sheet while another account works: an expired session
    /// PROMPTS (start screen + "Your session expired"), it does not open a
    /// web page by itself. Nothing is started until the person asks.
    func testExpiredSheetWithAnotherUsableAccountPromptsInsteadOfOpeningPage() async throws {
        let log = FakeCoreLog()
        log.expired = true
        let vm = Self.fakeVM(authorize: "\(server.base)/authorize", redirect: "\(server.base)/nativeclient", log: log)
        let (vc, _) = sheetHost(vm, adding: false, otherUsable: true)
        try await until(10, "expired state read") { vm.state == .expired }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(vc.webSignIn, "no web page opens on its own")
        XCTAssertEqual(log.browserStarts, 0)
        XCTAssertTrue(log.opened.isEmpty)
        XCTAssertEqual(vm.state, .expired, "still prompting")
        XCTAssertEqual(vc.preferredContentSize, SignInViewController.sheetSize, "start-screen sheet, not the web size")
        // The prompt's button starts the sign-in (embedded).
        await vm.startBrowserSignIn()
        try await until(10, "embedded web after the click") { vc.webSignIn != nil }
        XCTAssertEqual(log.browserStarts, 1)
    }

    /// Demo scaffolding (`signin?state=expired-sheet`): the canned
    /// expired auth prompts at the start-screen sheet size, with no
    /// page opening on its own. Same controller shape the product's
    /// Sign In Again sheet uses (evidence nil, asSheet, expired auth).
    func testExpiredDemoAuthSheetPromptsAtSheetSize() async throws {
        let vm = AuthViewModel.demo(.expired)
        // autoStart false: the demo route never auto-starts (demo mode),
        // like the app under XCTest (defaultAutoStart off).
        let (vc, _) = sheetHost(vm, adding: false, otherUsable: false, autoStart: false)
        try await until(10, "expired state read") { vm.state == .expired }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(vc.webSignIn, "no web page opens on its own")
        XCTAssertEqual(vm.state, .expired, "still prompting")
        XCTAssertEqual(vc.preferredContentSize, SignInViewController.sheetSize, "start-screen sheet, not the web size")
    }

    /// Add Account sheet (fresh profile, state unknown): starts embedded.
    func testAddAccountSheetStartsEmbedded() async throws {
        let log = FakeCoreLog()
        let vm = Self.fakeVM(authorize: "\(server.base)/authorize", redirect: "\(server.base)/nativeclient", log: log)
        let (vc, window) = sheetHost(vm, adding: true, otherUsable: true)
        try await until(10, "embedded web") { vc.webSignIn != nil }
        XCTAssertEqual(log.browserStarts, 1)
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(vc.preferredContentSize, SignInWebController.contentSize)
    }

    // MARK: client certificate + web process crash

    private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    /// A client-certificate challenge can't be answered in an embedded
    /// view: the footer offers the code flow (needsBrowser) and the
    /// challenge still completes (default handling), never hangs.
    func testClientCertificateChallengeOffersCodeFlow() async throws {
        let log = FakeCoreLog()
        let vm = Self.fakeVM(authorize: "\(server.base)/authorize", redirect: "\(server.base)/nativeclient", log: log)
        let (vc, _) = mainWindow(vm)
        try await until(10, "embedded web") { vc.webSignIn != nil }
        let web = try XCTUnwrap(vc.webSignIn)
        let space = URLProtectionSpace(host: "certauth.login.microsoftonline.com", port: 443, protocol: "https",
                                       realm: nil, authenticationMethod: NSURLAuthenticationMethodClientCertificate)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                                                   previousFailureCount: 0, failureResponse: nil, error: nil,
                                                   sender: ChallengeSender())
        var disposition: URLSession.AuthChallengeDisposition?
        web.webView(web.web, didReceive: challenge) { d, _ in disposition = d }
        XCTAssertEqual(web.chrome.problem, .needsBrowser)
        XCTAssertEqual(disposition, .performDefaultHandling)

        // A server-trust challenge (ordinary TLS) is not a needs-browser step.
        let plain = URLProtectionSpace(host: "127.0.0.1", port: 80, protocol: "http", realm: nil,
                                       authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        web.chrome.problem = nil
        web.webView(web.web, didReceive: URLAuthenticationChallenge(
            protectionSpace: plain, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil,
            error: nil, sender: ChallengeSender())) { _, _ in }
        XCTAssertNil(web.chrome.problem)
    }

    /// The web content process dying shows the native load problem (not a
    /// blank page); Try Again reloads the sign-in page and clears it.
    func testWebProcessCrashShowsNativeErrorAndRetryRecovers() async throws {
        let log = FakeCoreLog()
        let vm = Self.fakeVM(authorize: "\(server.base)/authorize", redirect: "\(server.base)/nativeclient", log: log)
        let (vc, _) = mainWindow(vm)
        try await until(10, "embedded web") { vc.webSignIn != nil }
        let web = try XCTUnwrap(vc.webSignIn)
        try await until(10, "login form") {
            (try? await web.web.evaluateJavaScript("document.getElementById('f') ? 'y' : 'n'") as? String) == "y"
        }
        let before = server.requests.filter { $0.hasPrefix("GET /authorize") }.count
        web.webViewWebContentProcessDidTerminate(web.web)
        XCTAssertEqual(web.chrome.problem, .loadFailed)
        XCTAssertEqual(SignInWebProblem.loadFailed.title, "Can't connect")
        XCTAssertNotNil(vc.webSignIn, "the sign-in stays up so Try Again / Use a Code are reachable")
        web.retry()
        XCTAssertNil(web.chrome.problem, "Try Again clears the error at once")
        try await until(10, "second page load") {
            self.server.requests.filter { $0.hasPrefix("GET /authorize") }.count > before
        }
        try await until(10, "login form again") {
            (try? await web.web.evaluateJavaScript("document.getElementById('f') ? 'y' : 'n'") as? String) == "y"
        }
        XCTAssertNil(web.chrome.problem)
    }

    // MARK: units

    func testRedirectMatchingIsBoundedToTheRedirectURI() {
        let r = "\(server.base)/nativeclient"
        XCTAssertTrue(isBrowserRedirect("\(r)?code=C&state=S", redirectURI: r))
        XCTAssertTrue(isBrowserRedirect("\(r)#code=C", redirectURI: r))
        XCTAssertFalse(isBrowserRedirect("\(r)x?code=C", redirectURI: r))
        XCTAssertFalse(isBrowserRedirect("\(server.base)/authorize", redirectURI: r))
        XCTAssertEqual(SignInPresentation.fakeRedirect(for: URL(string: "\(server.base)/authorize?x=1")!), r)
    }

    func testPageCheckRules() {
        XCTAssertTrue(SignInPageCheck.needsBrowser(url: nil, pageText: "Error AADSTS53000: device must be managed"))
        XCTAssertTrue(SignInPageCheck.needsBrowser(url: URL(string: "https://certauth.login.microsoftonline.com/x"), pageText: ""))
        XCTAssertTrue(SignInPageCheck.needsBrowser(url: URL(string: "https://login.microsoft.com/common/fido/get?x"), pageText: ""))
        XCTAssertFalse(SignInPageCheck.needsBrowser(url: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"),
                                                    pageText: "Approve sign in request. Open your Authenticator app"))
        XCTAssertFalse(SignInPageCheck.needsBrowser(url: URL(string: "https://example.com/fido/x"), pageText: "Pick an account"))
        XCTAssertTrue(SignInPageCheck.isBenign(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        XCTAssertTrue(SignInPageCheck.isBenign(NSError(domain: "WebKitErrorDomain", code: 102)))
        XCTAssertFalse(SignInPageCheck.isBenign(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)))
    }
}
