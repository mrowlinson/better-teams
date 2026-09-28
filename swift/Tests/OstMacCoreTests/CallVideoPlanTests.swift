// CallVideoPlanTests.swift — MEETVIDEO: the core roster payload decodes,
// tiles keep roster order with the pinned person first and unclaimed
// sources as their own tiles, subscriptions put pinned then the dominant
// speaker first under the cap, and slots stay put across changes.
import XCTest

@testable import OstMacCore

final class CallVideoPlanTests: XCTestCase {
    func testRosterTilesSubscriptionsAndStableSlots() throws {
        // `ostmac_call_roster` shape (optional MSIs omitted when unknown).
        let json = """
        {"ok":true,"call_id":"c1","updates":3,"participants":[
          {"id":"8:orgid:ann","name":"Ann Ross","audio_msi":11,"video_msi":12,"video_on":true,
           "screen_on":false,"muted":false,"is_self":false},
          {"id":"8:orgid:me","name":"Me","audio_msi":21,"video_msi":22,"video_on":true,
           "screen_on":false,"is_self":true},
          {"id":"8:orgid:bob","name":"Bob Hale","audio_msi":31,"video_on":false,"screen_on":false,
           "muted":true,"is_self":false},
          {"id":"8:orgid:cara","name":"Cara Webb","audio_msi":41,"video_msi":42,"video_on":true,
           "screen_msi":43,"screen_on":true,"is_self":false}],
         "dominant_msi":41,"dominant_id":"8:orgid:cara","log":["rosterUpdate: {}"]}
        """
        let poll = try JSONDecoder().decode(CallRosterPoll.self, from: Data(json.utf8))
        XCTAssertEqual(poll.dominantId, "8:orgid:cara")
        XCTAssertEqual(poll.participants[3].screenMsi, 43)
        XCTAssertNil(poll.participants[2].videoMsi)
        let roster = poll.participants

        // Self is never a remote tile; source 99 (no roster row) is its own tile.
        let tiles = MeetingVideoPlan.tiles(roster: roster, sources: [12, 99], pinned: nil, dominant: "8:orgid:cara")
        XCTAssertEqual(tiles.map(\.id), ["8:orgid:ann", "8:orgid:bob", "8:orgid:cara", "msi:99"])
        XCTAssertEqual(tiles.map(\.speaking), [false, false, true, false])
        XCTAssertEqual(tiles.map(\.source), [12, nil, 42, 99])
        XCTAssertEqual(tiles[1].muted, true)
        let pinned = MeetingVideoPlan.tiles(roster: roster, sources: [], pinned: "8:orgid:cara", dominant: nil)
        XCTAssertEqual(pinned.map(\.id), ["8:orgid:cara", "8:orgid:ann", "8:orgid:bob"])

        // Priority: pinned, dominant, then camera-on roster order; capped.
        XCTAssertEqual(MeetingVideoPlan.wanted(roster: roster, pinned: nil, dominant: "8:orgid:cara"), [42, 12])
        XCTAssertEqual(MeetingVideoPlan.wanted(roster: roster, pinned: "8:orgid:ann", dominant: "8:orgid:cara",
                                               cap: 1), [12])
        XCTAssertEqual(MeetingVideoPlan.wanted(roster: roster, pinned: "8:orgid:bob", dominant: nil), [12, 42])

        // Stable slots: kept sources stay; a freed slot takes a new one;
        // a hole with nothing new takes the last slot; lead goes to slot 0.
        XCTAssertEqual(MeetingVideoPlan.assignSlots(previous: [], wanted: [42, 12], lead: nil), [42, 12])
        XCTAssertEqual(MeetingVideoPlan.assignSlots(previous: [1, 2, 3], wanted: [3, 9, 1], lead: nil), [1, 9, 3])
        XCTAssertEqual(MeetingVideoPlan.assignSlots(previous: [1, 2, 3, 4], wanted: [1, 3, 4], lead: nil), [1, 4, 3])
        XCTAssertEqual(MeetingVideoPlan.assignSlots(previous: [1, 2, 3], wanted: [1, 2], lead: nil), [1, 2])
        XCTAssertEqual(MeetingVideoPlan.assignSlots(previous: [1, 2, 3], wanted: [1, 2, 3], lead: 3), [3, 2, 1])
        XCTAssertEqual(MeetingVideoPlan.assignSlots(previous: [5], wanted: [], lead: nil), [])
    }

    /// CALLFIX: a remote screen share is up while the roster names a
    /// presenter (or, with no screen streams in the roster, while share
    /// frames are fresh); the share leg's queue is never a camera tile.
    @MainActor
    func testRemoteScreenShareTakesTheStageNotATile() {
        let ann = CallRosterParticipant(id: "8:orgid:ann", name: "Ann Ross", audioMsi: 11, videoMsi: 12,
                                        videoOn: true, screenMsi: 13, screenOn: false)
        let presenting = CallRosterParticipant(id: "8:orgid:ann", name: "Ann Ross", audioMsi: 11, videoMsi: 12,
                                               videoOn: true, screenMsi: 13, screenOn: true)
        let me = CallRosterParticipant(id: "8:orgid:me", name: "Me", screenMsi: 23, screenOn: true, isSelf: true)
        XCTAssertFalse(MeetingVideoPlan.shareActive(roster: [ann, me], shareAgeMs: 100),
                       "the roster says nobody else presents; own share never counts")
        XCTAssertTrue(MeetingVideoPlan.shareActive(roster: [presenting, me], shareAgeMs: nil))
        XCTAssertEqual(MeetingVideoPlan.presenter(roster: [me, presenting])?.name, "Ann Ross")
        let plain = CallRosterParticipant(id: "8:orgid:bob", name: "Bob Hale", audioMsi: 31)
        XCTAssertTrue(MeetingVideoPlan.shareActive(roster: [plain], shareAgeMs: 900), "no screen streams: frames decide")
        XCTAssertFalse(MeetingVideoPlan.shareActive(roster: [plain], shareAgeMs: MeetingVideoPlan.shareFreshMs))
        XCTAssertFalse(MeetingVideoPlan.shareActive(roster: [plain], shareAgeMs: nil))

        let m = MeetingVideoModel(demo: false)
        m.apply(roster: nil, sources: VideoSourcesPoll(ok: true, sources: [
            .init(id: 12, frames: 5, ageMs: 10), .init(id: MeetingVideoPlan.shareSource, frames: 3, ageMs: 10)]),
                media: nil)
        XCTAssertEqual(m.sources, [12], "the share queue is not a camera source")
        XCTAssertFalse(m.tiles.contains { $0.source == MeetingVideoPlan.shareSource })
        XCTAssertNil(m.shareVideo, "not started: no decoders")
    }
}
