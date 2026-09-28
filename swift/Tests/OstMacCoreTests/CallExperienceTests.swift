// CallExperience tests (om-call-ux): phase machine, slot/event mapping,
// ring policy, banner actions, timeout, in-call controls. Pure Swift —
// no core/network/hardware (demo store + synthetic clocks).
import XCTest

@testable import OstMacCore

final class CallExperienceTests: XCTestCase {
    // MARK: - Reducer

    func testReducerIdle() {
        XCTAssertEqual(CallPhaseReducer.next(.idle, .invitation), .inviting)
        XCTAssertEqual(CallPhaseReducer.next(.idle, .placed), .inviting)
        // Stale/foreign events never move idle.
        for ev: CallPhaseEvent in [.connected, .remoteEnd, .rejected, .localEnd, .dismissed, .timedOut, .cleared] {
            XCTAssertEqual(CallPhaseReducer.next(.idle, ev), .idle, "\(ev)")
        }
    }

    func testReducerInviting() {
        XCTAssertEqual(CallPhaseReducer.next(.inviting, .connected), .active)
        for ev: CallPhaseEvent in [.remoteEnd, .rejected, .localEnd, .dismissed, .timedOut] {
            XCTAssertEqual(CallPhaseReducer.next(.inviting, ev), .ended, "\(ev)")
        }
        // Repeat rings and clears are absorbed.
        XCTAssertEqual(CallPhaseReducer.next(.inviting, .invitation), .inviting)
        XCTAssertEqual(CallPhaseReducer.next(.inviting, .placed), .inviting)
        XCTAssertEqual(CallPhaseReducer.next(.inviting, .cleared), .inviting)
    }

    func testReducerActive() {
        for ev: CallPhaseEvent in [.remoteEnd, .rejected, .localEnd] {
            XCTAssertEqual(CallPhaseReducer.next(.active, ev), .ended, "\(ev)")
        }
        // An active call is never dismissed or timed out — only ended.
        for ev: CallPhaseEvent in [.dismissed, .timedOut, .connected, .invitation, .placed, .cleared] {
            XCTAssertEqual(CallPhaseReducer.next(.active, ev), .active, "\(ev)")
        }
    }

    func testReducerEnded() {
        XCTAssertEqual(CallPhaseReducer.next(.ended, .cleared), .idle)
        XCTAssertEqual(CallPhaseReducer.next(.ended, .invitation), .inviting)
        XCTAssertEqual(CallPhaseReducer.next(.ended, .placed), .inviting)
        for ev: CallPhaseEvent in [.connected, .remoteEnd, .rejected, .localEnd, .dismissed, .timedOut] {
            XCTAssertEqual(CallPhaseReducer.next(.ended, ev), .ended, "\(ev)")
        }
    }

    // MARK: - Mapper

    func testMapperSlotToPhase() {
        XCTAssertEqual(CallPhaseMapper.phase(for: nil), .idle)
        for state in ["ringing", "placing"] {
            let c = CallInfo(id: "x", dir: "in", peer: "p", state: state)
            XCTAssertEqual(CallPhaseMapper.phase(for: c), .inviting, state)
        }
        let connected = CallInfo(id: "x", dir: "out", peer: "p", state: "connected")
        XCTAssertEqual(CallPhaseMapper.phase(for: connected), .active)
        for state in ["ended", "failed"] {
            let c = CallInfo(id: "x", dir: "in", peer: "p", state: state)
            XCTAssertEqual(CallPhaseMapper.phase(for: c), .ended, state)
        }
        // Unknown states fail closed (no banner).
        let weird = CallInfo(id: "x", dir: "in", peer: "p", state: "held")
        XCTAssertEqual(CallPhaseMapper.phase(for: weird), .idle)
    }

    func testMapperFeedEvents() {
        XCTAssertEqual(
            CallPhaseMapper.event(for: CallEvent(kind: "incoming", callID: "c")),
            .invitation)
        XCTAssertEqual(
            CallPhaseMapper.event(for: CallEvent(kind: "end", callID: "c")),
            .remoteEnd)
        XCTAssertEqual(
            CallPhaseMapper.event(for: CallEvent(kind: "rejected", callID: "c")),
            .rejected)
        XCTAssertNil(CallPhaseMapper.event(for: CallEvent(kind: "typing", callID: "c")))
    }

