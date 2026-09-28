// AvVerifyTests.swift — om-av-verify: pure A/V model/summary coverage.
// No hardware touched: JSON decode + status-word mapping only.
import XCTest

@testable import OstMacCore

@MainActor
final class AvVerifyTests: XCTestCase {
    // MARK: - Result decode (pure)

    func testToneCheckDecode() throws {
        let v = try JSONDecoder().decode(
            ToneCheckResult.self,
            from: Data(#"{"ok":true,"detected":true,"delay_ms":50.0,"correlation_peak":0.99}"#.utf8))
        XCTAssertTrue(v.ok && v.detected)
        XCTAssertEqual(v.delay_ms, 50.0)
        XCTAssertEqual(v.correlation_peak, 0.99)
    }

    func testToneCheckDecodeNoEcho() throws {
        let v = try JSONDecoder().decode(
            ToneCheckResult.self,
            from: Data(#"{"ok":true,"detected":false,"delay_ms":0.0,"correlation_peak":0.0}"#.utf8))
        XCTAssertFalse(v.detected)
        XCTAssertEqual(v.correlation_peak, 0.0)
    }

    func testTonePlayDecode() throws {
        let v = try JSONDecoder().decode(
            TonePlayResult.self, from: Data(#"{"ok":true,"frames":50}"#.utf8))
        XCTAssertTrue(v.ok)
        XCTAssertEqual(v.frames, 50)
    }

    func testMicTestDecodeNoPlayback() throws {
        let v = try JSONDecoder().decode(
            MicTestResult.self,
            from: Data(#"{"ok":true,"frames":40,"seconds":0.8,"peak_db":-60.0,"played_back":false}"#.utf8))
        XCTAssertEqual(v.frames, 40)
        XCTAssertEqual(v.peak_db, -60.0)
        XCTAssertFalse(v.played_back)
    }

    func testMicLevelSilenceFloorDecode() throws {
        let v = try JSONDecoder().decode(
            MicLevel.self, from: Data(#"{"ok":true,"peak_db":-60.0,"has_input":false}"#.utf8))
        XCTAssertFalse(v.has_input)
        XCTAssertEqual(v.peak_db, -60.0)
    }

    func testDryRunDecodeNoEcho() throws {
        let v = try JSONDecoder().decode(
            DryRunResult.self,
            from: Data(#"{"ok":true,"audio_sent":25,"audio_received":25,"echo_detected":false,"echo_delay_ms":0.0,"echo_correlation":0.0,"video_packets":5,"video_nals":5}"#.utf8))
        XCTAssertFalse(v.echo_detected)
        XCTAssertEqual(v.audio_received, v.audio_sent)
    }

    // MARK: - Camera status words (pure; fills AvPanelTests gaps)

    func testCameraStatusStopping() {
        XCTAssertEqual(AvSummary.cameraStatus("stopping…"), "Stopping…")
    }

    func testCameraStatusPushFailed() {
        XCTAssertEqual(
            AvSummary.cameraStatus("push failed: bad fmt"), "Push failed — bad fmt")
    }

    func testCameraStatusFailedKeepsDetail() {
        XCTAssertEqual(
            AvSummary.cameraStatus("failed: cannot add input"),
            "Failed — cannot add input")
    }
}
