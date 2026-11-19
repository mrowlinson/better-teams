// MeetingsPlusGuardTests.swift — MEETINGS-PLUS guards: the extras
// section never shows on plain events, and the server toggle patch keys
// stay the Graph shape (a rename breaks the PATCH contract silently).
import XCTest
@testable import BetterTeamsUI
@testable import OstMacCore

final class MeetingsPlusGuardTests: XCTestCase {
    private func meeting(online: Bool, joinURL: String?) -> MeetingItem {
        MeetingItem(meetingId: "M1", subject: "Standup", joinURL: joinURL, isOnline: online)
    }

    func testExtrasOnlineOnly() {
        XCTAssertTrue(MeetingExtrasBlock.shows(for: meeting(online: true, joinURL: nil)))
        XCTAssertTrue(MeetingExtrasBlock.shows(for: meeting(online: false, joinURL: "https://teams/join")))
        XCTAssertFalse(MeetingExtrasBlock.shows(for: meeting(online: false, joinURL: nil)))
        XCTAssertFalse(MeetingExtrasBlock.shows(for: meeting(online: false, joinURL: "")))
    }

    func testCapturePatchKeysAreGraphNames() throws {
        let opts = MeetingCaptureOptions(allowRecording: true, allowTranscription: false,
                                         recordAutomatically: true)
        let body = try JSONSerialization.jsonObject(with: opts.patchBody.data(using: .utf8)!) as? [String: Bool]
        XCTAssertEqual(Set((body ?? [:]).keys),
                       ["allowRecording", "allowTranscription", "recordAutomatically"])
    }

    func testRecordControlReusesMeetrecordLegs() {
        // The meeting-context row drives CallStore — the same legs the
        // Call menu + toolbars flip — so no menu/catalog growth here.
        let faces = CallControlsState(joined: true, muted: false, cameraOn: false, sharing: false,
                                            recording: true, transcribing: true)
        XCTAssertEqual(faces.record.menuTitle, "Stop Recording")
        XCTAssertEqual(faces.transcribe.menuTitle, "Stop Transcription")
    }
}
