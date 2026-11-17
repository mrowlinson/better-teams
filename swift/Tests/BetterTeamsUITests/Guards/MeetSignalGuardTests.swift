// MeetSignalGuardTests — C2b roster signaling guards (hand, meeting
// reactions, pin, participant actions). Model-level only: no calls,
// no network, no windows. Every C2b path is local state (no wire
// endpoint exists yet — owner live test pending), so the guards pin
// the demo/evidence behavior and the live-disabled contract.
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

@MainActor
final class MeetSignalGuardTests: XCTestCase {
    // MARK: hand axis

    func testHandDefaultsDownAndIngestRaisesAndLowers() {
        let store = MeetingRosterStore()
        store.adopt([MeetingParticipant(id: "a", name: "Ava Lindqvist")])
        XCTAssertFalse(store.participants[0].handRaised)
        store.ingest(MeetingRosterEvent(id: "a", name: "", handRaised: true))
        XCTAssertTrue(store.participants[0].handRaised)
        store.ingest(MeetingRosterEvent(id: "a", name: ""))
        XCTAssertTrue(store.participants[0].handRaised, "nil axis keeps the last value")
        store.ingest(MeetingRosterEvent(id: "a", name: "", handRaised: false))
        XCTAssertFalse(store.participants[0].handRaised)
    }

    func testHandIgnoresBlankIDs() {
        let store = MeetingRosterStore()
        store.ingest(MeetingRosterEvent(id: "   ", name: "", handRaised: true))
        XCTAssertTrue(store.participants.isEmpty)
    }

    // MARK: presenter axis

    func testPresenterDefaultsFalseAndIngestSets() {
        let store = MeetingRosterStore()
        store.adopt([MeetingParticipant(id: "t", name: "Tom Becker")])
        XCTAssertFalse(store.participants[0].isPresenter)
        store.ingest(MeetingRosterEvent(id: "t", name: "", isPresenter: true))
        XCTAssertTrue(store.participants[0].isPresenter)
    }

    // MARK: roster format

    func testAccessibilityNamesHandAndPresenter() {
        let p = MeetingParticipant(id: "a", name: "Ava Lindqvist", speaking: true, muted: false,
                                   handRaised: true, isPresenter: true)
        let label = MeetingRosterFormat.accessibilityLabel(for: p)
        XCTAssertTrue(label.contains("hand raised"))
        XCTAssertTrue(label.contains("presenter"))
        let plain = MeetingRosterFormat.accessibilityLabel(for: MeetingParticipant(id: "b", name: "Bo"))
        XCTAssertEqual(plain, "Bo, unmuted")
    }

    // MARK: meeting reactions

    func testReactionSetIsTheTeamsSix() {
        XCTAssertEqual(MeetingReactionSet.emojis, ["👍", "❤️", "👏", "😂", "🎉", "😮"])
        XCTAssertTrue(MeetingReactionSet.isSupported("👏"))
        XCTAssertFalse(MeetingReactionSet.isSupported("👍🏽"))
        XCTAssertFalse(MeetingReactionSet.isSupported(""))
    }

    func testReactionLogAppendsAndRejectsJunk() {
        var log = MeetingReactionLog()
        log.append(emoji: "👍", sender: "Ava Lindqvist")
        log.append(emoji: "🚀", sender: "Ava Lindqvist")
        log.append(emoji: "👏", sender: "  ")
        log.append(emoji: "", sender: "Ava Lindqvist")
        XCTAssertEqual(log.lines.map(\.emoji), ["👍"])
        XCTAssertEqual(log.recent.count, 1)
        log.clear()
        XCTAssertTrue(log.lines.isEmpty)
    }

    func testReactionLogCapsAtTwentyAndShowsNewestSix() {
        var log = MeetingReactionLog()
        for i in 0..<25 { log.append(emoji: MeetingReactionSet.emojis[i % 6], sender: "P\(i)") }
        XCTAssertEqual(log.lines.count, MeetingReactionLog.maxLines)
        XCTAssertEqual(log.lines.first?.sender, "P5")
        XCTAssertEqual(log.recent.map(\.sender), ["P19", "P20", "P21", "P22", "P23", "P24"])
    }

    // MARK: pin (local spotlight)

    func testPinSetsClearsAndIgnoresRepeat() {
        let video = MeetingVideoModel(demo: true)
        XCTAssertNil(video.pinnedID)
        video.pin("a")
        XCTAssertEqual(video.pinnedID, "a")
        video.pin("a")
        XCTAssertEqual(video.pinnedID, "a")
        video.pin(nil)
        XCTAssertNil(video.pinnedID)
    }

    // MARK: participant actions — demo applies, live throws

    func testDemoMuteRemoveAndPresenterApplyInMemory() async {
        let store = MeetingRosterStore()
        store.adopt([
            MeetingParticipant(id: "a", name: "Ava Lindqvist"),
            MeetingParticipant(id: "t", name: "Tom Becker"),
        ])
        let actions = MeetingParticipantActions.demo()
        XCTAssertTrue(actions.enabled)
        await actions.muteOthers(id: "a", in: store)
        XCTAssertTrue(store.participants.first { $0.id == "a" }?.muted == true)
        await actions.makePresenter(id: "t", in: store)
        XCTAssertTrue(store.participants.first { $0.id == "t" }?.isPresenter == true)
        await actions.remove(id: "a", in: store)
        XCTAssertNil(store.participants.first { $0.id == "a" })
        XCTAssertNil(actions.lastError)
        XCTAssertTrue(actions.pending.isEmpty)
    }

    func testLiveControlThrowsLiveUnprovenForAllThree() {
        let store = MeetingRosterStore()
        let control = NoParticipantControl()
        XCTAssertThrowsError(try control.muteOthers(id: "a", in: store))
        XCTAssertThrowsError(try control.remove(id: "a", in: store))
        XCTAssertThrowsError(try control.makePresenter(id: "a", in: store))
        do {
            try control.muteOthers(id: "a", in: store)
            XCTFail("expected liveUnproven")
        } catch let e as MeetingSignalError {
            XCTAssertTrue(e.errorDescription?.contains("owner live test pending") == true)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testDisabledActionsNeverRun() async {
        let store = MeetingRosterStore()
        store.adopt([MeetingParticipant(id: "a", name: "Ava Lindqvist")])
        let actions = MeetingParticipantActions.live()
        XCTAssertFalse(actions.enabled)
        await actions.muteOthers(id: "a", in: store)
        XCTAssertFalse(store.participants[0].muted)
        XCTAssertTrue(actions.pending.isEmpty)
        XCTAssertNil(actions.lastError)
    }
}
