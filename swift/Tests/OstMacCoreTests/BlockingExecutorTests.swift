// BlockingExecutorTests.swift — CHATPERF R22.2: blocking core calls run on
// BlockingExecutor, never the Swift cooperative pool.
//
//   * executor behaviour: off-pool thread, results/errors/cancel, bounded
//     width, interactive jobs not stuck behind background saturation;
//   * P2 starvation proof: saturate blocking calls (fake core = sleeps) and
//     show unrelated async work, a MainActor task awaiting nonisolated async
//     work, and a real ChatListViewModel load still finish within a bound,
//     with a main-queue lateness watchdog running. The same harness run with
//     the legacy switch (Task.detached semantics) MUST starve: that is the
//     negative control / mutation check;
//   * lint: no Task.detached or DispatchQueue.global in Sources outside the
//     executor file.
//   * P4 timing (CHATPERF-TIMING lines in the log): time-to-content with and
//     without launch fan-out, new vs legacy.
import XCTest

@testable import OstMacCore

// MARK: - Helpers

private final class BEPeakCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var cur = 0
    private(set) var peak = 0
    func enter() {
        lock.lock(); cur += 1; peak = max(peak, cur); lock.unlock()
    }
    func leave() {
        lock.lock(); cur -= 1; lock.unlock()
    }
}

private final class BEDone: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}

private final class BEFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    private var at = DispatchTime.now()
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); if !v { v = true; at = .now() }; lock.unlock() }
    /// Seconds from `t0` to the moment `set()` was called.
    func elapsed(since t0: DispatchTime) -> Double {
        lock.lock(); defer { lock.unlock() }
        return Double(at.uptimeNanoseconds &- t0.uptimeNanoseconds) / 1e9
    }
}

private struct BEBoom: Error {}

/// Main-queue lateness watchdog: a 10 ms repeating timer on the main queue;
/// records the worst gap beyond the interval between firings.
private final class MainLatenessWatchdog: @unchecked Sendable {
    private var timer: DispatchSourceTimer?
    private var last = DispatchTime.now()
    private(set) var worstLateness: Double = 0
    private let interval = 0.010

    func start() {
        last = .now()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [self] in
            let now = DispatchTime.now()
            let gap = Double(now.uptimeNanoseconds &- last.uptimeNanoseconds) / 1e9
            worstLateness = max(worstLateness, gap - interval)
            last = now
        }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }
}

/// Nonisolated async work: hops to the cooperative pool (Swift 5 mode).
private func unrelatedAsyncWork() async -> Int {
    await Task.yield()
    return 42
}

private func seconds(_ from: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds &- from.uptimeNanoseconds) / 1e9
}


@MainActor
final class BlockingExecutorTests: XCTestCase {
    override func tearDown() async throws {
        BlockingExecutor.legacyCooperativePool = false
    }

    // MARK: executor behaviour

    func testBodyRunsOnDedicatedThreadNotPool() async {
        let name = await Task.blocking { Thread.current.name ?? "" }.value
        XCTAssertTrue(name.hasPrefix("dev.ostmac.blocking"), "ran on \(name)")
    }

    func testResultsErrorsAndAsyncBodies() async throws {
        let v = try await Task.blocking { 7 }.value
        XCTAssertEqual(v, 7)
        do {
            _ = try await Task.blocking { () throws -> Int in throw BEBoom() }.value
            XCTFail("expected throw")
        } catch { XCTAssertTrue(error is BEBoom) }
        // An await inside the body returns the thread and resumes on the executor.
        let name = await Task.blocking { () async -> String in
            _ = await unrelatedAsyncWork()
            return Thread.current.name ?? ""
        }.value
        XCTAssertTrue(name.hasPrefix("dev.ostmac.blocking"), "resumed on \(name)")
        let r = try await BlockingExecutor.run { 3 + 4 }
        XCTAssertEqual(r, 7)
    }

