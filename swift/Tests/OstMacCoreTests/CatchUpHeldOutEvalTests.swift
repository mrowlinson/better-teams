// CatchUpHeldOutEvalTests.swift — CATCHEVAL lane: the Catch Up pipeline
// scored on a HELD-OUT fixture (CatchUpHeldOutFixture.swift), written by
// an independent author who never saw the filter rules or prompts, and
// never used to tune them.
//
// Always-on tests: the fixture's keyword scorer is self-consistent, and
// no fixture content appears in any prompt the pipeline sends.
//
// Opt-in eval (CATCHEVAL=1, LIVE Apple on-device model, ~15-30 min):
// every (chat, period) pair runs prepare -> summarize -> bullet pass.
// (A model rating pass after the bullet pass was scored here against
// the same raw summaries, 3 reps, and removed: F1 0.658 with it vs
// 0.687 without, lower in every rep, +1.0 CPU-s per item.)
// Rubric per the Catch Up spec:
//   noise    precision = bullets matching only in-period signal / bullets
//            matching any fixture item
//   signal   recall = in-period signal items named by some bullet
//   period   leaks = bullets naming an item older than the period
//   mentions deterministic flag recall/precision per period
//   invented bullets whose capitalized names appear nowhere in the chat
//            (prompt-example leakage / hallucination)
// Cost per item = this process's CPU + the inference service's CPU delta
// (`ps` CPU time) + wall time.
import Darwin
import XCTest

@testable import OstMacCore

@MainActor
final class CatchUpHeldOutEvalTests: XCTestCase {
    // MARK: Fixture adapters

    static let ownerAt = #"<at id="0">\#(CatchUpHeldOut.owner)</at>"#
    static let everyoneAt = #"<at id="1">everyone</at>"#

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func message(_ it: CatchUpHeldOut.Item, now: Date) -> ChatMessage {
        var raw: String?
        switch it.mention {
        case "you": raw = it.text.replacingOccurrences(of: "@\(CatchUpHeldOut.owner)", with: ownerAt)
        case "everyone": raw = it.text.replacingOccurrences(of: "@everyone", with: everyoneAt)
        default: raw = nil
        }
        return ChatMessage(id: it.id, sender: it.sender,
                           timestamp: iso.string(from: now.addingTimeInterval(-it.ageHours * 3600)),
                           content: it.text, isOwn: it.own, raw: raw)
    }

    /// Conversations, oldest message first.
    static func threads(now: Date) -> [(chatID: String, chatName: String, messages: [ChatMessage])] {
        CatchUpHeldOut.chats.map { c in
            let msgs = CatchUpHeldOut.items.filter { $0.chatID == c.id }
                .sorted { $0.ageHours > $1.ageHours }.map { message($0, now: now) }
            return (c.id, c.name, msgs)
        }
    }

    static func inPeriod(_ it: CatchUpHeldOut.Item, _ p: CatchUpPeriod) -> Bool { it.ageHours * 3600 <= p.interval }

