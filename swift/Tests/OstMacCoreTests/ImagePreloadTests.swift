// ImagePreloadTests.swift — om-imgpreload: prefetch window, cache hit,
// cancel, zero-indicator scroll simulation, Diagnostics line.
import XCTest

@testable import OstMacCore

/// Gated fetcher: fills park until released (or cancellation).
final class FetchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var gateReleased = false
    private var gateStarted: [String] = []
    private var gateCancelled: [String] = []
    private let bytes: Data

    init(bytes: Data) { self.bytes = bytes }

    func fetch(url: String) async throws -> Data {
        lock.withLock { gateStarted.append(url) }
        // Cancellation check FIRST (cooperative fetcher): a cancelled
        // fill always throws here, even if release lands first — the
        // flag-only exit below would race the release otherwise.
        do {
            while true {
                try Task.checkCancellation()
                if isReleased { return bytes }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        } catch {
            lock.withLock { gateCancelled.append(url) }
            throw error
        }
    }

    var isReleased: Bool {
        lock.lock(); defer { lock.unlock() }; return gateReleased
    }

    func release() {
        lock.lock(); gateReleased = true; lock.unlock()
    }

    var started: [String] {
        lock.lock(); defer { lock.unlock() }; return gateStarted
    }

    var cancelledURLs: [String] {
        lock.lock(); defer { lock.unlock() }; return gateCancelled
    }
}

final class ImagePreloadTests: XCTestCase {
    /// Thread where every bubble carries one photo.
    func imgThread(_ count: Int) -> [ChatMessage] {
        (0 ..< count).map { i in
            ChatMessage(
                id: "m\(i)", sender: "A", timestamp: "t", content: "",
                raw: "<p><img src=\"https://h/img\(i).png\" alt=\"p\(i)\"></p>")
        }
    }

