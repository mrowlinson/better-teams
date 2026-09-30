// PollTimersHoldPinsTests — om-perf-poll-timers: pin the audit HOLDS so the
// timer/poll wins can't silently regress. Behavioral where cheap (feed
// loop), static where the win lives in app wiring (2s tick split).
import XCTest
@testable import OstMacCore

final class PollTimersHoldPinsTests: XCTestCase {
    /// Live feed = blocking-wait chain: start() drains once via poll, then
    /// loops on pollWait. The 1s timer must stay idle (fallback only).
    func testStartUsesBlockingWaitChain() {
        final class Counters: @unchecked Sendable {
            private let lock = NSLock()
            private var _polls = 0
            private var _waits = 0
            func bumpPoll() { lock.lock(); _polls += 1; lock.unlock() }
            func bumpWait() { lock.lock(); _waits += 1; lock.unlock() }
            var polls: Int { lock.lock(); defer { lock.unlock() }; return _polls }
            var waits: Int { lock.lock(); defer { lock.unlock() }; return _waits }
        }
        let c = Counters()
        let empty = RealtimePoll(ok: true, messages: [], resync: false, skipped: 0)
        let feed = RealtimeFeed(
            poll: { c.bumpPoll(); return empty },
            pollWait: { _ in c.bumpWait(); return empty },
            start: { 0 }, stop: { 0 })
        feed.pollInterval = 60 // timer armed-but-idle; must never fire here
        feed.start()
        XCTAssertEqual(feed.currentState, .live)
        TestWait.untilBlocking(interval: 0.02) { c.waits >= 2 }
        feed.stop()
        XCTAssertGreaterThanOrEqual(c.waits, 2, "live loop must chain pollWait")
        XCTAssertEqual(c.polls, 1, "poll runs once (initial drain); timer stays idle")
    }

    /// The App 2s tick (464e89c contract): background sweeps run on every
    /// tick regardless of visibility (a hidden window must never stall
    /// delivery); only the presentation refresh is gated on visible
    /// surfaces (else the root re-evals every 2s while hidden).
    func testAppTickSweepsAlwaysPresentationGated() throws {
        let here = URL(fileURLWithPath: #filePath)
        let app = here
            .deletingLastPathComponent() // file
            .deletingLastPathComponent() // OstMacCoreTests dir
            .deletingLastPathComponent() // Tests dir → swift dir
            .appendingPathComponent("Sources/OstMacCore/AppState.swift")
        let src = try String(contentsOf: app, encoding: .utf8)
        // Method body: signature up to the first 4-space-indented close.
        func body(_ signature: String) throws -> String {
            let head = try XCTUnwrap(src.range(of: signature), "\(signature) moved?")
            let close = try XCTUnwrap(
                src.range(of: "\n    }\n", range: head.upperBound..<src.endIndex))
            return String(src[head.upperBound..<close.lowerBound])
        }

        // tick(): sweeps first (ungated), then the visibility gate, then
        // presentation.
        let tick = try body("private func tick() {")
        let sweep = try XCTUnwrap(tick.range(of: "runBackgroundSweeps(visible: visible)"),
                                  "tick() must always run the background sweeps")
        let gate = try XCTUnwrap(tick.range(of: "guard visible else { return }"),
                                 "tick() must gate presentation on visibility")
        let present = try XCTUnwrap(tick.range(of: "refreshPresentation()"),
                                    "tick() must refresh presentation when visible")
        XCTAssertLessThan(sweep.lowerBound, gate.lowerBound, "sweeps must run before the gate")
        XCTAssertLessThan(gate.lowerBound, present.lowerBound, "presentation must sit behind the gate")
        XCTAssertEqual(tick.components(separatedBy: "Self.surfacesVisible()").count - 1, 1,
                       "tick() reads visibility exactly once")

        // Sweeps: every due-work sweep present, none visibility-gated
        // (only the call-slot FFI re-read may skip while hidden, and only
        // with no call in progress).
        let sweeps = try body("private func runBackgroundSweeps(visible: Bool) {")
        for call in ["quietHours.refresh()", "focusSync.refresh()", "presenceTruth.tick()",
                     "presenceSchedule.tick()", "snooze.refresh()", "fireScheduled()",
                     "call.refresh()"] {
            XCTAssertTrue(sweeps.contains(call), "runBackgroundSweeps lost \(call)")
        }
        XCTAssertFalse(sweeps.contains("guard visible"), "sweeps must not early-return on visibility")
        XCTAssertFalse(sweeps.contains("surfacesVisible"), "sweeps must not read visibility")
        XCTAssertTrue(sweeps.contains("visible || call.call != nil || call.phase != .idle"),
                      "hidden call re-read must stay tied to an in-progress call")

        // Presentation: feed-status mirror only, no sweeps.
        let presentation = try body("private func refreshPresentation() {")
        XCTAssertTrue(presentation.contains("feed.currentState"))
        XCTAssertFalse(presentation.contains("fireScheduled"), "sweeps leaked into presentation")
    }
}
