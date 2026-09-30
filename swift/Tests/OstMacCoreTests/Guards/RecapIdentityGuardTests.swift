// RecapIdentityGuardTests — RECAP2 guards: the meeting identity the recap
// needs (notes read "noIdentity" 6/6 live until the core read it from the
// recording message XML and the thread's `properties`), and the AI-notes
// query keyed by the recording. Offline; no network, no windows.
import Foundation
import XCTest
@testable import OstMacCore

final class RecapIdentityGuardTests: XCTestCase {
    private func sources(_ json: String) throws -> MeetingRecapSources {
        let r = try JSONDecoder().decode(CoreMeetingRecapTransport.SourcesResponse.self, from: Data(json.utf8))
        return CoreMeetingRecapTransport.sources(from: r)
    }

    /// "noIdentity" only when the core found no meeting identity (collab null);
    /// a found identity whose artifacts read answered is never an error.
    func testNoIdentityOnlyWhenCoreFoundNoMeeting() throws {
        XCTAssertEqual(try sources(#"{"ok":true,"messages":[],"collab":null}"#).artifactsError,
                       MeetingRecapCopy.noIdentityError)
        XCTAssertNil(try sources(#"{"ok":true,"messages":[],"collab":{"ok":true,"resources":[]}}"#).artifactsError)
        XCTAssertEqual(try sources(#"{"ok":true,"messages":[],"collab":{"ok":false,"error":"HTTP 403 (meeting artifacts)"}}"#)
            .artifactsError, "HTTP 403 (meeting artifacts)")
    }

    private func recapCore() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("rust/ostmac-core/src/recap.rs")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The core's identity sources stay wired (Rust unit tests pin the parsers:
    /// identity_from_recording_xml_properties_and_loose_json).
    func testCoreReadsIdentityFromRecordingXMLAndThreadProperties() throws {
        let src = try recapCore()
        XCTAssertTrue(src.contains("meeting_infos_from_recordings(&kept)"), "sources read the recording XML identity")
        XCTAssertTrue(src.contains(#"&thread["properties"]"#), "thread identity reads `properties` (live shape)")
        XCTAssertTrue(src.contains("json_text_value(&raw, k)"), "transcript identity survives non-JSON content")
        for name in ["MeetingOrganizerId", "InstanceICalUid", "ICalUid", "MeetingICalUid", "MeetingOrganizerTenantId"] {
            XCTAssertTrue(src.contains("\"\(name)\""), "recording XML element \(name)")
        }
    }

    /// Intelligent recap asks by the recording's EntityId (Teams' Recap tab
    /// query) before the by-thread list query; the store hands it the target.
    func testAIRecapAsksByRecordingFirst() throws {
        let src = try recapCore()
        let byEntity = try XCTUnwrap(src.range(of: "post(catchup_entity_body(&entity))"))
        let byThread = try XCTUnwrap(src.range(of: "post(catchup_body(thread,"))
        XCTAssertLessThan(byEntity.lowerBound, byThread.lowerBound)
        let store = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/OstMacCore/MeetingRecapStore.swift"), encoding: .utf8)
        XCTAssertTrue(store.contains("let file = s.playable?.target.json"), "store passes the recording target")
    }
}
