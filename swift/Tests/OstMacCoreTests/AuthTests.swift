// AuthTests.swift — om-authux lane: sign-in state machine (mocked core).
import XCTest

@testable import OstMacCore

private final class URLBox: @unchecked Sendable {
    var urls: [URL] = []
}

private final class CopyBox: @unchecked Sendable {
    var codes: [String] = []
}

private final class CountBox: @unchecked Sendable {
    var n = 0
}

@MainActor
final class AuthTests: XCTestCase {
    // MARK: - Fixtures

    nonisolated static func status(
        signedIn: Bool, aadPresent: Bool = false,
        aadExpired: Bool = false, refresh: Bool = false
    ) -> StatusResponse {
        func slot(_ p: Bool, _ e: Bool) -> String {
            #"{"present":\#(p),"expired":\#(e)}"#
        }
        let json = #"{"ok":true,"signed_in":\#(signedIn),"tokens":"# +
            #"{"aad":\#(slot(aadPresent, aadExpired)),"# +
            #""refresh_present":\#(refresh),"# +
            #""graph":\#(slot(false, false)),"# +
            #""ic3":\#(slot(false, false)),"# +
            #""recorder":\#(slot(false, false)),"# +
            #""skype":\#(slot(false, false)),"# +
            #""region_gtms_present":false}}"#
        return try! decodeOrThrow(StatusResponse.self, from: Data(json.utf8))
    }

    nonisolated static func start() -> DeviceStart {
        let json = #"{"ok":true,"session":"dc-1","# +
            #""verification_uri":"https://example.com/device","# +
            #""user_code":"WXYZ-9999","message":"m","expires_in":900,"interval":5}"#
        return try! decodeOrThrow(DeviceStart.self, from: Data(json.utf8))
    }

    nonisolated static func poll(_ status: String) -> DevicePoll {
        let json = #"{"ok":true,"status":"\#(status)","interval":5}"#
        return try! decodeOrThrow(DevicePoll.self, from: Data(json.utf8))
    }

