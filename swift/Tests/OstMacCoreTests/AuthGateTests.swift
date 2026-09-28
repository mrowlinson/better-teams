// AuthGateTests.swift — om-auth-gate lane: 13-state gate helpers.
import XCTest

@testable import OstMacCore

@MainActor
final class AuthGateTests: XCTestCase {
    nonisolated static func status(signedIn: Bool) -> StatusResponse {
        let json = #"{"ok":true,"signed_in":\#(signedIn),"tokens":"# +
            #"{"aad":{"present":true,"expired":false},"refresh_present":true,"# +
            #""graph":{"present":true,"expired":false},"ic3":{"present":true,"expired":false},"# +
            #""recorder":{"present":true,"expired":false},"skype":{"present":true,"expired":false},"# +
            #""region_gtms_present":true}}"#
        return try! decodeOrThrow(StatusResponse.self, from: Data(json.utf8))
    }

    /// All 13 states with their gate bit. Only signedIn opens the gate.
    nonisolated static func allStates() -> [(AuthState, Bool)] {
        [
            (.unknown, false),
            (.signedOut, false),
            (.starting, false),
            (.code(.demo), false),
            (.polling(.demo, attempts: 0), false),
            (.browser(.demo), false),
            (.browserWorking(.demo), false),
            (.signedIn, true),
            (.signingOut, false),
            (.expired, false),
            (.refreshing, false),
            (.refreshFailed("r"), false),
            (.error("e"), false),
        ]
    }

    func testGateOpensOnlyWhenSignedIn() {
        let states = Self.allStates()
        XCTAssertEqual(states.count, 13) // AuthState has exactly 13 cases
        for (s, open) in states {
            XCTAssertEqual(s.isSignedIn, open, "\(s)")
            XCTAssertEqual(s.allowsContent, open, "\(s)")
        }
    }

    func testViewModelMirrorsGate() {
        XCTAssertTrue(AuthViewModel.demo(.signedIn).isSignedIn)
        XCTAssertFalse(AuthViewModel.demo(.signedOut).isSignedIn)
        XCTAssertFalse(AuthViewModel.demo(.expired).isSignedIn)
    }

    func testAccountFromGate() {
        func row(_ s: AuthState, status: StatusResponse? = nil) -> AccountInfo {
            AccountInfo.from(authState: s, status: status)
        }
        XCTAssertEqual(row(.unknown), AccountInfo(signedIn: false, detail: "Checking session…"))
        XCTAssertEqual(row(.signedOut), AccountInfo(signedIn: false, detail: "Not signed in"))
        XCTAssertEqual(row(.starting), AccountInfo(signedIn: false, detail: "Contacting Microsoft…"))
        XCTAssertEqual(
            row(.code(.demo)),
            AccountInfo(signedIn: false, detail: "Waiting for browser sign-in…"))
        XCTAssertEqual(
            row(.polling(.demo, attempts: 0)),
            AccountInfo(signedIn: false, detail: "Waiting for browser sign-in…"))
        XCTAssertEqual(
            row(.polling(.demo, attempts: 2)),
            AccountInfo(signedIn: false, detail: "Waiting for browser sign-in… (check 3)"))
        XCTAssertEqual(
            row(.browser(.demo)),
            AccountInfo(signedIn: false, detail: "Signing in with browser…"))
        XCTAssertEqual(
            row(.browserWorking(.demo)),
            AccountInfo(signedIn: false, detail: "Completing browser sign-in…"))
        XCTAssertEqual(
            row(.signedIn, status: Self.status(signedIn: true)),
            AccountInfo(signedIn: true, detail: "Signed in · tokens 7/7"))
        XCTAssertEqual(
            row(.signedIn),
            AccountInfo(signedIn: true, detail: "Signed in"))
        XCTAssertEqual(row(.signingOut), AccountInfo(signedIn: false, detail: "Signing out…"))
        XCTAssertEqual(row(.expired), AccountInfo(signedIn: false, detail: "Session expired"))
        XCTAssertEqual(row(.refreshing), AccountInfo(signedIn: false, detail: "Refreshing session…"))
        XCTAssertEqual(
            row(.refreshFailed("token request: timeout")),
            AccountInfo(signedIn: false, detail: "token request: timeout"))
        XCTAssertEqual(
            row(.error("device_start: network unreachable")),
            AccountInfo(signedIn: false, detail: "device_start: network unreachable"))
    }
}