    func testCancelReachesBody() async {
        let started = BEFlag()
        let t = Task.blocking { () -> Bool in
            started.set()
            while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
            return true
        }
        while !started.value { try? await Task.sleep(nanoseconds: 2_000_000) }
        t.cancel()
        let saw = await t.value
        XCTAssertTrue(saw)
    }

    func testWidthIsBoundedAndBackgroundCapped() async {
        let exec = BlockingExecutor(name: "test.blocking", width: 6, backgroundWidth: 3)
        let all = BEPeakCounter()
        let bg = BEPeakCounter()
        var tasks: [Task<Void, Never>] = []
        for _ in 0..<40 {
            tasks.append(
                Task.detached(executorPreference: exec, priority: .utility) {
                    all.enter(); bg.enter()
                    Thread.sleep(forTimeInterval: 0.02)
                    bg.leave(); all.leave()
                })
        }
        for t in tasks { await t.value }
        XCTAssertLessThanOrEqual(exec.threadCount, 6)
        XCTAssertLessThanOrEqual(bg.peak, 3, "background jobs exceeded their cap")
        XCTAssertGreaterThanOrEqual(bg.peak, 2, "background jobs never ran in parallel")
    }

    func testInteractiveJobNotStuckBehindBackgroundSaturation() async {
        let exec = BlockingExecutor(name: "test.blocking", width: 6, backgroundWidth: 3)
        var bg: [Task<Void, Never>] = []
        for _ in 0..<12 {
            bg.append(Task.detached(executorPreference: exec, priority: .utility) {
                Thread.sleep(forTimeInterval: 0.5)
            })
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let t0 = DispatchTime.now()
        await Task.detached(executorPreference: exec, priority: .userInitiated) { () -> Int in 1 }.value
        let dt = seconds(t0)
        XCTAssertLessThan(dt, 0.25, "interactive job waited \(dt)s behind background")
        for t in bg { await t.value }
    }

    // MARK: P2 starvation proof
    //
    // Harness notes (measured on this OS): the cooperative pool starves per
    // QoS bucket. Saturating `.utility` starves `.utility` work only, and
    // `.userInitiated` starves `.userInitiated` only; nil-priority detached
    // tasks did not starve in a probe. So the harness saturates BOTH explicit
    // buckets (the app has ~10 sites of each) and probes in both. A
    // `Task.detached` the caller awaits from a higher-priority context is
    // escalated out of the bucket, so probes are fire-and-forget and
    // completion is polled from a flag.

    private struct Measured {
        var unrelated: Double
        var mainHop: Double
        var chatList: Double
        var lateness: Double
    }

    /// Poll until `flag` is set (never awaits the task: no escalation).
    private func waitSeconds(_ flag: BEFlag, from t0: DispatchTime, limit: Double = 8) async -> Double {
        while !flag.value, seconds(t0) < limit { try? await Task.sleep(nanoseconds: 1_000_000) }
        return seconds(t0)
    }

    private func drain(_ done: BEDone, _ n: Int) async {
        let t0 = DispatchTime.now()
        while done.count < n, seconds(t0) < 15 { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// Saturate blocking calls (fake core = 0.6 s sleeps, more than the
    /// pool is wide), then measure how long unrelated work takes.
    private func measureUnderSaturation(legacy: Bool) async -> Measured {
        BlockingExecutor.legacyCooperativePool = legacy
        defer { BlockingExecutor.legacyCooperativePool = false }
        let dog = MainLatenessWatchdog()
        dog.start()
        defer { dog.stop() }

        let done = BEDone()
        let n = ProcessInfo.processInfo.activeProcessorCount + 4
        for _ in 0..<n {
            Task.blocking(priority: .utility) { Thread.sleep(forTimeInterval: 0.6); done.bump() }
            Task.blocking(priority: .userInitiated) { Thread.sleep(forTimeInterval: 0.6); done.bump() }
        }
        try? await Task.sleep(nanoseconds: 150_000_000)

        // All three probes start together, right after saturation begins.
        let t0 = DispatchTime.now()
        let fa = BEFlag(), fb = BEFlag(), fc = BEFlag(), ok = BEFlag()
        // A: unrelated async work (any pool consumer in the app).
        Task.detached(priority: .utility) { _ = await unrelatedAsyncWork(); fa.set() }
        // B: MainActor task hopping to nonisolated async work (a UI hop).
        Task(priority: .utility) { @MainActor in _ = await unrelatedAsyncWork(); fb.set() }
        // C: real chat-list load through the fake core (350 ms fetch).
        Task(priority: .userInitiated) { @MainActor in
            let model = ChatListViewModel(fetcher: { _ in
                Thread.sleep(forTimeInterval: 0.35)
                return ChatListTests.chatsJSON(ChatListTests.chatJSON(id: "8:a", name: "A"))
            })
            await model.load()
            if model.state == .loaded { ok.set() }
            fc.set()
        }
        for f in [fa, fb, fc] { _ = await waitSeconds(f, from: t0) }
        XCTAssertTrue(ok.value)
        let unrelated = fa.elapsed(since: t0), mainHop = fb.elapsed(since: t0), list = fc.elapsed(since: t0)

        await drain(done, 2 * n)
        return Measured(unrelated: unrelated, mainHop: mainHop, chatList: list, lateness: dog.worstLateness)
    }

    func testSaturatedBlockingCallsDoNotStarveUnrelatedWork() async {
        let m = await measureUnderSaturation(legacy: false)
        print("CHATPERF-STARVE new unrelated=\(m.unrelated) mainHop=\(m.mainHop) list=\(m.chatList) lateness=\(m.lateness)")
        XCTAssertLessThan(m.unrelated, 0.25, "unrelated async work stalled")
        XCTAssertLessThan(m.mainHop, 0.25, "MainActor hop to nonisolated work stalled")
        XCTAssertLessThan(m.chatList, 0.7, "chat list load stalled behind saturation")
        XCTAssertLessThan(m.lateness, 0.25, "main queue late")
    }

    /// Negative control / mutation check: the old pattern (Task.detached on
    /// the cooperative pool) MUST starve under the identical load, or the
    /// test above proves nothing.
    func testLegacyDetachedPatternStarvesUnderSameLoad() async {
        let m = await measureUnderSaturation(legacy: true)
        print("CHATPERF-STARVE legacy unrelated=\(m.unrelated) mainHop=\(m.mainHop) list=\(m.chatList) lateness=\(m.lateness)")
        XCTAssertGreaterThan(m.unrelated, 0.4, "old pattern did not starve unrelated work; harness is blind")
        XCTAssertGreaterThan(m.mainHop, 0.4, "old pattern did not starve the MainActor hop")
        XCTAssertGreaterThan(m.chatList, 0.7, "old pattern did not delay the chat-list load")
    }

    // MARK: lint

    /// Lines of code (comment lines and `//` tails dropped) that a rule flags.
    static func violations(in text: String, file: String) -> [String] {
        var out: [String] = []
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = String(raw)
            if let r = line.range(of: "//") { line = String(line[..<r.lowerBound]) }
            if line.contains("Task.detached") || line.contains("DispatchQueue.global") {
                out.append("\(file):\(i + 1): \(raw.trimmingCharacters(in: .whitespaces))")
            }
        }
        return out
    }

    func testLintCatchesTheOldPattern() {
        XCTAssertEqual(Self.violations(in: "let x = try await Task.detached { try RustCore.whoami() }.value", file: "f").count, 1)
        XCTAssertEqual(Self.violations(in: "DispatchQueue.global(qos: .userInitiated).async { }", file: "f").count, 1)
        XCTAssertEqual(Self.violations(in: "// Task.detached is banned\nlet t = Task.blocking { }", file: "f").count, 0)
    }

    func testNoTaskDetachedOrGlobalQueueOutsideTheExecutor() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let en = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        var bad: [String] = []
        for case let url as URL in en where url.pathExtension == "swift" {
            scanned += 1
            if url.lastPathComponent == "BlockingExecutor.swift" { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            bad += Self.violations(in: text, file: url.lastPathComponent)
        }
        XCTAssertGreaterThan(scanned, 100, "lint scanned too few files")
        XCTAssertEqual(bad, [], "blocking work must use Task.blocking / BlockingExecutor.run")
    }

    // MARK: P4 timing

    private static func pct(_ xs: [Double]) -> String {
        let s = xs.sorted()
        let p50 = s[s.count / 2]
        let p95 = s[min(s.count - 1, Int((Double(s.count) * 0.95).rounded(.up)) - 1)]
        return String(format: "p50=%.3fs p95=%.3fs", p50, p95)
    }

    /// Open-chat replica: ConversationStore.open runs two sequential
    /// blocking hops (priority nil before this lane, .userInitiated after) (whoami, then messages; RustCore is not
    /// fakeable). Latencies 80 ms + 350 ms.
    private nonisolated static func openChatReplica(priority: TaskPriority?) async {
        _ = try? await Task.blocking(priority: priority) { () throws -> Int in
            Thread.sleep(forTimeInterval: 0.08); return 1
        }.value
        _ = try? await Task.blocking(priority: priority) { () throws -> Int in
            Thread.sleep(forTimeInterval: 0.35); return 1
        }.value
    }

    /// The pre-lane chat-list offPool (GCD global queue), fake 350 ms fetch.
    private nonisolated static func listViaOldGCD() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                Thread.sleep(forTimeInterval: 0.35)
                c.resume()
            }
        }
    }

    private nonisolated static func listFirstPage() async -> Double {
        await MainActor.run {} // hop like a store kicked off from the UI
        return await Task { @MainActor () -> Double in
            let model = ChatListViewModel(fetcher: { _ in
                Thread.sleep(forTimeInterval: 0.35)
                return ChatListTests.chatsJSON(ChatListTests.chatJSON(id: "8:a", name: "A"))
            })
            let t0 = DispatchTime.now()
            await model.load()
            return seconds(t0)
        }.value
    }

    /// Time `body` run in a default-priority Task (not awaited: no escalation)
    /// with optional launch fan-out (blocking calls, 1.2 s each) in flight.
    private func timed(fanout: Bool, legacy: Bool, _ body: @escaping @Sendable () async -> Void) async -> Double {
        BlockingExecutor.legacyCooperativePool = legacy
        defer { BlockingExecutor.legacyCooperativePool = false }
        let done = BEDone()
        let n = ProcessInfo.processInfo.activeProcessorCount + 4
        if fanout {
            for _ in 0..<n {
                Task.blocking(priority: .utility) { Thread.sleep(forTimeInterval: 1.2); done.bump() }
                Task.blocking(priority: .userInitiated) { Thread.sleep(forTimeInterval: 1.2); done.bump() }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        let t0 = DispatchTime.now()
        let f = BEFlag()
        Task(priority: .userInitiated) { await body(); f.set() }
        let dt = await waitSeconds(f, from: t0, limit: 10)
        if fanout { await drain(done, 2 * n) }
        return dt
    }

    func testTimeToContentBeforeAfter() async {
        for (label, fanout, legacy) in [
            ("idle    new   ", false, false), ("idle    legacy", false, true),
            ("fanout  new   ", true, false), ("fanout  legacy", true, true),
        ] {
            var open: [Double] = []
            var list: [Double] = []
            var gcd: [Double] = []
            for _ in 0..<5 {
                open.append(await timed(fanout: fanout, legacy: legacy) { await Self.openChatReplica(priority: legacy ? nil : .userInitiated) })
                list.append(await timed(fanout: fanout, legacy: legacy) { _ = await Self.listFirstPage() })
                if legacy { gcd.append(await timed(fanout: fanout, legacy: legacy) { await Self.listViaOldGCD() }) }
            }
            print("CHATPERF-TIMING \(label) openChat \(Self.pct(open)) | chatListFirstPage \(Self.pct(list))"
                + (legacy ? " | chatList via pre-lane GCD offPool \(Self.pct(gcd))" : ""))
        }
    }
}