    nonisolated static func refreshed(_ b: Bool) -> RefreshResponse {
        try! decodeOrThrow(
            RefreshResponse.self, from: Data(#"{"ok":true,"refreshed":\#(b)}"#.utf8))
    }

    func failingModel() -> AuthViewModel {
        AuthViewModel(
            status: { throw CoreCallError.failed("no status") },
            start: { throw CoreCallError.failed("no start") },
            poll: { _ in throw CoreCallError.failed("no poll") },
            refresh: { throw CoreCallError.failed("no refresh") },
            signOut: { throw CoreCallError.failed("no signout") },
            openURL: { _ in false },
            copy: { _ in })
    }

    // MARK: - Status classification

    func testStatusSignedIn() async {
        let st = Self.status(signedIn: true)
        let vm = AuthViewModel(status: { st })
        XCTAssertEqual(vm.state, .unknown)
        await vm.refreshStatus()
        XCTAssertEqual(vm.state, .signedIn)
    }

    func testStatusSignedOut() async {
        let st = Self.status(signedIn: false)
        let vm = AuthViewModel(status: { st })
        await vm.refreshStatus()
        XCTAssertEqual(vm.state, .signedOut)
    }

    func testStatusExpiredToken() async {
        let st = Self.status(signedIn: false, aadPresent: true, aadExpired: true, refresh: true)
        let vm = AuthViewModel(status: { st })
        await vm.refreshStatus()
        XCTAssertEqual(vm.state, .expired)
    }

    func testClassifyPure() {
        XCTAssertEqual(AuthViewModel.classify(Self.status(signedIn: true)), .signedIn)
        XCTAssertEqual(AuthViewModel.classify(Self.status(signedIn: false)), .signedOut)
        XCTAssertEqual(
            AuthViewModel.classify(
                Self.status(signedIn: false, aadPresent: true, aadExpired: true)),
            .expired)
        // Present but NOT expired yet still unsigned -> signedOut, not expired.
        XCTAssertEqual(
            AuthViewModel.classify(
                Self.status(signedIn: false, aadPresent: true, aadExpired: false)),
            .signedOut)
    }

    func testStatusErrorRetryRecovers() async {
        let st = Self.status(signedIn: false)
        let calls = CountBox()
        let vm = AuthViewModel(status: {
            calls.n += 1
            if calls.n == 1 { throw CoreCallError.failed("disk busy") }
            return st
        })
        await vm.refreshStatus()
        XCTAssertEqual(vm.state, .error("disk busy"))
        XCTAssertEqual(vm.errorRetry, .status)
        await vm.retry()
        XCTAssertEqual(vm.state, .signedOut)
        XCTAssertEqual(calls.n, 2)
    }

    // MARK: - Device-code flow

    func testSignInSuccessReachesCode() async {
        let d = Self.start()
        let vm = AuthViewModel(
            status: { Self.status(signedIn: false) },
            start: { d })
        await vm.refreshStatus()
        await vm.signIn()
        guard case let .code(info) = vm.state else {
            return XCTFail("expected code, got \(vm.state)")
        }
        XCTAssertEqual(info.session, "dc-1")
        XCTAssertEqual(info.userCode, "WXYZ-9999")
        XCTAssertEqual(info.verificationURI, "https://example.com/device")
    }

    func testSignInFailure() async {
        let vm = failingModel()
        await vm.signIn()
        XCTAssertEqual(vm.state, .error("no start"))
        XCTAssertEqual(vm.errorRetry, .signIn)
    }

    func testSignInBlockedWhilePolling() async {
        let d = Self.start()
        let vm = AuthViewModel(
            start: { d },
            openURL: { _ in false })
        vm.pollIntervalOverride = 3600
        await vm.signIn()
        vm.openBrowser() // code -> polling
        guard case .polling = vm.state else {
            return XCTFail("expected polling, got \(vm.state)")
        }
        await vm.signIn() // no-op: already in flow
        guard case .polling = vm.state else {
            return XCTFail("signIn clobbered polling: \(vm.state)")
        }
        vm.stopPolling()
    }

    func testOpenBrowserStartsPolling() async {
        let d = Self.start()
        let opened = URLBox()
        let vm = AuthViewModel(
            start: { d },
            openURL: {
                opened.urls.append($0)
                return true
            })
        vm.pollIntervalOverride = 3600
        await vm.signIn()
        vm.openBrowser()
        guard case let .polling(info, attempts) = vm.state else {
            return XCTFail("expected polling, got \(vm.state)")
        }
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(info.session, "dc-1")
        XCTAssertEqual(opened.urls, [URL(string: "https://example.com/device")!])
        vm.stopPolling()
    }

    func testOpenBrowserInPollingReopensWithoutReset() async {
        let d = Self.start()
        let opened = URLBox()
        let vm = AuthViewModel(
            start: { d },
            poll: { _ in Self.poll("pending") },
            openURL: {
                opened.urls.append($0)
                return true
            })
        vm.pollIntervalOverride = 3600
        await vm.signIn()
        vm.openBrowser()
        await vm.pollOnce() // attempts -> 1
        vm.openBrowser() // re-open, attempts preserved
        guard case let .polling(_, attempts) = vm.state else {
            return XCTFail("expected polling, got \(vm.state)")
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(opened.urls.count, 2)
        vm.stopPolling()
    }

    func testStartCheckingSkipsBrowser() async {
        let d = Self.start()
        let opened = URLBox()
        let vm = AuthViewModel(
            start: { d },
            openURL: {
                opened.urls.append($0)
                return true
            })
        vm.pollIntervalOverride = 3600
        await vm.signIn()
        vm.startChecking()
        guard case .polling = vm.state else {
            return XCTFail("expected polling, got \(vm.state)")
        }
        XCTAssertTrue(opened.urls.isEmpty)
        vm.stopPolling()
    }

    func testCopyCode() async {
        let d = Self.start()
        let copied = CopyBox()
        let vm = AuthViewModel(
            start: { d },
            copy: { copied.codes.append($0) })
        await vm.signIn()
        XCTAssertFalse(vm.copied)
        vm.copyCode()
        XCTAssertTrue(vm.copied)
        XCTAssertEqual(copied.codes, ["WXYZ-9999"])
    }

    func testCopyCodeNoopOutsideFlow() {
        let copied = CopyBox()
        let vm = AuthViewModel(copy: { copied.codes.append($0) })
        vm.copyCode()
        XCTAssertFalse(vm.copied)
        XCTAssertTrue(copied.codes.isEmpty)
    }

    // MARK: - Polling

    func testPollPendingIncrements() async {
        let d = Self.start()
        let vm = AuthViewModel(
            start: { d },
            poll: { _ in Self.poll("pending") })
        vm.pollIntervalOverride = 3600
        await vm.signIn()
        vm.startChecking()
        await vm.pollOnce()
        await vm.pollOnce()
        guard case let .polling(_, attempts) = vm.state else {
            return XCTFail("expected polling, got \(vm.state)")
        }
        XCTAssertEqual(attempts, 2)
        vm.stopPolling()
    }

    func testPollCompleteLandsSignedIn() async {
        let d = Self.start()
        let vm = AuthViewModel(
            status: { Self.status(signedIn: true) },
            start: { d },
            poll: { _ in Self.poll("complete") })
        vm.pollIntervalOverride = 3600
        await vm.signIn()
        vm.startChecking()
        await vm.pollOnce()
        XCTAssertEqual(vm.state, .signedIn)
    }

    func testPollFatalError() async {
        let d = Self.start()
        let vm = AuthViewModel(
            start: { d },
            poll: { _ in throw CoreCallError.failed("device_expired: start again") })
        vm.pollIntervalOverride = 3600
        await vm.signIn()
        vm.startChecking()
        await vm.pollOnce()
        XCTAssertEqual(vm.state, .error("device_expired: start again"))
        XCTAssertEqual(vm.errorRetry, .signIn)
    }

    func testPollNoopOutsidePolling() async {
        let seen = CountBox()
        let vm = AuthViewModel(poll: { _ in
            seen.n += 1
            return Self.poll("complete")
        })
        await vm.pollOnce()
        XCTAssertEqual(seen.n, 0)
        XCTAssertEqual(vm.state, .unknown)
    }

    func testCancelReturnsToOrigin() async {
        let d = Self.start()
        let vm = AuthViewModel(
            status: { Self.status(
                signedIn: false, aadPresent: true, aadExpired: true, refresh: true) },
            start: { d })
        vm.pollIntervalOverride = 3600
        await vm.refreshStatus()
        XCTAssertEqual(vm.state, .expired)
        await vm.signIn() // expired -> starting -> code
        guard case .code = vm.state else {
            return XCTFail("expected code, got \(vm.state)")
        }
        vm.cancel()
        XCTAssertEqual(vm.state, .expired)
    }

    // MARK: - Refresh / expiry

    func testRetryRefreshSuccess() async {
        let expired = Self.status(
            signedIn: false, aadPresent: true, aadExpired: true, refresh: true)
        let calls = CountBox()
        let vm = AuthViewModel(
            status: {
                calls.n += 1
                return calls.n == 1 ? expired : Self.status(signedIn: true)
            },
            refresh: { Self.refreshed(true) })
        await vm.refreshStatus()
        XCTAssertEqual(vm.state, .expired)
        await vm.retryRefresh()
        XCTAssertEqual(vm.state, .signedIn)
    }

    func testRetryRefreshNoToken() async {
        let vm = AuthViewModel(
            status: { Self.status(
                signedIn: false, aadPresent: true, aadExpired: true, refresh: true) },
            refresh: { Self.refreshed(false) })
        await vm.refreshStatus()
        XCTAssertEqual(vm.state, .expired)
        await vm.retryRefresh()
        XCTAssertEqual(
            vm.state,
            .refreshFailed("No refresh token stored. Sign in again."))
    }

    func testRetryRefreshErrorThenRetryAgain() async {
        let calls = CountBox()
        let vm = AuthViewModel(
            status: { Self.status(
                signedIn: false, aadPresent: true, aadExpired: true, refresh: true) },
            refresh: {
                calls.n += 1
                if calls.n == 1 { throw CoreCallError.failed("token request: timeout") }
                return Self.refreshed(true)
            })
        await vm.refreshStatus()
        await vm.retryRefresh()
        XCTAssertEqual(vm.state, .refreshFailed("token request: timeout"))
        // refreshFailed re-enters retryRefresh (second attempt succeeds,
        // but status still reports expired fixtures -> back to expired).
        await vm.retryRefresh()
        XCTAssertEqual(vm.state, .expired)
        XCTAssertEqual(calls.n, 2)
    }

    // MARK: - Sign-out

    func testSignOutSuccess() async {
        let vm = AuthViewModel(
            status: { Self.status(signedIn: true) },
            signOut: {
                try decodeOrThrow(
                    SignOutResponse.self, from: Data(#"{"ok":true}"#.utf8))
            })
        await vm.refreshStatus()
        XCTAssertEqual(vm.state, .signedIn)
        await vm.signOut()
        XCTAssertEqual(vm.state, .signedOut)
        XCTAssertNil(vm.status)
    }

    func testSignOutFailureRetryRecovers() async {
        let calls = CountBox()
        let vm = AuthViewModel(signOut: {
            calls.n += 1
            if calls.n == 1 { throw CoreCallError.failed("config locked") }
            return try decodeOrThrow(
                SignOutResponse.self, from: Data(#"{"ok":true}"#.utf8))
        })
        await vm.signOut()
        XCTAssertEqual(vm.state, .error("config locked"))
        XCTAssertEqual(vm.errorRetry, .signOut)
        await vm.retry()
        XCTAssertEqual(vm.state, .signedOut)
    }

    // MARK: - Demo (screenshots; never touches core)

    func testDemoIgnoresCoreActions() async {
        let vm = AuthViewModel.demo(.code(.demo))
        XCTAssertTrue(vm.isDemo)
        await vm.refreshStatus()
        await vm.signIn()
        await vm.pollOnce()
        await vm.retryRefresh()
        await vm.signOut()
        vm.openBrowser()
        vm.startChecking()
        guard case .code = vm.state else {
            return XCTFail("demo state moved: \(vm.state)")
        }
        // Copy still gives UI feedback (injected no-op, no pasteboard).
        vm.copyCode()
        XCTAssertTrue(vm.copied)
    }

    func testRefreshResponseDecode() throws {
        let yes = try decodeOrThrow(
            RefreshResponse.self, from: Data(#"{"ok":true,"refreshed":true}"#.utf8))
        XCTAssertTrue(yes.refreshed)
        XCTAssertNil(yes.tokens)
        let no = try decodeOrThrow(
            RefreshResponse.self, from: Data(#"{"ok":true,"refreshed":false}"#.utf8))
        XCTAssertFalse(no.refreshed)
    }

    func testSignOutResponseDecode() throws {
        let r = try decodeOrThrow(
            SignOutResponse.self, from: Data(#"{"ok":true}"#.utf8))
        XCTAssertTrue(r.ok)
    }

    // MARK: - Test guard (never launch the real browser under XCTest)

    func testDefaultOpenURLNoopsUnderXCTest() {
        XCTAssertNotNil(NSClassFromString("XCTestCase"))
        XCTAssertFalse(
            AuthViewModel.defaultOpenURL(URL(string: "https://example.com/device")!))
    }

    // MARK: - Profiles (d1-accounts: one VM per account)

    func testProfileDefaultsToLegacy() {
        XCTAssertEqual(AuthViewModel().profile, AccountProfile.defaultID)
        XCTAssertEqual(
            AuthViewModel(status: { Self.status(signedIn: true) }).profile,
            AccountProfile.defaultID)
    }

    func testTwoProfileVMsCoexistAndRefreshFailedIsolates() async {
        let ok = Self.status(signedIn: true)
        let good = AuthViewModel(profile: "acct-a", status: { ok })
        let bad = AuthViewModel(
            profile: "acct-b",
            status: {
                Self.status(
                    signedIn: false, aadPresent: true, aadExpired: true,
                    refresh: true)
            },
            refresh: { throw CoreCallError.failed("stale grant") })
        await good.refreshStatus()
        await bad.refreshStatus()
        XCTAssertEqual(good.state, .signedIn)
        XCTAssertEqual(bad.state, .expired)
        // Refresh-failed on B leaves A signed in.
        await bad.retryRefresh()
        if case .refreshFailed = bad.state {} else {
            XCTFail("expected refreshFailed, got \(bad.state)")
        }
        XCTAssertEqual(good.state, .signedIn)
    }

    func testRepointSwapsProfileAndResetsState() async {
        let vm = AuthViewModel(
            profile: "acct-a", status: { Self.status(signedIn: true) })
        await vm.refreshStatus()
        XCTAssertEqual(vm.state, .signedIn)
        vm.repoint(profile: "acct-b", live: false)
        XCTAssertEqual(vm.profile, "acct-b")
        XCTAssertEqual(vm.state, .unknown)
    }
}
