import XCTest

/// Controls for TestWait (FLAKESWEEP): positive AND negative, per helper kind.
/// A helper that always returns true, or always false, fails one of these.
@MainActor
final class TestWaitTests: XCTestCase {
    private final class Flag: @unchecked Sendable { var on = false }

    func testUntilReportsTimeoutAndReturnsWhenMet() async {
        let missed = await TestWait.until(ceiling: 0.05) { false }
        XCTAssertFalse(missed, "a condition that never holds is reported, not passed")
        let met = await TestWait.until(ceiling: 0.05) { true }
        XCTAssertTrue(met)
    }

    /// Not a fixed poll count: a condition met after far more than 300 x 10 ms
    /// worth of polling budget's worth of checks still holds because only the
    /// condition (not a count) ends the wait, and it sees the flip made by
    /// another task.
    func testUntilSeesALateFlipFromAnotherTask() async {
        let f = Flag()
        Task { try? await Task.sleep(nanoseconds: 150_000_000); f.on = true }
        let ok = await TestWait.until(ceiling: 30, interval: 0.001) { f.on }
        XCTAssertTrue(ok)
        XCTAssertTrue(f.on)
    }

    func testUntilThrowingPropagatesAndTimesOut() async throws {
        struct Boom: Error {}
        let missed = try await TestWait.untilThrowing(ceiling: 0.05) { false }
        XCTAssertFalse(missed)
        do {
            _ = try await TestWait.untilThrowing(ceiling: 5) { throw Boom() }
            XCTFail("a throwing condition must throw")
        } catch is Boom {}
    }

    func testUntilBlockingAndSpinUntilTimeOutAndMeet() {
        XCTAssertFalse(TestWait.untilBlocking(ceiling: 0.05) { false })
        XCTAssertTrue(TestWait.untilBlocking(ceiling: 0.05) { true })
        XCTAssertFalse(TestWait.spinUntil(ceiling: 0.05) { false })
        XCTAssertTrue(TestWait.spinUntil(ceiling: 0.05) { true })
    }

    /// spinUntil pumps the run loop: a main-queue block posted before the
    /// wait runs during it (blocking wait would starve it).
    func testSpinUntilRunsMainQueueWork() {
        let f = Flag()
        DispatchQueue.main.async { f.on = true }
        XCTAssertTrue(TestWait.spinUntil(ceiling: 30) { f.on })
    }

    /// CPU time ignores waiting but sees work.
    func testCpuTimeIgnoresWaitingButSeesWork() {
        let waited = TestWait.cpuTime { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertLessThan(waited, 0.15, "waiting is not CPU")
        var sink = 0.0
        let burned = TestWait.cpuTime {
            let end = TestWait.cpuSeconds() + 0.2
            while TestWait.cpuSeconds() < end { sink += 1 }
        }
        XCTAssertGreaterThanOrEqual(burned, 0.2, "work is CPU (\(sink))")
    }
}
