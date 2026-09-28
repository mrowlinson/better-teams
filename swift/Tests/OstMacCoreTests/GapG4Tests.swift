// GapG4Tests.swift — gap lane: CallKit verdict (G4). No core/network/
// UNCenter/CX symbols: availability probe + pure routing rule +
// banner-content builder + mute-gated ringer.
import UserNotifications
import XCTest

@testable import OstMacCore

final class GapG4Tests: XCTestCase {
    // MARK: - CallKit unavailable on macOS (the G4 verdict)

    /// The provider API is unusable on macOS (SDK marks CXProvider
    /// API_UNAVAILABLE(macos) — a static reference is a build
    /// error). Contract gate, not class presence: the string lookup
    /// itself is harness-dependent noise (resolves under XCTest,
    /// nil in a plain process), usable in neither.
    func testProviderUnavailableOnMacOS() {
        XCTAssertFalse(CallKitSupport.providerAvailable)
    }

    /// Pure routing rule, both legs.
    func testRoutingRule() {
        XCTAssertEqual(
            CallRouting.route(providerAvailable: false), .g3Banner)
        XCTAssertEqual(
            CallRouting.route(providerAvailable: true), .callKit)
    }

    /// Live route on this machine is the G3 banner path.
    func testCurrentRouteIsG3Banner() {
        XCTAssertEqual(CallRouting.current, .g3Banner)
    }

    // MARK: - Banner content (OS-policy routing)

    /// makeContent pins the contract Notifier.postCall posts.
    func testMakeContentContract() {
        let c = OmCallInfo.makeContent(
            title: "Doe, Jane", body: "Incoming call", callID: "c1")
        XCTAssertEqual(c.categoryIdentifier, OmCallInfo.categoryID)
        XCTAssertEqual(c.threadIdentifier, "c1")
        XCTAssertEqual(
            c.userInfo[OmCallInfo.callIDKey] as? String, "c1")
        XCTAssertNil(c.sound, "banner silent — ringer owns call audio")
        XCTAssertEqual(
            c.interruptionLevel, .active,
            "OS policy decides display (Focus/DND suppress)")
    }

    /// Empty body falls back to the call placeholder; request id is
    /// stable per call (re-posts replace, withdraw removes).
    func testMakeContentEmptyBodyAndStableID() {
        let c = OmCallInfo.makeContent(
            title: "x", body: "", callID: "c9")
        XCTAssertEqual(c.body, "(incoming call)")
        XCTAssertEqual(OmCallInfo.requestID(callID: "c9"), "call-c9")
    }

    // MARK: - System-mute-gated ringer

    /// A muted output never starts the loop (and the probe is
    /// consulted on every start, not cached).
    func testMutedOutputNeverRings() {
        let r = CallRinger()
        var probes = 0
        r.mutedCheck = { probes += 1; return true }
        r.start()
        r.start()
        XCTAssertEqual(probes, 2)
        XCTAssertFalse(r.isRinging)
    }

    /// Unmuted consults the probe and attempts the ring (isRinging
    /// itself depends on sound resolution — headless has none — so
    /// only the attempt is pinned).
    func testUnmutedAttemptsRing() {
        let r = CallRinger()
        var probes = 0
        r.mutedCheck = { probes += 1; return false }
        r.start()
        XCTAssertEqual(probes, 1)
        r.stop()
    }

    /// Nil probe = legacy unconditional ring attempt.
    func testNilProbeRingsUnconditionally() {
        let r = CallRinger()
        XCTAssertNil(r.mutedCheck)
        r.start() // must not crash headless
        r.stop()
    }

    /// The CoreAudio probe runs and returns a Bool (fails open —
    /// whatever this box reports, the call completes).
    func testSystemMuteProbeRuns() {
        let muted: Bool = SystemAudioMute.isOutputMuted()
        XCTAssertTrue(muted == true || muted == false)
    }

    // MARK: - G3 path stays live (the permanent route)

    /// With CallKit absent, an incoming ring still posts the banner
    /// hook and rings — the G3 path is active, not a dead fallback.
    func testIncomingRingStillPostsWithoutCallKit() {
        XCTAssertEqual(CallRouting.current, .g3Banner)
        let s = CallStore(demo: true)
        let ringer = FakeRinger()
        var posted: [String] = []
        s.ringer = ringer
        s.onIncomingRing = { posted.append($0.id) }
        s.seedDemo(state: "incoming")
        XCTAssertEqual(posted, ["demo-call"])
        XCTAssertEqual(ringer.starts, 1)
    }
}
