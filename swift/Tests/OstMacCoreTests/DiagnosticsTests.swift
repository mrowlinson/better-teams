// DiagnosticsTests.swift — om-statusbar lane: shared counter formatters
// (status-bar dot tooltip + Diagnostics window rows stay identical).
import XCTest

import OstMacCore

final class DiagnosticsTests: XCTestCase {
    func testDiagWindowID() {
        XCTAssertEqual(AppIdentity.diagWindowID, "diagnostics")
    }

    func testCoreLine() {
        XCTAssertEqual(
            DiagnosticsFormat.coreLine(version: "1.0.0", initCode: 0),
            "core 1.0.0 · init=0")
    }

    func testSessionLine() {
        XCTAssertEqual(
            DiagnosticsFormat.sessionLine(isDemo: true, signedIn: true),
            "DEMO · offline")
        XCTAssertEqual(
            DiagnosticsFormat.sessionLine(isDemo: false, signedIn: true),
            "signed in")
        XCTAssertEqual(
            DiagnosticsFormat.sessionLine(isDemo: false, signedIn: false),
            "signed out")
        XCTAssertEqual(
            DiagnosticsFormat.sessionLine(isDemo: false, signedIn: nil),
            "auth ?")
    }

    func testFeedLineLive() {
        XCTAssertEqual(
            DiagnosticsFormat.feedLine(
                state: .live, events: 3, polls: 12, resyncs: 1),
            "Live · 3 new · 12 polls · 1 resyncs")
    }

    func testFeedLineRetryWait() {
        XCTAssertEqual(
            DiagnosticsFormat.feedLine(
                state: .retryWait, events: 2, polls: 9, resyncs: 1),
            "Connecting… (2 new · 1 resyncs)")
    }

    func testFeedLineStopped() {
        XCTAssertEqual(
            DiagnosticsFormat.feedLine(
                state: .stopped, events: 0, polls: 0, resyncs: 0),
            "Realtime off")
    }

    func testFeedWord() {
        XCTAssertEqual(DiagnosticsFormat.feedWord(state: .live), "Live")
        XCTAssertEqual(
            DiagnosticsFormat.feedWord(state: .retryWait), "Connecting…")
        XCTAssertEqual(
            DiagnosticsFormat.feedWord(state: .stopped), "Realtime off")
    }

    func testNotifLine() {
        XCTAssertEqual(
            DiagnosticsFormat.notifLine(posted: 0, skipped: 0, lastReason: ""),
            "0 posted · 0 skipped · last —")
        XCTAssertEqual(
            DiagnosticsFormat.notifLine(
                posted: 3, skipped: 1, lastReason: "chat-message"),
            "3 posted · 1 skipped · last chat-message")
    }

    func testPinsLine() {
        XCTAssertEqual(DiagnosticsFormat.pinsLine(count: 0), "0 pinned")
        XCTAssertEqual(DiagnosticsFormat.pinsLine(count: 2), "2 pinned")
    }

    func testSeekLine() {
        XCTAssertEqual(
            DiagnosticsFormat.seekLine(attempted: 0, landed: 0, missed: 0),
            "no jumps yet")
        XCTAssertEqual(
            DiagnosticsFormat.seekLine(attempted: 4, landed: 3, missed: 1),
            "4 attempts · 3 landed · 1 missed (25%)")
        // Page-error attempts count with neither landed nor missed.
        XCTAssertEqual(
            DiagnosticsFormat.seekLine(attempted: 3, landed: 1, missed: 1),
            "3 attempts · 1 landed · 1 missed (33%)")
    }
}
