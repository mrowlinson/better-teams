// BrowserAuthTests.swift — om-pwauth lane: browser-capture fallback (mocked core).
import XCTest

@testable import OstMacCore

private final class SeenBox: @unchecked Sendable {
    var sessions: [String] = []
    var callbacks: [String] = []
}

@MainActor
final class BrowserAuthTests: XCTestCase {
    // MARK: - Fixtures

    nonisolated static func browserStart() -> AuthCodeStart {
        let json = #"{"ok":true,"session":"ba-1","# +
            #""authorize_url":"https://login.example/authorize?x=1","# +
            #""redirect_uri":"https://login.example/nativeclient","expires_in":600}"#
        return try! decodeOrThrow(AuthCodeStart.self, from: Data(json.utf8))
    }

    nonisolated static func browserComplete(_ status: String) -> AuthCodeComplete {
        let json = #"{"ok":true,"status":"\#(status)"}"#
        return try! decodeOrThrow(AuthCodeComplete.self, from: Data(json.utf8))
    }

    nonisolated static func browserCancel() -> AuthCodeCancel {
        try! decodeOrThrow(
            AuthCodeCancel.self, from: Data(#"{"ok":true,"cancelled":true}"#.utf8))
    }

    // MARK: - Start

    func testBrowserStartReachesBrowser() async {
        let d = Self.browserStart()
        let vm = AuthViewModel(
            status: { AuthTests.status(signedIn: false) },
            browserStart: { d })
        await vm.refreshStatus()
        await vm.startBrowserSignIn()
        guard case let .browser(info) = vm.state else {
            return XCTFail("expected browser, got \(vm.state)")
        }
        XCTAssertEqual(info.session, "ba-1")
        XCTAssertEqual(info.authorizeURL, "https://login.example/authorize?x=1")
        XCTAssertEqual(info.redirectURI, "https://login.example/nativeclient")
    }

    func testBrowserStartFailureRetryReenters() async {
        let seen = SeenBox()
        let vm = AuthViewModel(browserStart: {
            seen.sessions.append("start")
            if seen.sessions.count == 1 { throw CoreCallError.failed("no core") }
            return Self.browserStart()
        })
        await vm.startBrowserSignIn()
        XCTAssertEqual(vm.state, .error("no core"))
        XCTAssertEqual(vm.errorRetry, .browser)
        await vm.retry()
        guard case .browser = vm.state else {
            return XCTFail("retry did not re-enter browser: \(vm.state)")
        }
        XCTAssertEqual(seen.sessions.count, 2)
    }

    func testBrowserStartBlockedInsideDeviceFlow() async {
        let vm = AuthViewModel(
            start: { AuthTests.start() },
            browserStart: { Self.browserStart() })
        await vm.signIn() // -> code
        guard case .code = vm.state else {
            return XCTFail("expected code, got \(vm.state)")
        }
        await vm.startBrowserSignIn() // no-op: cancel device flow first
        guard case .code = vm.state else {
            return XCTFail("browser start clobbered device flow: \(vm.state)")
        }
    }

    func testDeviceSignInBlockedInsideBrowserFlow() async {
        let vm = AuthViewModel(
            start: { AuthTests.start() },
            browserStart: { Self.browserStart() })
        await vm.startBrowserSignIn() // -> browser
        await vm.signIn() // no-op
        guard case .browser = vm.state else {
            return XCTFail("device start clobbered browser flow: \(vm.state)")
        }
    }

    // MARK: - Complete

    func testBrowserCompleteLandsSignedIn() async {
        let seen = SeenBox()
        let vm = AuthViewModel(
            status: { AuthTests.status(signedIn: true) },
            browserStart: { Self.browserStart() },
            browserComplete: { session, callback in
                seen.sessions.append(session)
                seen.callbacks.append(callback)
                return Self.browserComplete("complete")
            })
        await vm.startBrowserSignIn()
        await vm.completeBrowserSignIn(callbackURL: "https://login.example/nativeclient?code=C&state=S")
        XCTAssertEqual(vm.state, .signedIn)
        XCTAssertEqual(seen.sessions, ["ba-1"])
        XCTAssertEqual(
            seen.callbacks,
            ["https://login.example/nativeclient?code=C&state=S"])
    }

    func testBrowserCompleteDeniedIsErrorWithBrowserRetry() async {
        let vm = AuthViewModel(
            browserStart: { Self.browserStart() },
            browserComplete: { _, _ in
                throw CoreCallError.failed("authcode_denied: access_denied: No")
            })
        await vm.startBrowserSignIn()
        await vm.completeBrowserSignIn(callbackURL: "https://login.example/nativeclient?error=access_denied")
        XCTAssertEqual(vm.state, .error("authcode_denied: access_denied: No"))
        XCTAssertEqual(vm.errorRetry, .browser)
    }

    func testBrowserCompleteUnexpectedStatusIsError() async {
        let vm = AuthViewModel(
            browserStart: { Self.browserStart() },
            browserComplete: { _, _ in Self.browserComplete("pending") })
        await vm.startBrowserSignIn()
        await vm.completeBrowserSignIn(callbackURL: "https://login.example/x?code=C")
        XCTAssertEqual(vm.state, .error("browser sign-in returned pending"))
        XCTAssertEqual(vm.errorRetry, .browser)
    }

    func testBrowserCompleteNoopOutsideBrowser() async {
        let seen = SeenBox()
        let vm = AuthViewModel(browserComplete: { session, callback in
            seen.sessions.append(session)
            seen.callbacks.append(callback)
            return Self.browserComplete("complete")
        })
        await vm.completeBrowserSignIn(callbackURL: "https://login.example/x?code=C")
        XCTAssertTrue(seen.sessions.isEmpty)
        XCTAssertEqual(vm.state, .unknown)
    }

    // MARK: - Cancel

    func testCancelBrowserReturnsToOrigin() async {
        let seen = SeenBox()
        let vm = AuthViewModel(
            status: { AuthTests.status(signedIn: false) },
            browserStart: { Self.browserStart() },
            browserCancel: {
                seen.sessions.append($0)
                return Self.browserCancel()
            })
        await vm.refreshStatus()
        XCTAssertEqual(vm.state, .signedOut)
        await vm.startBrowserSignIn()
        guard case .browser = vm.state else {
            return XCTFail("expected browser, got \(vm.state)")
        }
        vm.cancelBrowser()
        XCTAssertEqual(vm.state, .signedOut)
        // Detached cancel lands shortly; poll briefly (no sleep loops).
        for _ in 0..<50 where seen.sessions.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(seen.sessions, ["ba-1"])
    }

    func testCancelBrowserFromErrorSkipsErrorScreen() async {
        let vm = AuthViewModel(
            status: { AuthTests.status(signedIn: false) },
            browserStart: { Self.browserStart() },
            browserComplete: { _, _ in
                throw CoreCallError.failed("authcode_exchange: boom")
            },
            browserCancel: { _ in Self.browserCancel() })
        await vm.refreshStatus() // origin = signedOut
        await vm.startBrowserSignIn()
        await vm.completeBrowserSignIn(callbackURL: "https://login.example/x?code=C")
        XCTAssertEqual(vm.state, .error("authcode_exchange: boom"))
        await vm.startBrowserSignIn() // error -> browser (origin kept)
        guard case .browser = vm.state else {
            return XCTFail("expected browser, got \(vm.state)")
        }
        vm.cancelBrowser()
        XCTAssertEqual(vm.state, .signedOut) // not .error
    }

    func testCancelBrowserNoopOutsideBrowser() {
        let vm = AuthViewModel.demo(.signedOut)
        vm.cancelBrowser()
        XCTAssertEqual(vm.state, .signedOut)
    }

    // MARK: - Redirect matching (token plumbing, pure)

    func testIsBrowserRedirect() {
        let redir = "https://login.microsoftonline.com/common/oauth2/nativeclient"
        XCTAssertTrue(isBrowserRedirect(redir + "?code=C&state=S", redirectURI: redir))
        XCTAssertTrue(isBrowserRedirect(redir + "#code=C", redirectURI: redir))
        XCTAssertTrue(isBrowserRedirect(redir, redirectURI: redir))
        XCTAssertTrue(isBrowserRedirect(
            "HTTPS://LOGIN.MICROSOFTONLINE.COM/COMMON/OAUTH2/NATIVECLIENT?code=C",
            redirectURI: redir))
        XCTAssertFalse(isBrowserRedirect(
            "https://login.microsoftonline.com/common/oauth2/authorize?x=1",
            redirectURI: redir))
        // Host-suffix game must not match.
        XCTAssertFalse(isBrowserRedirect(
            redir + ".evil.example/?code=C",
            redirectURI: redir))
        XCTAssertFalse(isBrowserRedirect("", redirectURI: redir))
    }

    // MARK: - Models

    func testAuthCodeResponseDecode() throws {
        let s = Self.browserStart()
        XCTAssertEqual(s.session, "ba-1")
        XCTAssertEqual(s.expires_in, 600)
        let c = Self.browserComplete("complete")
        XCTAssertEqual(c.status, "complete")
        XCTAssertNil(c.tokens)
        let x = Self.browserCancel()
        XCTAssertTrue(x.cancelled)
    }

    func testBrowserDemoStateIgnoresCoreActions() async {
        let vm = AuthViewModel.demo(.browser(.demo))
        await vm.startBrowserSignIn()
        await vm.completeBrowserSignIn(callbackURL: "https://x/?code=C")
        guard case .browser = vm.state else {
            return XCTFail("demo state moved: \(vm.state)")
        }
    }
}
