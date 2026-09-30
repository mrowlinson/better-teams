// CatchUpEvalTests.swift — CATCHTABS lane: model-dependent eval of the
// Catch Up noise pipeline on the labeled fixture, plus the energy cost of
// a 2-week refresh. LIVE Apple on-device model; skipped unless
// CATCHTABS_EVAL=1 and the model is available.
//
// Before = the pre-CATCHTABS input (each chat's newest 60 messages, no age
// bound, no filter, no rating). After = period-bounded + noise-filtered +
// salience-ranked input, then the bullet rating pass. Bullets are matched
// back to fixture items by keyword; precision = bullets matching only
// in-period signal / bullets matching any item; recall = in-period signal
// items mentioned by some bullet.
import Darwin
import XCTest

@testable import OstMacCore

/// Counts rating calls (the pass skips the model when every bullet is strong).
final class RatingCounter: CatchUpTransport, @unchecked Sendable {
    let inner: any CatchUpTransport
    var count = 0
    init(inner: any CatchUpTransport) { self.inner = inner }
    func complete(baseURL: String, apiKey: String, model: String, prompt: String) async throws -> String {
        count += 1
        return try await inner.complete(baseURL: baseURL, apiKey: apiKey, model: model, prompt: prompt)
    }
}

@MainActor
final class CatchUpEvalTests: XCTestCase {
    /// Keyword regex alternations per fixture item (word-bounded).
    static let keys: [String: String] = [
        "l01": "atlas|release notes|sign off|sign-off", "l02": "sandbox|payments", "l03": "morning", "l05": "phased|rollout",
        "l06": "lol", "l07": "go/no-go|audit", "l08": "coffee", "l09": "kestrel|load test", "l10": "happy friday",
        "l11": "runbook", "l12": "kudos|great job", "l13": "burrito|lunch orders?", "l14": "burrito", "l15": "burrito",
        "l16": "orion|vendor contract", "l17": "weather|weekend", "l18": "helios|migration", "l19": "birthday",
        "l20": "zephyr|budget freeze", "l21": "security", "l22": "see you",
        "d01": "layouts?", "d03": "teal|gradient", "d05": "icons?|icon set", "d07": "usability", "d08": "quick call",
        "d09": "cake|anniversary", "d10": "settings|spec", "d12": "contrast|accessibility", "d13": "morning",
        "o01": "latency|incident", "o02": "cache|rolled back", "o03": "on my way", "o04": "postmortem|timeline",
        "o06": "lunch", "o07": "nodes|disk|queue", "o08": "late|standup", "o09": "pager|rotation", "o11": "in the office",
        "o12": "tls|certificates?", "o13": "hotfix", "o14": "charger",
        "a01": "hiring", "a02": "coffee", "a03": "weekend", "a04": "budget review|budget", "a06": "scorecards?",
        "a07": "meme", "a08": "performance",
        "f01": "donuts?", "f02": "pizza", "f03": "electrical|closed|work from home", "f04": "birthday", "f05": "sushi",
        "f06": "welcome", "f07": "food truck", "f08": "badges?", "f09": "picnic|weather", "f10": "promotion",
        "f11": "summer party|party",
    ]

    static let socialLine = "Leave out social chat: food or drink orders, greetings, thanks, jokes, celebrations, and plans whose moment has passed."

    struct Score {
        var good = 0, bad = 0, unmatched = 0, signalHit = Set<String>(), signalTotal = 0
        var precision: Double { Double(good) / Double(max(1, good + bad)) }
        var recall: Double { Double(signalHit.count) / Double(max(1, signalTotal)) }
        var line: String {
            String(format: "P=%.2f R=%.2f (good %d, bad %d, unmatched %d, signal %d/%d)",
                   precision, recall, good, bad, unmatched, signalHit.count, signalTotal)
        }
    }

    static func matches(_ bullet: String, _ id: String) -> Bool {
        guard let k = keys[id] else { return false }
        return bullet.range(of: "\\b(\(k))\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func score(_ s: inout Score, chatID: String, bullets: [String], period: CatchUpPeriod?) {
        let items = CatchUpFixture.items.filter { $0.chatID == chatID }
        let inP: (CatchUpFixture.Item) -> Bool = { item in period.map { p in CatchUpFixture.inPeriod(item, p) } ?? true }
        for b in bullets {
            let hits = items.filter { matches(b, $0.id) }
            if hits.isEmpty { s.unmatched += 1; continue }
            if hits.contains(where: { !$0.signal || !inP($0) }) { s.bad += 1 } else { s.good += 1 }
            for h in hits where h.signal && inP(h) { s.signalHit.insert(h.id) }
        }
    }

    private func selfCPU() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    /// CPU seconds of other processes whose name contains `needle`.
    private func otherCPU(_ needle: String) -> Double {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "time=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var total = 0.0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.contains(needle) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let t = parts.first?.split(separator: ":").compactMap { Double($0) } ?? []
            total += t.count == 3 ? t[0] * 3600 + t[1] * 60 + t[2] : t.count == 2 ? t[0] * 60 + t[1] : 0
        }
        return total
    }