    static func matches(_ text: String, _ it: CatchUpHeldOut.Item) -> Bool {
        text.range(of: "\\b(\(it.keys))\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Always-on

    /// Each item's keys match its own text and no other item in its chat
    /// (the scorer can attribute a bullet to exactly one source).
    func testHeldOutKeysAreSelfConsistent() {
        var misses: [String] = [], clashes: [String] = []
        for it in CatchUpHeldOut.items {
            // Emoji-only items carry descriptive keys ("thumbs up") that
            // can't match their own text; they still catch paraphrases.
            if it.text.contains(where: \.isLetter), !Self.matches(it.text, it) { misses.append(it.id) }
            for other in CatchUpHeldOut.items where other.chatID == it.chatID && other.id != it.id {
                if Self.matches(other.text, it) { clashes.append("\(it.id)->\(other.id)") }
            }
        }
        XCTAssertEqual(misses, [], "keys that miss their own text")
        XCTAssertEqual(clashes, [], "keys that match another item in the same chat")
        XCTAssertEqual(Set(CatchUpHeldOut.items.map(\.id)).count, CatchUpHeldOut.items.count, "duplicate ids")
    }

    /// Held-out isolation: no sender name or capitalized fixture word
    /// (code names, projects) appears in any prompt the pipeline sends.
    func testNoHeldOutContentInPrompts() {
        let prompts = [
            CatchUpPrompts.final(transcript: ""), CatchUpPrompts.notes(chunk: ""),
            CatchUpPrompts.combine(notes: ""), CatchUpPrompts.update(previous: "", newMessages: ""),
            CatchUp.prompt(transcript: ""),
        ].joined(separator: "\n")
        var names = Set(CatchUpHeldOut.items.map(\.sender) + CatchUpHeldOut.chats.map(\.name))
        for it in CatchUpHeldOut.items {
            for w in Self.capitalizedWords(it.text) where w.count >= 5 { names.insert(w) }
        }
        let common: Set = ["Please", "Thanks", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
                           "Sunday", "Action", "Happy", "Morning", "Anyone", "Great", "Could", "Would", "Should", "Sounds"]
        let checked = names.subtracting(common)
        func scan(_ text: String) -> [String] {
            checked.filter { text.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }.sorted()
        }
        // Not vacuous: real prompt text and many fixture words, and the
        // scan flags a fixture word once it is planted in a prompt.
        XCTAssertGreaterThan(prompts.count, 1500)
        XCTAssertGreaterThan(checked.count, 100)
        if let planted = checked.sorted().first { XCTAssertEqual(scan(prompts + " " + planted), [planted]) }
        XCTAssertEqual(scan(prompts), [], "held-out content inside a prompt")
    }

    static func capitalizedWords(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.first?.isUppercase == true && $0.dropFirst().contains(where: \.isLowercase) }
    }

    // MARK: Scoring

    struct Score {
        var good = 0, bad = 0, leaks = 0, unmatched = 0, invented = 0, bullets = 0
        var hit = Set<String>(), total = 0
        var precision: Double { Double(good) / Double(max(1, good + bad)) }
        var recall: Double { Double(hit.count) / Double(max(1, total)) }
        var f1: Double { precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall) }
        mutating func add(_ o: Score, tag: String) {
            good += o.good; bad += o.bad; leaks += o.leaks; unmatched += o.unmatched
            invented += o.invented; bullets += o.bullets; total += o.total
            hit.formUnion(o.hit.map { "\(tag):\($0)" })
        }
        var line: String {
            String(format: "F1=%.3f P=%.3f R=%.3f good=%d bad=%d leaks=%d unmatched=%d invented=%d bullets=%d signal=%d/%d",
                   f1, precision, recall, good, bad, leaks, unmatched, invented, bullets, hit.count, total)
        }
    }

    static func score(_ s: inout Score, chatID: String, chatText: String, bullets: [String], period: CatchUpPeriod) {
        let items = CatchUpHeldOut.items.filter { $0.chatID == chatID }
        for b in bullets {
            s.bullets += 1
            let unknown = capitalizedWords(b).filter { $0.count >= 4 && !chatText.localizedCaseInsensitiveContains($0) }
            if !unknown.isEmpty { s.invented += 1 }
            let hits = items.filter { matches(b, $0) }
            if hits.isEmpty { s.unmatched += 1; continue }
            if hits.contains(where: { !inPeriod($0, period) }) { s.leaks += 1 }
            if hits.contains(where: { !$0.signal || !inPeriod($0, period) }) { s.bad += 1 } else { s.good += 1 }
            for h in hits where h.signal && inPeriod(h, period) { s.hit.insert(h.id) }
        }
    }

    // MARK: Cost