    // MARK: - Ring policy

    func testRingExpiryBoundary() {
        XCTAssertFalse(CallRingPolicy.isExpired(startedAt: 100, now: 100 + 44.9))
        XCTAssertTrue(CallRingPolicy.isExpired(startedAt: 100, now: 100 + 45))
        XCTAssertTrue(CallRingPolicy.isExpired(startedAt: 100, now: 100 + 1000))
        // Undated rings never auto-clear.
        XCTAssertFalse(CallRingPolicy.isExpired(startedAt: 0, now: 1_000_000_000))
    }

    func testBannerVisibleMatrix() {
        let ring = CallInfo(id: "c1", dir: "in", peer: "p", state: "ringing")
        XCTAssertTrue(CallRingPolicy.bannerVisible(phase: .inviting, call: ring, dismissedIDs: []))
        XCTAssertFalse(CallRingPolicy.bannerVisible(phase: .inviting, call: ring, dismissedIDs: ["c1"]))
        XCTAssertFalse(CallRingPolicy.bannerVisible(phase: .inviting, call: nil, dismissedIDs: []))
        let live = CallInfo(id: "c1", dir: "out", peer: "p", state: "connected")
        XCTAssertTrue(CallRingPolicy.bannerVisible(phase: .active, call: live, dismissedIDs: []))
        XCTAssertFalse(CallRingPolicy.bannerVisible(phase: .active, call: live, dismissedIDs: ["c1"]))
        let ended = CallInfo(id: "c1", dir: "in", peer: "p", state: "ended")
        XCTAssertFalse(CallRingPolicy.bannerVisible(phase: .ended, call: ended, dismissedIDs: []))
        XCTAssertFalse(CallRingPolicy.bannerVisible(phase: .idle, call: nil, dismissedIDs: []))
    }

    // MARK: - Banner actions (demo store journeys)

    func testSeedIncomingRingsOnce() {
        let s = CallStore(demo: true)
        XCTAssertEqual(s.phase, .idle)
        s.seedDemo(state: "incoming")
        XCTAssertEqual(s.phase, .inviting)
        XCTAssertTrue(s.bannerVisible)
        XCTAssertEqual(s.rings, 1)
    }

    func testAcceptJourneyCountsAccept() {
        let s = CallStore(demo: true)
        s.seedDemo(state: "incoming")
        s.accept()
        XCTAssertEqual(s.call?.state, "connected")
        XCTAssertEqual(s.phase, .active)
        XCTAssertEqual(s.accepts, 1)
        XCTAssertTrue(s.bannerVisible)
        s.end()
        XCTAssertNil(s.call)
        XCTAssertEqual(s.phase, .idle)
        XCTAssertFalse(s.bannerVisible)
    }

    func testDeclineJourneyCountsDecline() {
        let s = CallStore(demo: true)
        s.seedDemo(state: "incoming")
        s.end()
        XCTAssertEqual(s.declines, 1)
        XCTAssertEqual(s.phase, .idle)
    }

    func testEndOfActiveCallIsNotADecline() {
        let s = CallStore(demo: true)
        s.seedDemo(state: "active")
        XCTAssertEqual(s.phase, .active)
        s.end()
        XCTAssertEqual(s.declines, 0)
        XCTAssertEqual(s.phase, .idle)
    }

    func testDismissAndRecall() {
        let s = CallStore(demo: true)
        s.seedDemo(state: "incoming")
        s.dismiss()
        XCTAssertFalse(s.bannerVisible)
        XCTAssertEqual(s.phase, .ended) // local terminal; slot still rings
        XCTAssertEqual(s.dismissals, 1)
        XCTAssertNotNil(s.call) // server truth untouched
        // Diagnostics escape hatch: the ring is still actionable.
        s.recall()
        XCTAssertTrue(s.bannerVisible)
        XCTAssertEqual(s.phase, .inviting)
        XCTAssertEqual(s.rings, 1) // recall is not a new ring
    }