    /// Poll until the preloader drains (bounded; returns last snapshot).
    func waitIdle(_ p: ImagePreloader, timeout: TimeInterval = 10) async -> ImagePreloader.Stats {
        // `timeout` is a hang ceiling only (raised to TestWait.hangCeiling):
        // a short wall deadline would measure scheduler load, not the preloader.
        let ceiling = max(timeout, TestWait.hangCeiling)
        let start = DispatchTime.now().uptimeNanoseconds
        while Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e9 < ceiling {
            let s = await p.snapshot()
            if s.isIdle { return s }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await p.snapshot()
    }

    // MARK: - Prefetch window

    func testWindowSpansAboveAndBelow() {
        let msgs = imgThread(30)
        let targets = ImagePreloadPolicy.targets(
            messages: msgs, visibleIDs: ["m10", "m11", "m12"])
        let idx = targets.map(\.messageIndex)
        // lookBehind 4 above m10 through lookAhead 8 below m12.
        XCTAssertEqual(Set(idx), Set(6 ..< 21))
        XCTAssertLessThan(idx.min()!, 10) // above the viewport
        XCTAssertGreaterThan(idx.max()!, 12) // below the viewport
        // Nearest-first: distances never decrease along the order.
        let dists = targets.map(\.distance)
        XCTAssertEqual(dists, dists.sorted())
        // Exact priority head: visible first, then alternating sides.
        XCTAssertEqual(
            targets.prefix(7).map(\.messageID),
            ["m10", "m11", "m12", "m9", "m13", "m8", "m14"])
    }

    func testEmptyViewportPrefetchesTail() {
        let msgs = imgThread(30)
        let targets = ImagePreloadPolicy.targets(messages: msgs, visibleIDs: [])
        // Nothing visible yet (initial land): the tail, in thread order.
        XCTAssertEqual(targets.map(\.messageIndex), Array(22 ..< 30))
    }

    func testPhotosBeforeEmoticonsAtSameDistance() {
        var msgs = imgThread(5)
        msgs[2] = ChatMessage(
            id: "m2", sender: "A", timestamp: "t", content: "",
            raw: "<p><img src=\"https://h/emo.png\" class=\"emoticon\" alt=\"(smile)\">"
                + "<img src=\"https://h/photo.png\" alt=\"pic\"></p>")
        let targets = ImagePreloadPolicy.targets(messages: msgs, visibleIDs: ["m2"])
        let m2 = targets.filter { $0.messageID == "m2" }
        // Both are prefetched; the photo jumps ahead of the emoticon
        // despite raw order.
        XCTAssertEqual(m2.map(\.url), ["https://h/photo.png", "https://h/emo.png"])
        XCTAssertTrue(m2[1].isEmoticon)
    }

    // MARK: - Cache fill + hit

    func testPrefetchFillsWindowCache() async throws {
        let msgs = imgThread(30)
        let cache = RichMediaCache(diskDir: nil, memory: .pinned)
        let preloader = ImagePreloader(cache: cache)
        let calls = Counter()
        let bytes = try DemoMedia.data(for: DemoMedia.photo1)
        await preloader.update(
            messages: msgs, visibleIDs: ["m10", "m11", "m12"],
            fetcher: { _ in
                calls.inc()
                try await Task.sleep(nanoseconds: 1_000_000)
                return bytes
            })
        let stats = await waitIdle(preloader)
        XCTAssertTrue(stats.isIdle)
        XCTAssertEqual(stats.prefetched, 15)
        XCTAssertEqual(calls.count, 15)
        for i in 6 ..< 21 {
            let hit = await cache.cached(url: "https://h/img\(i).png", messageID: "m\(i)")
            XCTAssertEqual(hit, bytes, "m\(i) not prefetched")
        }
    }

    func testWindowHitsSkipFetch() async throws {
        let msgs = imgThread(30)
        let cache = RichMediaCache(diskDir: nil, memory: .pinned)
        let bytes = try DemoMedia.data(for: DemoMedia.photo1)
        let warm = ImagePreloader(cache: cache)
        await warm.update(messages: msgs, visibleIDs: ["m10"], fetcher: { _ in bytes })
        _ = await waitIdle(warm)
        // Fresh preloader, same cache: every window target is a hit, so
        // the throwing fetcher never fires.
        let cold = ImagePreloader(cache: cache)
        await cold.update(
            messages: msgs, visibleIDs: ["m10"],
            fetcher: { _ in throw MediaFetchError.failed("must not refetch") })
        let stats = await waitIdle(cold)
        XCTAssertTrue(stats.isIdle)
        XCTAssertEqual(stats.hits, 13) // window 6..<19
        XCTAssertEqual(stats.prefetched, 0)
    }

    // MARK: - Cancel

    func testCancelFarFetches() async throws {
        let msgs = imgThread(30)
        let cache = RichMediaCache(diskDir: nil, memory: .pinned)
        let preloader = ImagePreloader(cache: cache, maxConcurrent: 1)
        let gate = FetchGate(bytes: try DemoMedia.data(for: DemoMedia.photo1))
        let fetcher: RichMediaCache.Fetcher = { [gate] url in try await gate.fetch(url: url) }
        // Window A: visible m0 → 0..<9. One fill runs, the rest queue.
        await preloader.update(messages: msgs, visibleIDs: ["m0"], fetcher: fetcher)
        var running = false
        let runStart = DispatchTime.now().uptimeNanoseconds
        while Double(DispatchTime.now().uptimeNanoseconds &- runStart) / 1e9 < TestWait.hangCeiling {
            if await preloader.snapshot().inFlight == 1, !gate.started.isEmpty {
                running = true
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(running, "prefetch never started")
        // Jump far: visible m29 → window 25..<30, keep 9..<30. The m0
        // fill (index 0) cancels; queued A targets drop.
        await preloader.update(messages: msgs, visibleIDs: ["m29"], fetcher: fetcher)
        var stats = await preloader.snapshot()
        XCTAssertEqual(stats.cancelled, 1)
        XCTAssertEqual(stats.inFlight, 1) // B's head fill already launched
        gate.release()
        stats = await waitIdle(preloader)
        XCTAssertTrue(stats.isIdle)
        XCTAssertEqual(stats.prefetched, 5)
        // B's window filled; the cancelled A head never landed.
        for i in 25 ..< 30 {
            let filled = await cache.cached(url: "https://h/img\(i).png", messageID: "m\(i)")
            XCTAssertNotNil(filled, "m\(i) not prefetched after jump")
        }
        let dropped = await cache.cached(url: "https://h/img0.png", messageID: "m0")
        XCTAssertNil(dropped)
        XCTAssertTrue(gate.cancelledURLs.contains("https://h/img0.png"))
        // Queued A targets (m1..m8) never started; B launches ran
        // nearest-first behind the cap (maxConcurrent 1 serializes them).
        XCTAssertEqual(
            gate.started,
            ["https://h/img0.png", "https://h/img29.png", "https://h/img28.png",
             "https://h/img27.png", "https://h/img26.png", "https://h/img25.png"])
    }

    // MARK: - Zero-indicator scroll simulation

    func testZeroIndicatorScrollSimulation() async {
        // Image-heavy thread: every bubble carries a photo. The reader
        // scrolls top to bottom; before each viewport step the timeline
        // reschedules prefetch (the production onAppear path). Every
        // image must already be cached the moment its bubble appears —
        // zero loading indicators — and each image fetched exactly once.
        let msgs = imgThread(40)
        let cache = RichMediaCache(diskDir: nil, memory: .pinned)
        let preloader = ImagePreloader(cache: cache)
        let calls = Counter()
        let fetcher: RichMediaCache.Fetcher = { _ in
            calls.inc()
            try await Task.sleep(nanoseconds: 2_000_000) // network latency
            return Data([7, 7, 7])
        }
        var misses = 0
        var step = 0
        while step + 5 <= 40 {
            let vis = Set((step ..< step + 5).map { "m\($0)" })
            await preloader.update(messages: msgs, visibleIDs: vis, fetcher: fetcher)
            _ = await waitIdle(preloader)
            for i in step ..< step + 5 {
                let hit = await cache.cached(url: "https://h/img\(i).png", messageID: "m\(i)")
                if hit == nil { misses += 1 }
            }
            step += 3
        }
        XCTAssertEqual(misses, 0, "images shown without prefetched bytes")
        XCTAssertEqual(calls.count, 40, "each image fetched exactly once")
    }

    // MARK: - Diagnostics

    func testPreloadLine() {
        XCTAssertEqual(
            DiagnosticsFormat.preloadLine(prefetched: 3, hits: 12, cancelled: 1, inFlight: 2),
            "3 prefetched · 12 hits · 1 cancelled · 2 in flight")
    }
}
