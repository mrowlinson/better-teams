// GapG3G5Tests.swift — gap lane: incoming-call banner+ring (G3),
// Focus default-on + failure-diagnostic (G5). No core/network/UNCenter:
// CallStore hooks + FakeRinger + the pure route/category map.
import UserNotifications
import XCTest

@testable import OstMacCore

final class GapG3G5Tests: XCTestCase {
    // MARK: - G3 harness (ring hooks + fake ringer)

    private final class RingLog {
        var posted: [String] = []
        var withdrawn: [String] = []
    }

    /// Demo store wired like the live app (ringer + post/withdraw hooks).
    private func wiredStore(log: RingLog, ringer: FakeRinger) -> CallStore {
        let s = CallStore(demo: true)
        s.ringer = ringer
        s.onIncomingRing = { log.posted.append($0.id) }
        s.onRingEnded = { log.withdrawn.append($0) }
        return s
    }

    // MARK: - G3: incoming phase → banner + ring

    /// Entering inviting on an incoming call posts once and rings.
    func testIncomingRingPostsBannerAndRings() {
        let (log, ringer) = (RingLog(), FakeRinger())
        let s = wiredStore(log: log, ringer: ringer)
        s.seedDemo(state: "incoming")
        XCTAssertEqual(log.posted, ["demo-call"])
        XCTAssertEqual(ringer.starts, 1)
        XCTAssertTrue(ringer.isRinging)
        XCTAssertTrue(log.withdrawn.isEmpty)
    }

    /// Repeat phase sets for the same ring never re-post (sink fires,
    /// the rung-id guard holds).
    func testRepeatIngestNeverReposts() {
        let (log, ringer) = (RingLog(), FakeRinger())
        let s = wiredStore(log: log, ringer: ringer)
        s.seedDemo(state: "incoming")
        s.ingest(CallEvent(kind: "incoming", callID: "demo-call"))
        s.ingest(CallEvent(kind: "incoming", callID: "demo-call"))
        XCTAssertEqual(log.posted, ["demo-call"])
        XCTAssertTrue(ringer.isRinging)
    }

    /// Answer stops the ring and withdraws the banner.
    func testAnswerStopsRingAndWithdraws() {
        let (log, ringer) = (RingLog(), FakeRinger())
        let s = wiredStore(log: log, ringer: ringer)
        s.seedDemo(state: "incoming")
        s.accept() // demo: inviting → active
        XCTAssertEqual(s.phase, .active)
        XCTAssertFalse(ringer.isRinging)
        XCTAssertGreaterThanOrEqual(ringer.stops, 1)
        XCTAssertEqual(log.withdrawn, ["demo-call"])
    }

    /// Decline (end on a ring) stops the ring and withdraws the banner.
    func testDeclineStopsRingAndWithdraws() {
        let (log, ringer) = (RingLog(), FakeRinger())
        let s = wiredStore(log: log, ringer: ringer)
        s.seedDemo(state: "incoming")
        let declinesBefore = s.declines
        s.end() // demo: ring → idle, counted as a decline
        XCTAssertEqual(s.phase, .idle)
        XCTAssertEqual(s.declines, declinesBefore + 1)
        XCTAssertFalse(ringer.isRinging)
        XCTAssertEqual(log.withdrawn, ["demo-call"])
    }

    /// The ring-timeout path (CallRingPolicy.timeout) ends the ring too.
    func testTimeoutStopsRingAndWithdraws() {
        let (log, ringer) = (RingLog(), FakeRinger())
        let s = wiredStore(log: log, ringer: ringer)
        s.seedDemo(state: "incoming", startedAt: 100)
        s.checkTimeout(now: 100 + CallRingPolicy.timeoutSecs + 1)
        XCTAssertEqual(s.phase, .ended)
        XCTAssertFalse(ringer.isRinging)
        XCTAssertEqual(log.withdrawn, ["demo-call"])
    }

    /// Dismiss silences; recall re-rings and re-posts.
    func testDismissSilencesRecallReRings() {
        let (log, ringer) = (RingLog(), FakeRinger())
        let s = wiredStore(log: log, ringer: ringer)
        s.seedDemo(state: "incoming")
        s.dismiss()
        XCTAssertFalse(ringer.isRinging)
        XCTAssertEqual(log.withdrawn, ["demo-call"])
        s.recall()
        XCTAssertEqual(s.phase, .inviting)
        XCTAssertTrue(ringer.isRinging)
        XCTAssertEqual(log.posted, ["demo-call", "demo-call"])
        XCTAssertEqual(log.withdrawn, ["demo-call"])
    }

    /// A non-ring seed never posts and never rings.
    func testEndedSeedStaysSilent() {
        let (log, ringer) = (RingLog(), FakeRinger())
        let s = wiredStore(log: log, ringer: ringer)
        s.seedDemo(state: "ended")
        XCTAssertTrue(log.posted.isEmpty)
        XCTAssertFalse(ringer.isRinging)
    }

