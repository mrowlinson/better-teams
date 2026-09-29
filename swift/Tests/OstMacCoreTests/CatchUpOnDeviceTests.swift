// CatchUpOnDeviceTests.swift — AICATCH lane: deterministic mention flags,
// 4096-token chunking, plain-text parsing, incremental digest, mode gate.
import XCTest

@testable import OstMacCore

@MainActor
final class CatchUpOnDeviceTests: XCTestCase {
    private func msg(_ id: String, _ sender: String = "Ava Stone", raw: String? = nil,
                     content: String = "status update on the release", ts: String? = nil, own: Bool = false) -> ChatMessage {
        ChatMessage(id: id, sender: sender, timestamp: ts ?? "2026-09-28T09:00:\(id.suffix(2))Z",
                    content: content, isOwn: own, raw: raw)
    }

    // MARK: - Mentions

    func testMentionKinds() {
        let owner = "Jordan Fox"
        let you = msg("01", raw: #"<p>Can <at id="8:me">@Jordan Fox</at> review?</p>"#)
        let everyone = msg("02", raw: #"<p><at id="0">Everyone</at> standup moved</p>"#)
        let channel = msg("03", raw: #"<p><at id="1">channel</at> heads up</p>"#)
        let team = msg("04", raw: #"<p><span itemtype="http://schema.skype.com/Mention" itemid="0">Team</span> ship it</p>"#)
        let other = msg("05", raw: #"<p><at id="8:t">@Tom Becker</at> thanks</p>"#)
        let plain = msg("06", raw: "<p>@Jordan Fox typed by hand, no entity</p>")
        let noRaw = msg("07", content: "Jordan Fox please look")
        let own = msg("08", "Jordan Fox", raw: #"<p><at id="0">Everyone</at> from me</p>"#)
        let k = { (m: ChatMessage) in CatchUpMentions.kind(of: m, ownerMRI: nil, ownerDisplayName: owner) }
        XCTAssertEqual(k(you), .you)
        XCTAssertEqual(k(everyone), .everyone)
        XCTAssertEqual(k(channel), .everyone)
        XCTAssertEqual(k(team), .everyone)
        XCTAssertNil(k(other))
        XCTAssertNil(k(plain), "text without a mention entity never flags")
        XCTAssertNil(k(noRaw))
        XCTAssertNil(k(own), "own messages never flag")
        // MRI identity wins over the name.
        let byMRI = msg("09", raw: #"<p><at id="8:orgid:abc">@Someone Else</at></p>"#)
        XCTAssertNil(CatchUpMentions.kind(of: byMRI, ownerMRI: "8:orgid:abc", ownerDisplayName: owner),
                     "content-mined <at> carries no MRI; name decides")
        let flagged = CatchUpMentions.flag([you, other, everyone], chatID: "c", chatName: "Chat",
                                           ownerMRI: nil, ownerDisplayName: owner)
        XCTAssertEqual(flagged.map(\.messageID), ["01", "02"])
    }

    // MARK: - Chunker

    func testChunksStayWithinBudgetAndKeepNewest() {
        let lines = (0 ..< 400).map { "Person \($0 % 5): " + String(repeating: "word ", count: 30) + "#\($0)" }
        let chunks = CatchUpChunker.chunks(lines)
        XCTAssertEqual(chunks.count, CatchUpChunker.maxChunks)
        for c in chunks {
            XCTAssertLessThanOrEqual(CatchUpChunker.estimateTokens(c), CatchUpChunker.inputBudget)
        }
        XCTAssertTrue(chunks.last!.hasSuffix("#399"), "newest message is always read")
        XCTAssertFalse(chunks.joined().contains("#0\n"), "head drops first")
        // One giant line is truncated to fit, never overflows.
        let giant = CatchUpChunker.chunks([String(repeating: "x", count: 50_000)])
        XCTAssertEqual(giant.count, 1)
        XCTAssertLessThanOrEqual(CatchUpChunker.estimateTokens(giant[0]), CatchUpChunker.inputBudget)
        // Prompt + budgeted input + response stays inside the window.
        let prompt = CatchUpPrompts.final(transcript: chunks[0])
        XCTAssertLessThan(CatchUpChunker.estimateTokens(prompt) + CatchUpChunker.finalResponseTokens,
                          CatchUpChunker.contextTokens)
    }

    func testPromptsCarryNoExampleContent() {
        let p = CatchUpPrompts.final(transcript: "")
        for bad in ["Thursday", "Ava", "onboarding", "e.g.", "for example", "Example"] {
            XCTAssertFalse(p.contains(bad), bad)
        }
    }

    // MARK: - Parser

    func testParserReadsLayoutAndVariants() {
        let a = CatchUpSummaryParser.parse("""
            SUMMARY: The release is on track.
            POINTS:
            - Tests pass
            - Docs pending
            ACTIONS:
            - None
            """)
        XCTAssertEqual(a, ParsedCatchUp(summary: "The release is on track.", points: ["Tests pass", "Docs pending"], actions: []))
        let b = CatchUpSummaryParser.parse("""
            **1. TL;DR** — Budget approved.
            ## Key points
            • Vendor chosen
            3. Action items:
            1. Sam sends the contract
            """)
        XCTAssertEqual(b.summary, "Budget approved.")
        XCTAssertEqual(b.points, ["Vendor chosen"])
        XCTAssertEqual(b.actions, ["Sam sends the contract"])
        let c = CatchUpSummaryParser.parse("Summary of the week was quiet.\n- one\n- two")
        XCTAssertEqual(c.summary, "Summary of the week was quiet.", "prose that starts with a key is not a header")
        XCTAssertEqual(c.points, ["one", "two"])
    }

    // MARK: - Engine

    func testEngineSingleVsMapReduceCallCounts() async throws {
        let t = CatchUpCannedTransport(stub: "SUMMARY: ok")
        let engine = OnDeviceCatchUpEngine(transport: t)
        let short = (10 ..< 20).map { msg("\($0)") }
        _ = try await engine.summarize(messages: short)
        XCTAssertEqual(t.prompts.count, 1)
        let long = (10 ..< 99).map { msg("\($0)", content: String(repeating: "status update ", count: 40)) }
        guard case let .mapReduce(n) = OnDeviceCatchUpEngine.plan(messages: long, previous: nil) else {
            return XCTFail("long thread must chunk")
        }
        _ = try await engine.summarize(messages: long)
        XCTAssertEqual(t.prompts.count, 1 + n + 1, "one notes call per chunk + one combine")
        // Incremental: previous summary + only the new tail.
        let prev = OnDeviceCatchUpEngine.Previous(text: "SUMMARY: earlier", afterMessageID: "97")
        XCTAssertEqual(OnDeviceCatchUpEngine.plan(messages: long, previous: prev), .incremental)
        _ = try await engine.summarize(messages: long, previous: prev)
        XCTAssertTrue(t.prompts.last!.contains("SUMMARY: earlier"))
        XCTAssertEqual(t.prompts.last!.components(separatedBy: "\nAva Stone: ").count - 1, 1,
                       "only message 98 is re-read")
    }

    // MARK: - Digest

    private func digest(_ t: CatchUpTransport, mode: @escaping () -> CatchUpMode,
                        lowPower: Bool = false) -> CatchUpDigestStore {
        let d = CatchUpDigestStore(transport: t, mode: mode, conditions: { (lowPower, .nominal) }, observeSystem: false,
                                   defaults: MemoryDefaults())
        d.debounce = .seconds(3600)
        d.ownerDisplayName = { "Jordan Fox" }
        // CATCHTABS: messages are period-bounded; pin the clock.
        d.now = { ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z")! }
        return d
    }

    func testDigestOffDoesNoWork() async {
        let t = CatchUpCannedTransport(stub: "SUMMARY: x")
        let d = digest(t, mode: { .off })
        d.ingest(chatID: "c1", chatName: "One", messages: [msg("01", raw: #"<at id="0">Everyone</at>"#)])
        await d.runCycle(userInitiated: false)
        d.updateNow()
        XCTAssertTrue(t.prompts.isEmpty)
        XCTAssertTrue(d.mentions.isEmpty)
        XCTAssertEqual(d.pending, 0)
    }

    func testDigestSkipsUnchangedAndFlagsMentions() async {
        let t = CatchUpCannedTransport(stub: "SUMMARY: x")
        let d = digest(t, mode: { .alwaysUpToDate })
        let a = [msg("01"), msg("02", raw: #"<at id="8:me">@Jordan Fox</at> ping"#)]
        d.ingest(chatID: "c1", chatName: "One", messages: a)
        d.ingest(chatID: "c2", chatName: "Two", messages: [msg("03")])
        XCTAssertEqual(d.mentions.map(\.messageID), ["02"], "mentions flag on arrival, before any model work")
        XCTAssertEqual(d.pending, 2)
        await d.runCycle(userInitiated: false)
        XCTAssertEqual(t.prompts.count, 2)
        XCTAssertEqual(d.pending, 0)
        // Same messages again: unchanged → no model work.
        d.ingest(chatID: "c1", chatName: "One", messages: a)
        await d.runCycle(userInitiated: false)
        XCTAssertEqual(t.prompts.count, 2)
        // One new message in c2 only → one incremental call for c2.
        d.ingest(chatID: "c2", chatName: "Two", messages: [msg("04")])
        await d.runCycle(userInitiated: false)
        XCTAssertEqual(t.prompts.count, 3)
        XCTAssertTrue(t.prompts[2].contains("Current catch-up:"))
        XCTAssertEqual(Set(d.entries.map(\.chatID)), ["c1", "c2"])
    }

    func testDigestPausesInLowPowerAndOnClickWaitsForUser() async {
        let t = CatchUpCannedTransport(stub: "SUMMARY: x")
        let d = digest(t, mode: { .alwaysUpToDate }, lowPower: true)
        d.ingest(chatID: "c1", chatName: "One", messages: [msg("01")])
        await d.runCycle(userInitiated: false)
        XCTAssertTrue(t.prompts.isEmpty)
        XCTAssertEqual(d.paused, .lowPower)
        let t2 = CatchUpCannedTransport(stub: "SUMMARY: x")
        let click = digest(t2, mode: { .onClick })
        click.ingest(chatID: "c1", chatName: "One", messages: [msg("01")])
        await click.runCycle(userInitiated: false)
        XCTAssertTrue(t2.prompts.isEmpty, "on-click never summarizes in the background")
        await click.runCycle(userInitiated: true)
        XCTAssertEqual(t2.prompts.count, 1)
    }

    // MARK: - Settings mode + deprecation gate

    func testModeMigratesAndLegacyProviderNeedsHiddenKey() {
        let suite = "test-aicatch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "catchup.enabled")
        defaults.set("opencode-cli", forKey: "catchup.provider")
        let a = CatchUpStore(defaults: defaults, keyStore: CatchUpMemoryKeyStore())
        XCTAssertEqual(a.mode, .onClick, "pre-mode 'enabled' reads as on-click")
        XCTAssertEqual(a.config.provider, .onDevice, "legacy provider ignored without the hidden key")
        XCTAssertFalse(a.deprecatedProvidersEnabled)
        a.mode = .alwaysUpToDate
        defaults.set(true, forKey: CatchUp.deprecatedProvidersKey)
        let b = CatchUpStore(defaults: defaults, keyStore: CatchUpMemoryKeyStore())
        XCTAssertEqual(b.mode, .alwaysUpToDate)
        XCTAssertTrue(b.deprecatedProvidersEnabled)
        XCTAssertEqual(b.config.provider, .onDevice, "a.save wrote on-device")
    }
}
