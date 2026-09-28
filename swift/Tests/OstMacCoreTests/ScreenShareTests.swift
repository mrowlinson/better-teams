// ScreenShareTests.swift — om-screenshare: session model + permission
// states + summaries. Pure unit tests only — no live capture anywhere in
// this file (no start/stop/picker/stream calls), so the suite degrades
// cleanly headless.
import XCTest

@testable import OstMacCore

@MainActor
final class ScreenShareTests: XCTestCase {
    // MARK: - Permission states (pure)

    func testPermissionMapping() {
        XCTAssertEqual(ScreenSharePermission(granted: true), .authorized)
        XCTAssertEqual(ScreenSharePermission(granted: false), .denied)
        XCTAssertEqual(ScreenSharePermission(granted: nil), .unknown)
    }

    func testPermissionPredicates() {
        XCTAssertTrue(ScreenSharePermission.denied.isDenied)
        XCTAssertFalse(ScreenSharePermission.unknown.isDenied)
        XCTAssertFalse(ScreenSharePermission.authorized.isDenied)
        XCTAssertTrue(ScreenSharePermission.authorized.isAuthorized)
        XCTAssertFalse(ScreenSharePermission.unknown.isAuthorized)
        XCTAssertFalse(ScreenSharePermission.denied.isAuthorized)
    }

    func testPrivacyURLTargetsScreenRecording() {
        let url = ScreenShareAccess.privacyURL.absoluteString
        XCTAssertTrue(url.contains("Privacy_ScreenCapture"), url)
    }

    // MARK: - Session state machine (pure)

    private func display() -> ScreenShareSource {
        ScreenShareSource(id: "display-1920×1080", kind: .display, name: "1920×1080")
    }

    func testFullCycle() {
        var s = ScreenShareSession()
        XCTAssertEqual(s.phase, .idle)
        XCTAssertTrue(s.beginPick())
        XCTAssertEqual(s.phase, .picking)
        XCTAssertTrue(s.didPick(display()))
        XCTAssertEqual(s.phase, .starting)
        XCTAssertEqual(s.source, display())
        XCTAssertTrue(s.didStart())
        XCTAssertEqual(s.phase, .live)
        XCTAssertTrue(s.beginStop())
        XCTAssertEqual(s.phase, .stopping)
        XCTAssertTrue(s.didStop())
        XCTAssertEqual(s.phase, .idle)
        // Source kept for one-tap re-share; errors cleared.
        XCTAssertEqual(s.source, display())
        XCTAssertNil(s.lastError)
    }

    func testBeginPickOnlyFromIdleOrFailed() {
        var s = ScreenShareSession()
        XCTAssertTrue(s.beginPick())
        XCTAssertFalse(s.beginPick()) // already picking
        s.didCancelPick()
        XCTAssertTrue(s.beginPick())
        _ = s.didPick(display())
        XCTAssertFalse(s.beginPick()) // starting
        _ = s.didStart()
        XCTAssertFalse(s.beginPick()) // live
        _ = s.beginStop()
        XCTAssertFalse(s.beginPick()) // stopping
    }

    func testBeginPickRetriesFromFailed() {
        var s = ScreenShareSession()
        _ = s.beginPick()
        s.didFail("nope")
        XCTAssertEqual(s.phase, .failed)
        XCTAssertTrue(s.beginPick())
        XCTAssertEqual(s.phase, .picking)
        XCTAssertNil(s.lastError) // retry clears the detail
    }

    func testDidPickOnlyFromPicking() {
        var s = ScreenShareSession()
        XCTAssertFalse(s.didPick(display())) // idle: stray pick ignored
        XCTAssertNil(s.source)
        _ = s.beginPick()
        _ = s.didPick(display())
        let other = ScreenShareSource(id: "w", kind: .window, name: "1×1")
        XCTAssertFalse(s.didPick(other)) // starting: no re-pick
        XCTAssertEqual(s.source, display())
        _ = s.didStart()
        XCTAssertFalse(s.didPick(other)) // live: stop, then re-share
        XCTAssertEqual(s.source, display())
    }