    private func selfCPU() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    /// CPU seconds of other processes whose name contains "Inference"
    /// (the system model runs out of process).
    private func inferenceCPU() -> Double {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "time=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var total = 0.0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.contains("Inference") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let t = parts.first?.split(separator: ":").compactMap { Double($0) } ?? []
            total += t.count == 3 ? t[0] * 3600 + t[1] * 60 + t[2] : t.count == 2 ? t[0] * 60 + t[1] : 0
        }
        return total
    }

    struct Cost {
        var wall = 0.0, cpu = 0.0, calls = 0
        mutating func add(_ o: Cost) { wall += o.wall; cpu += o.cpu; calls += o.calls }
    }

    private func measure<T>(_ body: () async throws -> T) async rethrows -> (T, Cost) {
        let t0 = Date(), c0 = selfCPU(), i0 = inferenceCPU()
        let v = try await body()
        return (v, Cost(wall: Date().timeIntervalSince(t0), cpu: selfCPU() - c0 + inferenceCPU() - i0))
    }

    private func bullets(_ text: String) -> [String] {
        let p = CatchUpSummaryParser.parse(text)
        return p.points + p.actions
    }

    // MARK: Opt-in eval

    func testHeldOutEval() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["CATCHEVAL"] == "1", "set CATCHEVAL=1")
        try XCTSkipUnless(OnDeviceSummary.liveAvailability() == .available, "on-device model not available")
        let reps = max(1, Int(env["CATCHEVAL_REPS"] ?? "") ?? 2)
        let transport = OnDeviceCatchUpTransport()
        let now = Date()
        let threads = Self.threads(now: now)
        var out: [String] = [], summary: [String] = []

        // Mentions (deterministic; same with or without the rating pass).
        for p in CatchUpPeriod.allCases {
            var expected = Set<String>(), flagged = Set<String>()
            for t in threads {
                for it in CatchUpHeldOut.items where it.chatID == t.chatID && it.mention != nil && !it.own && Self.inPeriod(it, p) {
                    expected.insert(it.id)
                }
                let bounded = CatchUpBound.messages(t.messages, period: p, now: now)
                for m in CatchUpMentions.flag(bounded, chatID: t.chatID, chatName: t.chatName,
                                              ownerMRI: nil, ownerDisplayName: CatchUpHeldOut.owner) {
                    flagged.insert(m.messageID)
                }
            }
            summary.append("MENTIONS \(p.rawValue): expected \(expected.count) flagged \(flagged.count) hit \(expected.intersection(flagged).count) extra \(flagged.subtracting(expected).sorted())")
        }

        var total = Score(), cost = Cost(), items = 0
        for rep in 1 ... reps {
            var repScore = Score()
            for p in CatchUpPeriod.allCases {
                var ps = Score()
                for t in threads {
                    let chatText = ([t.chatName, CatchUpHeldOut.owner] + t.messages.map { "\($0.sender) \($0.content)" }).joined(separator: "\n")
                    let ctx = CatchUpFilterContext(now: now, chatID: t.chatID, ownerDisplayName: CatchUpHeldOut.owner)
                    let input = CatchUpPipeline.prepare(t.messages, period: p, ctx)
                    guard !input.isEmpty else { continue }
                    let plan = OnDeviceCatchUpEngine.plan(messages: input, previous: nil)
                    let counter = RatingCounter(inner: transport)
                    let (raw, cs) = try await measure { try await OnDeviceCatchUpEngine(transport: counter).summarize(messages: input) }
                    let kept = bullets(CatchUpPipeline.refine(raw, ctx))
                    var c = cs; c.calls = counter.count
                    cost.add(c); items += 1
                    Self.score(&ps, chatID: t.chatID, chatText: chatText, bullets: kept, period: p)
                    out.append(String(format: "r%d %@ %@ plan=%@ msgs=%d calls=%d wall=%.1fs cpu=%.2fs",
                                      rep, p.rawValue, t.chatID, "\(plan)", input.count, counter.count, cs.wall, cs.cpu))
                    out.append("  kept: " + kept.joined(separator: " | "))
                }
                for it in CatchUpHeldOut.items where it.signal && Self.inPeriod(it, p) { ps.total += 1 }
                summary.append("r\(rep) \(p.rawValue) \(ps.line)")
                repScore.add(ps, tag: p.rawValue)
            }
            summary.append("r\(rep) ALL \(repScore.line)")
            total.add(repScore, tag: "r\(rep)")
        }
        let n = Double(max(1, items))
        summary.append("TOTAL \(total.line)")
        summary.append(String(format: "COST per item (n=%d): wall %.1fs cpu %.2fs calls %d",
                              items, cost.wall / n, cost.cpu / n, cost.calls))
        summary.append("ENV lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) reps=\(reps)")
        for s in summary { print("CATCHEVAL " + s) }
        if let path = env["CATCHEVAL_OUT"] {
            try (summary + [""] + out).joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