    // MARK: - G3: category + route map (pure)

    func testCallCategoryCarriesAcceptDecline() {
        let category = OmCallInfo.category
        XCTAssertEqual(category.identifier, "OM_CALL")
        XCTAssertEqual(
            category.actions.map(\.identifier),
            ["OM_CALL_ACCEPT", "OM_CALL_DECLINE"])
    }

    func testCallUserInfoRoundTrip() {
        let info = OmCallInfo.userInfo(callID: "c1")
        XCTAssertEqual(NcDelivery.callID(from: info), "c1")
        XCTAssertNil(NcDelivery.callID(from: [:]))
        XCTAssertNil(NcDelivery.callID(from: ["OMCallID": ""]))
        XCTAssertEqual(OmCallInfo.requestID(callID: "c1"), "call-c1")
    }

    func testCallActionsRoute() {
        let info: [AnyHashable: Any] = ["OMCallID": "c9"]
        XCTAssertEqual(
            NcDelivery.route(actionID: OmCallInfo.acceptActionID, userInfo: info),
            .acceptCall(callID: "c9"))
        XCTAssertEqual(
            NcDelivery.route(actionID: OmCallInfo.declineActionID, userInfo: info),
            .declineCall(callID: "c9"))
        XCTAssertEqual(
            NcDelivery.route(
                actionID: UNNotificationDefaultActionIdentifier, userInfo: info),
            .showCall(callID: "c9"))
        XCTAssertEqual(
            NcDelivery.route(actionID: "WHATEVER", userInfo: info), .none)
        XCTAssertEqual(
            NcDelivery.route(actionID: OmCallInfo.declineActionID, userInfo: [:]),
            .none)
    }

    /// Decline-from-banner: the shared delegate broadcasts the decline
    /// note the app observes (end path), and returns the route.
    func testDeclineDispatchBroadcasts() {
        let exp = expectation(forNotification: .omNotifDeclineCall, object: nil) {
            $0.userInfo?["callID"] as? String == "c9"
        }
        let r = MessageNotifications.dispatch(
            actionID: OmCallInfo.declineActionID,
            userInfo: ["OMCallID": "c9"])
        XCTAssertEqual(r, .declineCall(callID: "c9"))
        wait(for: [exp], timeout: 1)
    }

    func testAcceptAndShowDispatchBroadcasts() {
        let acceptExp = expectation(
            forNotification: .omNotifAcceptCall, object: nil)
        {
            $0.userInfo?["callID"] as? String == "c9"
        }
        XCTAssertEqual(
            MessageNotifications.dispatch(
                actionID: OmCallInfo.acceptActionID,
                userInfo: ["OMCallID": "c9"]),
            .acceptCall(callID: "c9"))
        wait(for: [acceptExp], timeout: 1)
        let showExp = expectation(
            forNotification: .omNotifShowCall, object: nil)
        {
            $0.userInfo?["callID"] as? String == "c9"
        }
        XCTAssertEqual(
            MessageNotifications.dispatch(
                actionID: UNNotificationDefaultActionIdentifier,
                userInfo: ["OMCallID": "c9"]),
            .showCall(callID: "c9"))
        wait(for: [showExp], timeout: 1)
    }

    // MARK: - G5: Focus default-on + failure diagnostic

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-gap-g3g5-\(UUID().uuidString)") ?? .standard
    }

    /// Fresh installs (no stored key) sync Focus ON.
    @MainActor
    func testFreshInstallDefaultsOn() {
        let store = FocusSyncStore(defaults: isolatedDefaults(), reader: { false })
        XCTAssertTrue(store.syncEnabled)
    }

    /// An explicit choice persists both ways; stored choice wins.
    @MainActor
    func testExplicitChoicePersists() {
        let defaults = isolatedDefaults()
        let first = FocusSyncStore(defaults: defaults, reader: { false })
        XCTAssertTrue(first.syncEnabled)
        first.syncEnabled = false
        let second = FocusSyncStore(defaults: defaults, reader: { false })
        XCTAssertFalse(second.syncEnabled)
        second.syncEnabled = true
        let third = FocusSyncStore(defaults: defaults, reader: { false })
        XCTAssertTrue(third.syncEnabled)
    }

    /// Probe failure records the Diagnostics error even with sync off
    /// (never hidden behind the toggle) and still fails open.
    @MainActor
    func testFailureRecordsErrorEvenWhenSyncOff() {
        struct Boom: Error {}
        let store = FocusSyncStore(
            defaults: isolatedDefaults(), reader: { throw Boom() })
        store.syncEnabled = false
        store.refresh()
        XCTAssertFalse(store.focusActive)
        XCTAssertFalse(store.quietNow)
        XCTAssertNotNil(store.error)
    }
}
