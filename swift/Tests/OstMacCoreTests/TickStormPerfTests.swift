// TickStormPerfTests — om-s7-tickstorm guards. Caps/counts only, never
// timings: refresh coalescing, media-loop gating, silent re-adopt.
import Combine
import XCTest

@testable import OstMacCore

/// Lock-box counter (cross-thread sets from detached fetchers).
final class TickStormCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func inc() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var n: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class TickStormPerfTests: XCTestCase {
    /// Burst refresh collapses: one in-flight + one drain re-read.
    func testRefreshCoalescesBurst() async {
        let store = CallStore()
        let fetches = TickStormCounter()
        store.statusFetcher = {
            fetches.inc()
            return nil
        }
        for _ in 0..<5 { store.refresh() }
        await spinUntil({ fetches.n == 2 })
        XCTAssertEqual(fetches.n, 2)
    }

    /// Demo refresh never reads (seeded state only).
    func testDemoRefreshNeverReads() async {
        let store = CallStore(demo: true)
        let fetches = TickStormCounter()
        store.statusFetcher = {
            fetches.inc()
            return nil
        }
        for _ in 0..<5 { store.refresh() }
        await settle(yields: 5000)
        XCTAssertEqual(fetches.n, 0)
    }

    /// Media loop follows surfaces: banner up → runs; banner dismissed
    /// with no window → stops; In-Call window → resumes; closed → stops.
    func testMediaGatedOnSurfaces() async {
        let store = CallStore()
        let live = Self.liveCall
        store.statusFetcher = { live }
        store.refresh()
        await spinUntil({ store.call != nil })
        XCTAssertEqual(store.call?.id, "live-1")
        XCTAssertTrue(store.bannerVisible)
        XCTAssertTrue(store.isMediaPolling)
        store.dismiss()
        XCTAssertFalse(store.bannerVisible)
        XCTAssertFalse(store.isMediaPolling)
        store.callWindowOpen = true
        XCTAssertTrue(store.isMediaPolling)
        store.callWindowOpen = false
        XCTAssertFalse(store.isMediaPolling)
    }

    /// A visible surface alone never starts the loop (no live call).
    func testMediaSilentWithoutLiveCall() async {
        let store = CallStore()
        let fetches = TickStormCounter()
        store.statusFetcher = {
            fetches.inc()
            return nil
        }
        store.callWindowOpen = true
        store.refresh()
        await spinUntil({ fetches.n == 1 && !store.isRefreshInflight })
        XCTAssertFalse(store.isMediaPolling)
        store.callWindowOpen = false
    }

    /// Re-adopting an identical slot publishes nothing (guarded assigns).
    func testIdenticalSlotSilent() async {
        let store = CallStore()
        let fetches = TickStormCounter()
        let live = Self.liveCall
        store.statusFetcher = {
            fetches.inc()
            return live
        }
        store.refresh()
        await spinUntil({ store.call?.id == "live-1" && !store.isRefreshInflight })
        XCTAssertEqual(store.call?.id, "live-1")
        let sends = TickStormCounter()
        let sub = store.objectWillChange.sink { _ in sends.inc() }
        store.refresh()
        await spinUntil({ fetches.n == 2 && !store.isRefreshInflight })
        await settle()
        XCTAssertEqual(sends.n, 0)
        _ = sub
    }

    /// Live connected call with media attached.
    static var liveCall: CallInfo {
        CallInfo(
            id: "live-1", dir: "out", peer: "8:orgid:peer",
            peerName: "Peer", thread: "19:live@thread.v2",
            state: "connected", controller: nil, startedAt: 1,
            detail: nil, liveMedia: true)
    }

    /// Wait until the condition holds. Deadline-bounded, not yield-count
    /// bounded: the fetch runs on a detached thread, so a fixed number of
    /// yields can run out before it lands when the full suite loads the
    /// CPU (testMediaGatedOnSurfaces flaked that way). Asserts stay counts.
    private func spinUntil(
        _ done: @escaping () -> Bool, timeout: TimeInterval = 10
    ) async {
        let end = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() > end { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Fixed settle budget (lets cross-thread publishes land; no clock).
    private func settle(yields: Int = 500) async {
        for _ in 0..<yields { await Task.yield() }
    }
}