    func testDismissActiveKeepsPhase() {
        let s = CallStore(demo: true)
        s.seedDemo(state: "active")
        s.dismiss()
        XCTAssertFalse(s.bannerVisible)
        XCTAssertEqual(s.phase, .active) // active is never dismissed away
        s.recall()
        XCTAssertTrue(s.bannerVisible)
    }

    func testDismissIdleIsNoop() {
        let s = CallStore(demo: true)
        s.dismiss()
        XCTAssertEqual(s.dismissals, 0)
        XCTAssertEqual(s.phase, .idle)
        s.recall()
        s.clearEnded()
        XCTAssertEqual(s.phase, .idle)
    }

    func testClearEndedRetiresTerminalRecord() {
        let s = CallStore(demo: true)
        s.seedDemo(state: "ended")
        XCTAssertEqual(s.phase, .ended)
        XCTAssertFalse(s.bannerVisible)
        s.clearEnded()
        XCTAssertEqual(s.phase, .idle)
        XCTAssertNil(s.call)
    }

    func testClearEndedRefusesLiveSlot() {
        let s = CallStore(demo: true)
        s.seedDemo(state: "incoming")
        s.dismiss() // ended locally, but the slot still rings
        XCTAssertEqual(s.phase, .ended)
        s.clearEnded() // refused: end the ring, don't clear it
        XCTAssertEqual(s.phase, .ended)
        XCTAssertNotNil(s.call)
    }

    // MARK: - Timeout

    func testTimeoutRetiresStaleRing() {
        let s = CallStore(demo: true)
        s.seedDemo(state: "incoming", startedAt: 100)
        XCTAssertEqual(s.phase, .inviting)
        s.checkTimeout(now: 100 + 44.9)
        XCTAssertEqual(s.phase, .inviting)
        XCTAssertTrue(s.bannerVisible)
        s.checkTimeout(now: 100 + 45)
        XCTAssertEqual(s.phase, .ended)
        XCTAssertFalse(s.bannerVisible)
        XCTAssertEqual(s.timeouts, 1)
        XCTAssertNotNil(s.call) // server truth untouched (missed call)
    }

    func testTimeoutIgnoresUndatedAndLive() {
        let s = CallStore(demo: true)
        s.seedDemo(state: "incoming") // startedAt 0
        s.checkTimeout(now: 1_000_000_000)
        XCTAssertEqual(s.phase, .inviting)
        XCTAssertEqual(s.timeouts, 0)
        // Active calls never time out.
        s.seedDemo(state: "active")
        s.checkTimeout(now: 1_000_000_000)
        XCTAssertEqual(s.phase, .active)
        XCTAssertEqual(s.timeouts, 0)
        // Dismissed rings don't double-report.
        s.seedDemo(state: "incoming", startedAt: 100)
        s.dismiss()
        s.checkTimeout(now: 100 + 1000)
        XCTAssertEqual(s.timeouts, 0)
    }

    func testTimeoutThenRecallReRings() {
        let s = CallStore(demo: true)
        s.seedDemo(state: "incoming", startedAt: 100)
        s.checkTimeout(now: 100 + 45)
        s.recall() // user saw the missed call in Diagnostics, re-raises it
        XCTAssertEqual(s.phase, .inviting)
        XCTAssertTrue(s.bannerVisible)
    }

    // MARK: - Feed wiring (TEAMS_MANUAL_CALLS path → machine)

    func testIngestReducesPhase() {
        let s = CallStore(demo: true)
        s.ingest(CallEvent(kind: "incoming", callID: "c9"))
        XCTAssertEqual(s.phase, .inviting)
        XCTAssertEqual(s.lastAction, "event:incoming")
        s.ingest(CallEvent(kind: "end", callID: "c9"))
        XCTAssertEqual(s.phase, .ended)
        s.ingest(CallEvent(kind: "bogus", callID: "c9"))
        XCTAssertEqual(s.phase, .ended) // unknown kinds ignored
    }

    // MARK: - In-call controls