    func testDidCancelPickOnlyFromPicking() {
        var s = ScreenShareSession()
        s.didCancelPick() // idle: no-op
        XCTAssertEqual(s.phase, .idle)
        _ = s.beginPick()
        _ = s.didPick(display())
        s.didCancelPick() // starting: no-op
        XCTAssertEqual(s.phase, .starting)
        _ = s.beginPick() // false (starting) — phase unchanged
        _ = s.didStart()
        var live = s
        live.didCancelPick() // live: no-op
        XCTAssertEqual(live.phase, .live)
    }

    func testDidStartOnlyFromStarting() {
        var s = ScreenShareSession()
        XCTAssertFalse(s.didStart()) // idle
        _ = s.beginPick()
        XCTAssertFalse(s.didStart()) // picking
        _ = s.didPick(display())
        s.didFail("boom")
        XCTAssertFalse(s.didStart()) // failed
    }

    func testDidFailKeepsDetail() {
        var s = ScreenShareSession()
        s.didFail("ignored") // idle: no-op
        XCTAssertEqual(s.phase, .idle)
        XCTAssertNil(s.lastError)
        _ = s.beginPick()
        s.didFail("permission denied")
        XCTAssertEqual(s.phase, .failed)
        XCTAssertEqual(s.lastError, "permission denied")
    }

    func testBeginStopOnlyFromLiveOrStarting() {
        var s = ScreenShareSession()
        XCTAssertFalse(s.beginStop()) // idle
        _ = s.beginPick()
        XCTAssertFalse(s.beginStop()) // picking: cancel via the picker
        _ = s.didPick(display())
        XCTAssertTrue(s.beginStop()) // starting: honored on landing
        var t = ScreenShareSession()
        _ = t.beginPick()
        _ = t.didPick(display())
        _ = t.didStart()
        XCTAssertTrue(t.beginStop()) // live
        XCTAssertFalse(t.beginStop()) // stopping
    }

    func testDidStopOnlyFromStopping() {
        var s = ScreenShareSession()
        XCTAssertFalse(s.didStop()) // idle
        _ = s.beginPick()
        XCTAssertFalse(s.didStop()) // picking
        _ = s.didPick(display())
        XCTAssertFalse(s.didStop()) // starting (stop not begun)
        _ = s.didStart()
        XCTAssertFalse(s.didStop()) // live (stop not begun)
        s.didFail("x")
        XCTAssertFalse(s.didStop()) // failed
    }

    // MARK: - Summaries (pure)

    func testStatusWords() {
        XCTAssertEqual(
            ScreenShareSummary.status(phase: .idle, lastError: nil), "Off")
        XCTAssertEqual(
            ScreenShareSummary.status(phase: .picking, lastError: nil),
            "Choose a screen…")
        XCTAssertEqual(
            ScreenShareSummary.status(phase: .starting, lastError: nil),
            "Starting…")
        XCTAssertEqual(
            ScreenShareSummary.status(phase: .live, lastError: nil), "Live")
        XCTAssertEqual(
            ScreenShareSummary.status(phase: .stopping, lastError: nil),
            "Stopping…")
        XCTAssertEqual(
            ScreenShareSummary.status(phase: .failed, lastError: nil), "Failed")
        XCTAssertEqual(
            ScreenShareSummary.status(phase: .failed, lastError: ""),
            "Failed")
        XCTAssertEqual(
            ScreenShareSummary.status(
                phase: .failed, lastError: "permission denied"),
            "Failed — permission denied")
    }

    func testSourceLabels() {
        XCTAssertEqual(
            ScreenShareSummary.label(for: display()), "Display · 1920×1080")
        XCTAssertEqual(
            ScreenShareSummary.label(
                for: ScreenShareSource(id: "w", kind: .window, name: "800×600")),
            "Window · 800×600")
        XCTAssertEqual(
            ScreenShareSummary.label(
                for: ScreenShareSource(id: "a", kind: .app, name: "App")),
            "App · App")
    }

    func testDeniedHint() {
        XCTAssertTrue(ScreenShareSummary.denied.contains("Screen Recording"))
        XCTAssertTrue(ScreenShareSummary.denied.contains("System Settings"))
    }

