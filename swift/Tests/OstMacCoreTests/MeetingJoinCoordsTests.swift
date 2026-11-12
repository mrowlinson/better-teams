// MeetingJoinCoordsTests.swift — MEETFIX: a meeting join carries the
// reply chain and organizer from its link so the core joins the
// meeting's own call (not a fresh, empty group call on its thread).
import Foundation
import XCTest
@testable import OstMacCore

final class MeetingJoinCoordsTests: XCTestCase {
    private let org = "66666666-7777-8888-9999-000000000000"
    private let ten = "11111111-2222-3333-4444-555555555555"

    private func link(_ thread: String = "19%3ameeting_abc%40thread.v2", message: String = "0") -> String {
        "https://teams.microsoft.com/l/meetup-join/\(thread)/\(message)?context=%7b%22Tid%22%3a%22\(ten)%22%2c%22Oid%22%3a%22\(org)%22%7d"
    }

    func testJoinLinkCarriesOrganizerTenantAndReplyChain() throws {
        let target = JoinTarget(kind: "thread", threadID: "19:meeting_abc@thread.v2", url: link())
        let r = MeetingJoinRequest(target: target)
        XCTAssertEqual(r.threadID, "19:meeting_abc@thread.v2")
        XCTAssertEqual(r.messageID, "0")
        XCTAssertEqual(r.organizerOID, org)
        XCTAssertEqual(r.tenantID, ten)
        XCTAssertTrue(r.isMeeting)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any]
        XCTAssertEqual(json?["organizer_oid"] as? String, org)
        XCTAssertEqual(json?["tenant_id"] as? String, ten)
        XCTAssertEqual(json?["message_id"] as? String, "0")
    }

    func testLauncherFormAndDoubleEncodingParse() {
        let inner = link().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let c = JoinParse.meetingCoordinates("https://teams.microsoft.com/dl/launcher/launcher.html?url=\(inner)")
        XCTAssertEqual(c.messageID, "0")
        XCTAssertEqual(c.organizerOID, org)
        XCTAssertEqual(c.tenantID, ten)
    }

    func testBareThreadAndGroupChat() {
        let bare = MeetingJoinRequest(target: JoinTarget(kind: "thread", threadID: "19:meeting_abc@thread.v2",
                                                          url: "19:meeting_abc@thread.v2"))
        XCTAssertNil(bare.organizerOID)
        XCTAssertTrue(bare.isMeeting) // core defaults the reply chain to "0"
        let group = MeetingJoinRequest(target: JoinTarget(kind: "thread", threadID: "19:abc@thread.v2",
                                                           url: "19:abc@thread.v2"))
        XCTAssertFalse(group.isMeeting)
        let junk = JoinParse.meetingCoordinates("https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/abc?context=%7b%22Oid%22%3a%22not a guid%22%7d")
        XCTAssertNil(junk.messageID)
        XCTAssertNil(junk.organizerOID)
    }

    @MainActor
    func testConfirmJoinHandsTheRunnerTheLinkCoordinates() async {
        let seen = LockedBox<MeetingJoinRequest?>(nil)
        let parsed = MeetingsTests.parseJSON(kind: "thread", thread: "19:meeting_abc@thread.v2", url: link())
        let model = MeetingsViewModel(
            parseFetcher: { _ in parsed },
            joinRunner: { req in seen.mutate { $0 = req }; return CallResult(ok: true, accepted: true) },
            lobbyGraceSecs: 3600)
        model.joinText = "x"
        model.submitJoin()
        let sheet = await TestWait.until { model.showPreJoin }
        XCTAssertTrue(sheet)
        model.confirmJoin(micOn: false, cameraOn: false)
        let dialed = await TestWait.until { seen.value != nil }
        XCTAssertTrue(dialed)
        XCTAssertEqual(seen.value?.organizerOID, org)
        XCTAssertEqual(seen.value?.tenantID, ten)
        XCTAssertEqual(seen.value?.messageID, "0")
    }
}
