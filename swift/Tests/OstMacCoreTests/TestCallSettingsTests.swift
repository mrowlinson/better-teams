// Test-call Settings entry: pure UI-state mapping + demo echo-live
// reuse. No core/network (pure describe + offline demo store).
import XCTest

@testable import OstMacCore

final class TestCallSettingsTests: XCTestCase {
    func testSignedOutDisablesPlace() {
        let s = TestCallSettings.describe(signedIn: false, busy: false, call: nil)
        XCTAssertEqual(s.placeLabel, "Place test call")
        XCTAssertFalse(s.placeEnabled)
        XCTAssertFalse(s.showEnd)
        XCTAssertTrue(s.status.contains("Sign in"))
    }

    func testIdleSignedInOffersPlace() {
        let s = TestCallSettings.describe(signedIn: true, busy: false, call: nil)
        XCTAssertTrue(s.placeEnabled)
        XCTAssertFalse(s.showEnd)
        XCTAssertTrue(s.status.contains("echo bot"))
    }

    func testBusyDisablesWhilePlacing() {
        let s = TestCallSettings.describe(signedIn: true, busy: true, call: nil)
        XCTAssertFalse(s.placeEnabled)
        XCTAssertFalse(s.showEnd)
        XCTAssertTrue(s.status.contains("Placing"))
    }

    func testConnectedEchoShowsEndWithLoopbackHint() {
        let call = CallInfo(
            id: "c1", dir: "out", peer: "8:orgid:echo", peerName: "Echo (Test Call)",
            thread: "19:t", state: "connected", liveMedia: true)
        let s = TestCallSettings.describe(signedIn: true, busy: false, call: call)
        XCTAssertFalse(s.placeEnabled)
        XCTAssertTrue(s.showEnd)
        XCTAssertTrue(s.endEnabled)
        XCTAssertTrue(s.status.contains("your own audio back"))
    }

    func testConnectedEchoWithoutMediaSaysSo() {
        let call = CallInfo(
            id: "c1", dir: "out", peer: "8:orgid:echo", peerName: "Echo (Test Call)",
            thread: "19:t", state: "connected")
        let s = TestCallSettings.describe(signedIn: true, busy: false, call: call)
        XCTAssertTrue(s.showEnd)
        XCTAssertTrue(s.status.contains("signaling only"))
    }

    func testOtherActiveCallStillOffersEnd() {
        // Shared slot: a non-test call shows generic status, never a
        // second place button (core would refuse with busy anyway).
        let call = CallInfo(
            id: "c2", dir: "in", peer: "8:orgid:aaa", peerName: "Doe, Jane",
            state: "connected", liveMedia: true)
        let s = TestCallSettings.describe(signedIn: true, busy: false, call: call)
        XCTAssertFalse(s.placeEnabled)
        XCTAssertTrue(s.showEnd)
        XCTAssertTrue(s.status.contains("Doe, Jane"))
        XCTAssertFalse(s.status.contains("your own audio back"))
    }

    func testEndedCallReturnsToIdle() {
        let call = CallInfo(
            id: "c1", dir: "out", peer: "8:orgid:echo", peerName: "Echo (Test Call)",
            thread: "19:t", state: "ended")
        let s = TestCallSettings.describe(signedIn: true, busy: false, call: call)
        XCTAssertTrue(s.placeEnabled)
        XCTAssertFalse(s.showEnd)
    }

    func testDemoEchoLiveConnectsWithLiveMedia() {
        // Reuse proof: the Settings place path is CallStore.echoLive,
        // which flips the demo slot to connected + live media offline.
        let s = CallStore(demo: true)
        s.echoLive()
        XCTAssertEqual(s.call?.state, "connected")
        XCTAssertEqual(s.call?.liveMedia, true)
        s.end()
        XCTAssertNil(s.call)
    }
}