    func testMuteFlipsInDemo() {
        let s = CallStore(demo: true)
        XCTAssertFalse(s.muted)
        s.setMuted(true)
        XCTAssertTrue(s.muted)
        s.setMuted(false)
        XCTAssertFalse(s.muted)
    }

    func testCameraToggleDrivesHook() {
        let s = CallStore(demo: true)
        var seen: [Bool] = []
        s.cameraHook = { seen.append($0) }
        XCTAssertFalse(s.cameraOn)
        s.setCameraOn(true)
        XCTAssertTrue(s.cameraOn)
        s.setCameraOn(false)
        XCTAssertFalse(s.cameraOn)
        XCTAssertEqual(seen, [true, false])
    }

    func testCameraToggleWorksHookless() {
        let s = CallStore(demo: true)
        XCTAssertNil(s.cameraHook) // headless: no window installed one
        s.setCameraOn(true) // must not trap
        XCTAssertTrue(s.cameraOn)
    }

    /// core-b demo-leak sweep: demo routes stay in memory — the shared
    /// real A/V key is never read or written (live persists it before
    /// the core reroute; not unit-tested here, that path calls the FFI).
    func testDemoSpeakerNeverTouchesSharedKey() {
        let key = AvPanelModel.speakerKey
        let prev = UserDefaults.standard.string(forKey: key)
        defer {
            if let prev { UserDefaults.standard.set(prev, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set("Real Device", forKey: key)
        let s = CallStore(demo: true)
        XCTAssertNil(s.speaker) // never reads the real route
        s.setSpeaker("External Headphones")
        XCTAssertEqual(s.speaker, "External Headphones")
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "Real Device")
        s.setSpeaker(nil)
        XCTAssertNil(s.speaker)
    }

    func testRefreshSpeakersDemo() {
        let s = CallStore(demo: true)
        XCTAssertFalse(s.speakersLoaded)
        s.refreshSpeakers()
        XCTAssertTrue(s.speakersLoaded)
        XCTAssertEqual(s.speakerDevices, ["Demo Speaker"])
    }

    // MARK: - Media control models

    func testLiveMediaStatsDecodesNewKeys() throws {
        let json = """
        {"running":true,"audio_sent":1,"audio_recv":2,"video_sent":3,
         "video_recv":4,"send_queued":0,"send_dropped":0,"recv_pending":0,
         "recv_dropped":0,"ice_audio":"a","ice_video":"v","started_at":9,
         "muted":true,"speaker":"External","speaker_error":null}
        """
        let m = try JSONDecoder().decode(LiveMediaStats.self, from: Data(json.utf8))
        XCTAssertEqual(m.muted, true)
        XCTAssertEqual(m.speaker, "External")
        XCTAssertNil(m.speakerError)
    }

    func testLiveMediaStatsOldCoreOmitsNewKeys() throws {
        // Old core builds omit muted/speaker/speaker_error: must decode nil.
        let json = """
        {"running":false,"audio_sent":0,"audio_recv":0,"video_sent":0,
         "video_recv":0,"send_queued":0,"send_dropped":0,"recv_pending":0,
         "recv_dropped":0,"ice_audio":"","ice_video":"","started_at":0}
        """
        let m = try JSONDecoder().decode(LiveMediaStats.self, from: Data(json.utf8))
        XCTAssertNil(m.muted)
        XCTAssertNil(m.speaker)
        XCTAssertNil(m.speakerError)
    }

    func testMuteAndSpeakerResultsDecode() throws {
        let mute = try decodeOrThrow(
            MuteResult.self, from: Data(#"{"ok":true,"muted":true}"#.utf8))
        XCTAssertTrue(mute.muted)
        let sp = try decodeOrThrow(
            SpeakerResult.self, from: Data(#"{"ok":true,"speaker":null}"#.utf8))
        XCTAssertNil(sp.speaker)
        let sp2 = try decodeOrThrow(
            SpeakerResult.self, from: Data(#"{"ok":true,"speaker":"X"}"#.utf8))
        XCTAssertEqual(sp2.speaker, "X")
    }
}
