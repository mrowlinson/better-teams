import Foundation
import XCTest

/// Shared condition waits for tests (FLAKESWEEP).
///
/// Why: fixed-count poll loops (`for _ in 0 ..< 300 { sleep 10 ms }`) and short
/// wall-clock deadlines measure how long the scheduler queued the test, not
/// whether the code under test is correct. On a loaded machine (load 500 to
/// 900) they expire mid-operation and the assertions that follow fail for no
/// product reason. These helpers wait on the CONDITION. The ceiling only
/// bounds a genuine hang (default 60 s, never a tuning knob), and every helper
/// returns whether the condition held, so a caller asserts the result and a
/// timeout is reported instead of passing silently.
enum TestWait {
    /// Hang-only ceiling in seconds.
    static let hangCeiling: Double = 60

    private static func uptime() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func seconds(since t0: UInt64) -> Double { Double(uptime() &- t0) / 1e9 }

    /// Async wait: yields the caller's actor between checks. Runs `cond` on
    /// the caller's actor (nonsending), so main-actor state is read on main.
    @discardableResult
    nonisolated(nonsending)
    static func until(ceiling: Double = hangCeiling, interval: Double = 0.01,
                      _ cond: () -> Bool) async -> Bool {
        let t0 = uptime()
        while !cond() {
            if seconds(since: t0) >= ceiling { return false }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1e9))
        }
        return true
    }

    /// Async wait for a condition that can throw. A throw ends the wait.
    @discardableResult
    nonisolated(nonsending)
    static func untilThrowing(ceiling: Double = hangCeiling, interval: Double = 0.01,
                              _ cond: () throws -> Bool) async throws -> Bool {
        let t0 = uptime()
        while try !cond() {
            if seconds(since: t0) >= ceiling { return false }
            try await Task.sleep(nanoseconds: UInt64(interval * 1e9))
        }
        return true
    }

    /// Blocking wait for synchronous tests (sleeps the thread). Do not use
    /// where the condition needs the caller's run loop to make progress; use
    /// `spinUntil` there.
    @discardableResult
    static func untilBlocking(ceiling: Double = hangCeiling, interval: Double = 0.01,
                              _ cond: () -> Bool) -> Bool {
        let t0 = uptime()
        while !cond() {
            if seconds(since: t0) >= ceiling { return false }
            Thread.sleep(forTimeInterval: interval)
        }
        return true
    }

    /// Run-loop wait for synchronous main-thread tests: pumps the main run
    /// loop between checks so timers, dispatch and AppKit callbacks run.
    @discardableResult
    static func spinUntil(ceiling: Double = hangCeiling, slice: Double = 0.005,
                          _ cond: () -> Bool) -> Bool {
        let t0 = uptime()
        while !cond() {
            if seconds(since: t0) >= ceiling { return false }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: slice))
        }
        return true
    }

    /// Process CPU seconds. Perf bounds measure CPU time, never wall time:
    /// wall counts the scheduler's queueing under machine load.
    static func cpuSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)) / 1e9
    }

    /// Runs `body` and returns the CPU seconds it used.
    static func cpuTime(_ body: () throws -> Void) rethrows -> Double {
        let t0 = cpuSeconds()
        try body()
        return cpuSeconds() - t0
    }
}