    private func bullets(_ text: String) -> [String] {
        let p = CatchUpSummaryParser.parse(text)
        return p.points + p.actions
    }

    func testEvalAndEnergyOnFixture() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CATCHTABS_EVAL"] == "1", "set CATCHTABS_EVAL=1")
        try XCTSkipUnless(OnDeviceSummary.liveAvailability() == .available, "on-device model not available")
        let transport = OnDeviceCatchUpTransport()
        let engine = OnDeviceCatchUpEngine(transport: transport)
        let now = Date()
        let threads = CatchUpFixture.threads(now: now)
        var out: [String] = []
        let service = "InferenceProvider"

        // BEFORE (also the 2-week "before" energy run).
        var beforeDay = Score(), beforeTwo = Score()
        var t0 = Date(), c0 = selfCPU(), s0 = otherCPU(service)
        for t in threads {
            // The pre-CATCHTABS prompt (no "leave out social chat" line);
            // every fixture chat fits one call.
            let chunks = CatchUpChunker.chunks(CatchUpChunker.lines(Array(t.messages.suffix(60))))
            XCTAssertEqual(chunks.count, 1)
            let oldPrompt = CatchUpPrompts.final(transcript: chunks[0])
                .replacingOccurrences(of: Self.socialLine + "\n", with: "")
            XCTAssertFalse(oldPrompt.contains("social chat"))
            let text = try await transport.complete(baseURL: "", apiKey: "", model: "", prompt: oldPrompt)
            let b = bullets(text)
            out.append("BEFORE \(t.chatID): " + b.joined(separator: " | "))
            Self.score(&beforeDay, chatID: t.chatID, bullets: b, period: .day)
            Self.score(&beforeTwo, chatID: t.chatID, bullets: b, period: .twoWeeks)
        }
        let beforeEnergy = (Date().timeIntervalSince(t0), selfCPU() - c0, otherCPU(service) - s0)

        // AFTER, per period; raw = before the rating pass.
        var energy: [CatchUpPeriod: (Double, Double, Double, Int)] = [:]
        var summary: [String] = []
        for p in [CatchUpPeriod.day, .twoWeeks] {
            var sa = Score(), sr = Score()
            var calls = 0
            t0 = Date(); c0 = selfCPU(); s0 = otherCPU(service)
            for t in threads {
                let ctx = CatchUpFilterContext(now: now, chatID: t.chatID, ownerDisplayName: CatchUpFixture.owner)
                let input = CatchUpPipeline.prepare(t.messages, period: p, ctx)
                guard !input.isEmpty else { continue }
                let raw = try await engine.summarize(messages: input)
                let refined = CatchUpPipeline.refine(raw, ctx)
                calls += 1
                out.append("AFTER-\(p.rawValue) \(t.chatID) raw: " + bullets(raw).joined(separator: " | "))
                out.append("AFTER-\(p.rawValue) \(t.chatID) kept: " + bullets(refined).joined(separator: " | "))
                Self.score(&sr, chatID: t.chatID, bullets: bullets(raw), period: p)
                Self.score(&sa, chatID: t.chatID, bullets: bullets(refined), period: p)
            }
            energy[p] = (Date().timeIntervalSince(t0), selfCPU() - c0, otherCPU(service) - s0, calls)
            for c in CatchUpFixture.items where c.signal && CatchUpFixture.inPeriod(c, p) { sa.signalTotal += 1; sr.signalTotal += 1 }
            let before = p == .day ? beforeDay : beforeTwo
            var b = before
            b.signalTotal = CatchUpFixture.items.filter { $0.signal && CatchUpFixture.inPeriod($0, p) }.count
            summary.append("\(p.rawValue): before \(b.line) | filtered-unrated \(sr.line) | after \(sa.line)")
        }
        let e2 = energy[.twoWeeks]!
        summary.append(String(format: "ENERGY 2w refresh: before wall %.1fs appCPU %.2fs inferenceCPU %.2fs (5 chats, unbounded) | after wall %.1fs appCPU %.2fs inferenceCPU %.2fs (%d calls)",
                              beforeEnergy.0, beforeEnergy.1, beforeEnergy.2, e2.0, e2.1, e2.2, e2.3))
        for s in summary { print("CATCHTABS-EVAL " + s) }
        if let path = ProcessInfo.processInfo.environment["CATCHTABS_EVAL_OUT"] {
            try (summary + [""] + out).joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
