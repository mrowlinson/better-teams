// CatchUpMeasureTests.swift — AICATCH lane: CPU + energy cost of on-device
// catch-up on demo data, with the LIVE Apple on-device model. Skipped
// unless AICATCH_MEASURE=1 (minutes long; needs Apple Intelligence).
//   (a) on-click: one catch-up of the largest demo conversation (cold, warm)
//   (b) always up to date: 3 conversations, a demo message every 20 s for
//       5 min, 30 s debounce — steady-state cost.
// CPU = this process (getrusage) + every other process's `ps` CPU-time
// delta (inference runs out of process); energy = `top` POWER samples.
import Darwin
import XCTest

@testable import OstMacCore

@MainActor
final class CatchUpMeasureTests: XCTestCase {
    private func shell(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// pid → (command, CPU seconds) for every process.
    private func psSnap() -> [Int32: (String, Double)] {
        var out: [Int32: (String, Double)] = [:]
        for line in shell("/bin/ps", ["-axo", "pid=,time=,comm="]).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]) else { continue }
            let t = parts[1].split(separator: ":").compactMap { Double($0) }
            let secs = t.count == 3 ? t[0] * 3600 + t[1] * 60 + t[2] : t.count == 2 ? t[0] * 60 + t[1] : 0
            out[pid] = (String(parts[2].split(separator: "/").last ?? ""), secs)
        }
        return out
    }

    private func selfCPU() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    /// Top-5 CPU-time deltas among other processes (excludes this one).
    private func deltas(_ a: [Int32: (String, Double)], _ b: [Int32: (String, Double)]) -> String {
        let me = getpid()
        return b.compactMap { pid, v -> (String, Double)? in
            guard pid != me else { return nil }
            return (v.0, v.1 - (a[pid]?.1 ?? 0))
        }
        .sorted { $0.1 > $1.1 }.prefix(5)
        .map { "\($0.0)=\(String(format: "%.1f", $0.1))s" }.joined(separator: " ")
    }

    /// One `top` POWER sample: this process + the top 3 others.
    private func powerSample() -> String {
        let text = shell("/usr/bin/top", ["-l", "2", "-s", "1", "-n", "8", "-o", "power", "-stats", "pid,command,cpu,power"])
        guard let r = text.range(of: "PID", options: .backwards) else { return "top: n/a" }
        let rows = text[r.upperBound...].split(separator: "\n").dropFirst().prefix(4)
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
        return rows.joined(separator: " | ")
    }

    func testMeasureOnDeviceCatchUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AICATCH_MEASURE"] == "1", "set AICATCH_MEASURE=1")
        let avail = OnDeviceSummary.liveAvailability()
        print("AICATCH-MEASURE availability=\(avail) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
        try XCTSkipUnless(avail == .available, "on-device model not available")
        let transport = OnDeviceCatchUpTransport()
        func size(_ ms: [ChatMessage]) -> Int { ms.reduce(0) { $0 + $1.content.count } }
        var threads: [(ChatItem, [ChatMessage])] = DemoData.chats.map { ($0, DemoData.messages(for: $0.id)) }
        threads.sort { size($0.1) > size($1.1) }

        let env = ProcessInfo.processInfo.environment
        let arrivals = Int(env["AICATCH_MEASURE_ARRIVALS"] ?? "") ?? 15
        // (a) on click (AICATCH_MEASURE_SKIP_A=1 skips it)
        let big = threads[0]
        for label in env["AICATCH_MEASURE_SKIP_A"] == "1" ? [] : ["cold", "warm"] {
            let p0 = psSnap(), s0 = selfCPU(), t0 = Date()
            let text = try await OnDeviceCatchUpEngine(transport: transport).summarize(messages: big.1)
            let wall = Date().timeIntervalSince(t0), s1 = selfCPU(), p1 = psSnap()
            let parsed = CatchUpSummaryParser.parse(text)
            print("AICATCH-MEASURE a-\(label) msgs=\(big.1.count) chars=\(size(big.1)) plan=\(OnDeviceCatchUpEngine.plan(messages: big.1, previous: nil)) wall=\(String(format: "%.1f", wall))s selfCPU=\(String(format: "%.2f", s1 - s0))s others: \(deltas(p0, p1))")
            print("AICATCH-MEASURE a-\(label) parsed summary=\(!parsed.summary.isEmpty) points=\(parsed.points.count) actions=\(parsed.actions.count)")
            print("AICATCH-MEASURE a-\(label) power: \(powerSample())")
        }

        // (b) always up to date
        let picks = Array(threads.prefix(3))
        let digest = CatchUpDigestStore(transport: transport, mode: { .alwaysUpToDate }, observeSystem: false)
        digest.debounce = .seconds(30)
        digest.ownerDisplayName = { DemoData.ownerDisplayName }
        digest.seed = { picks.map { ($0.0.id, $0.0.name, $0.1) } }
        var p0 = psSnap(), s0 = selfCPU(), t0 = Date()
        digest.modeChanged(.alwaysUpToDate)
        while digest.pending > 0 || digest.working != nil, Date().timeIntervalSince(t0) < 240 {
            try await Task.sleep(for: .seconds(1))
        }
        print("AICATCH-MEASURE b-seed chats=3 summaries=\(digest.summariesRun) wall=\(String(format: "%.0f", Date().timeIntervalSince(t0)))s selfCPU=\(String(format: "%.2f", selfCPU() - s0))s others: \(deltas(p0, psSnap()))")

        // Steady state: one demo message every 20 s for 5 min.
        let pool: [ChatMessage] = threads.dropFirst(3).flatMap { $0.1 }.filter { !$0.content.isEmpty }
        let base = digest.summariesRun
        p0 = psSnap(); s0 = selfCPU(); t0 = Date()
        var powers: [String] = []
        for i in 0 ..< arrivals {
            let src = pool[i % pool.count]
            let chat = picks[i % 3].0
            let m = ChatMessage(id: "measure-\(i)", sender: src.sender,
                                timestamp: "2099-01-01T00:\(String(format: "%02d", i)):00Z", content: src.content)
            digest.ingest(chatID: chat.id, chatName: chat.name, messages: [m])
            try await Task.sleep(for: .seconds(20))
            if i % 3 == 2 { powers.append(powerSample()) }
        }
        let steadyWall = Date().timeIntervalSince(t0)
        let drainStart = Date()
        while digest.pending > 0 || digest.working != nil, Date().timeIntervalSince(drainStart) < 90 {
            try await Task.sleep(for: .seconds(1))
        }
        print("AICATCH-MEASURE b-steady end pending=\(digest.pending) working=\(digest.working ?? "-") error=\(digest.lastError ?? "-")")
        print("AICATCH-MEASURE b-steady arrivals=\(arrivals) window=\(String(format: "%.0f", steadyWall))s+drain=\(String(format: "%.0f", Date().timeIntervalSince(drainStart)))s summaries=\(digest.summariesRun - base) selfCPU=\(String(format: "%.2f", selfCPU() - s0))s others: \(deltas(p0, psSnap()))")
        for (i, p) in powers.enumerated() { print("AICATCH-MEASURE b-power[\(i)]: \(p)") }
        // Idle: nothing arriving → no timer, no work.
        p0 = psSnap(); s0 = selfCPU()
        try await Task.sleep(for: .seconds(60))
        print("AICATCH-MEASURE b-idle60s summaries=\(digest.summariesRun - base) selfCPU=\(String(format: "%.2f", selfCPU() - s0))s others: \(deltas(p0, psSnap()))")
    }
}