    // MARK: - No-blank guarantee (top10-share; BetaNews 2026-07-12)

    /// Preflight -> status wiring, environment-independent: on a box
    /// without the grant, status() reports denied (the preflight
    /// detects the missing permission); on a granted box, authorized.
    func testStatusReflectsPreflight() {
        let expected = ScreenSharePermission(
            granted: ScreenShareAccess.granted())
        XCTAssertEqual(ScreenShareAccess.status(), expected)
    }

    func testTileContentPreviewOnlyWhenLiveWithFrame() {
        XCTAssertEqual(
            ScreenShareSummary.tileContent(phase: .live, hasPreview: true),
            .preview)
        // Every other combo renders the status placeholder — never a
        // silent tile (Teams blank-share failure mode).
        for phase: ScreenSharePhase in
            [.idle, .picking, .starting, .live, .stopping, .failed]
        {
            if phase != .live {
                XCTAssertEqual(
                    ScreenShareSummary.tileContent(
                        phase: phase, hasPreview: true),
                    .placeholder, "\(phase) with a stale frame")
            }
            XCTAssertEqual(
                ScreenShareSummary.tileContent(
                    phase: phase, hasPreview: false),
                .placeholder, "\(phase) without a frame")
        }
    }

    func testPlaceholderStatusNeverEmpty() {
        // The fallback state always carries a human word.
        for phase: ScreenSharePhase in
            [.idle, .picking, .starting, .live, .stopping, .failed]
        {
            let word = ScreenShareSummary.status(
                phase: phase, lastError: nil)
            XCTAssertFalse(word.isEmpty, "\(phase)")
        }
        XCTAssertFalse(
            ScreenShareSummary.status(
                phase: .failed, lastError: "stream ended").isEmpty)
    }

    func testShareLine() {
        XCTAssertEqual(
            DiagnosticsFormat.shareLine(source: nil, frames: 0, sent: 0), "off")
        XCTAssertEqual(
            DiagnosticsFormat.shareLine(source: "", frames: 3, sent: 1), "off")
        XCTAssertEqual(
            DiagnosticsFormat.shareLine(
                source: "Display · 1920×1080", frames: 12, sent: 10),
            "Display · 1920×1080 · 12 frames · 10 sent")
    }

    // MARK: - Model (no capture: init state + toggles only)

    func testModelInitialState() {
        let m = ScreenShareModel()
        XCTAssertEqual(m.phase, .idle)
        XCTAssertFalse(m.phase.isLive)
        XCTAssertFalse(m.phase.isBusy)
        XCTAssertFalse(m.liveSend)
        XCTAssertNil(m.preview)
        XCTAssertNil(m.sourceLabel)
        XCTAssertEqual(m.framesCaptured, 0)
        XCTAssertEqual(m.framesSent, 0)
        // No --share-denied in the test run: never starts denied.
        XCTAssertNotEqual(m.permission, .denied)
    }

    func testModelLiveSendToggle() {
        let m = ScreenShareModel()
        m.setLiveSend(true)
        XCTAssertTrue(m.liveSend)
        m.setLiveSend(false)
        XCTAssertFalse(m.liveSend)
    }

    func testModelRefreshNeverDeniesAlone() {
        // Headless CI: preflight is false, but without failure evidence
        // the model must stay unknown — never auto-deny.
        let m = ScreenShareModel()
        m.refreshPermission()
        XCTAssertNotEqual(m.permission, .denied)
    }

    func testPhasePredicates() {
        XCTAssertTrue(ScreenSharePhase.live.isLive)
        XCTAssertFalse(ScreenSharePhase.idle.isLive)
        XCTAssertTrue(ScreenSharePhase.picking.isBusy)
        XCTAssertTrue(ScreenSharePhase.starting.isBusy)
        XCTAssertTrue(ScreenSharePhase.stopping.isBusy)
        XCTAssertFalse(ScreenSharePhase.live.isBusy)
        XCTAssertFalse(ScreenSharePhase.idle.isBusy)
        XCTAssertFalse(ScreenSharePhase.failed.isBusy)
    }
}
