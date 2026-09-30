// ActionItemsTests.swift — f1-actions lane: on-device meeting action
// items over transcripts (cues) + chat threads (messages). Pure
// builders, lenient bullet parse, memory-only cache, on-device-only
// routing, empty/error behavior. Failing-first: written before the
// extractor.
import XCTest

@testable import OstMacCore

@MainActor
final class ActionItemsTests: XCTestCase {
    // MARK: - Fixtures

    private func cues() -> [TranscriptCue] {
        [
            TranscriptCue(
                id: 0, speaker: "Ava Lindqvist", startMs: 43_000,
                endMs: 48_000, text: "Megan, can you ship the picker by Friday?"),
            TranscriptCue(
                id: 1, speaker: "Megan Harper", startMs: 49_000,
                endMs: 55_000, text: "On it.\nI will also update the docs."),
            TranscriptCue(
                id: 2, speaker: nil, startMs: 3_723_000,
                endMs: 3_730_000, text: "Tom owns the login fix."),
        ]
    }

    private func thread() -> [ChatMessage] {
        [
            ChatMessage(
                id: "m1", sender: "Ava Lindqvist", timestamp: "t",
                content: "Megan, can you ship the picker by Friday?"),
            ChatMessage(
                id: "m2", sender: "Megan Harper", timestamp: "t",
                content: "On it\nsecond line"),
        ]
    }

    private func store(
        stub: String = "- Ship the picker — Megan Harper [0:43]",
        availability: OnDeviceAvailability = .available,
        failure: Error? = nil
    ) -> (ActionItemsStore, OnDeviceMockRunner) {
        let runner = OnDeviceMockRunner(stub: stub, failure: failure)
        let transport = OnDeviceCatchUpTransport(
            runner: runner, availability: { availability })
        return (ActionItemsStore(transport: transport), runner)
    }

    private func waitFor(
        _ cond: @escaping @MainActor () -> Bool,
        timeout: TimeInterval = 5
    ) async -> Bool {
        // `timeout` is ignored: wait on the condition, ceiling only bounds a hang.
        await TestWait.until(interval: 0.02) { cond() }
    }

    // MARK: - Cue transcript builder

    func testCueTranscriptFormat() {
        let t = ActionItems.transcript(from: cues())
        XCTAssertFalse(t.truncated)
        let lines = t.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(
            lines[0],
            "Ava Lindqvist [0:43]: Megan, can you ship the picker by Friday?")
        // Multi-line cue payloads join onto one line.
        XCTAssertEqual(
            lines[1], "Megan Harper [0:49]: On it. I will also update the docs.")
        // Missing speaker + hour-long label.
        XCTAssertEqual(lines[2], "Unknown [1:02:03]: Tom owns the login fix.")
    }

    func testCueTranscriptTailCap() {
        let long = (0 ..< 400).map {
            TranscriptCue(
                id: $0, speaker: "Sam Ray", startMs: $0 * 1000,
                endMs: $0 * 1000 + 500,
                text: String(repeating: "word ", count: 20))
        }
        let t = ActionItems.transcript(from: long)
        XCTAssertTrue(t.truncated)
        XCTAssertLessThanOrEqual(t.text.count, CatchUp.maxTranscriptChars)
        // Cut lands on a line boundary: the first line is whole.
        XCTAssertTrue(t.text.hasPrefix("Sam Ray ["))
        // Small inputs stay whole and unflagged.
        let small = ActionItems.transcript(from: [cues()[0]])
        XCTAssertFalse(small.truncated)
        XCTAssertTrue(small.text.contains("Ava Lindqvist"))
    }

    func testMessagesTranscriptReusesCatchUp() {
        let via = ActionItems.transcript(from: thread())
        XCTAssertEqual(via.text, CatchUp.transcript(from: thread()))
        XCTAssertFalse(via.truncated)
    }

    // MARK: - Prompt

    func testPromptShape() {
        let t = ActionItems.transcript(from: cues())
        let p = ActionItems.prompt(transcript: t)
        // Owner + timestamp instructions are pinned by keyword.
        XCTAssertTrue(p.lowercased().contains("owner"))
        XCTAssertTrue(p.contains("[m:ss]"))
        XCTAssertTrue(p.contains(t.text))
        // Untruncated transcripts carry no scope note.
        XCTAssertFalse(p.contains("omitted"))
        // Truncated transcripts name the fragment scope.
        let long = ActionItems.transcript(from: (0 ..< 400).map {
            TranscriptCue(
                id: $0, speaker: "Sam Ray", startMs: $0 * 1000,
                endMs: $0 * 1000 + 500,
                text: String(repeating: "word ", count: 20))
        })
        XCTAssertTrue(ActionItems.prompt(transcript: long).contains("omitted"))
    }

    // MARK: - Bullet parse

    func testParseFullBullets() {
        let items = ActionItems.parse("""
        - Ship the picker — Megan Harper [0:43]
        - Fix the login bug - Tom Becker [1:02:03]
        """)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "Ship the picker")
        XCTAssertEqual(items[0].owner, "Megan Harper")
        XCTAssertEqual(items[0].sourceLabel, "0:43")
        XCTAssertEqual(items[1].title, "Fix the login bug")
        XCTAssertEqual(items[1].owner, "Tom Becker")
        XCTAssertEqual(items[1].sourceLabel, "1:02:03")
    }

    func testParseLenientShapes() {
        let items = ActionItems.parse("""
        * Update the docs (Ava Lindqvist)
        1. Review the plan (0:49)
        - Just do the thing
        """)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].owner, "Ava Lindqvist")
        XCTAssertNil(items[0].sourceLabel)
        XCTAssertEqual(items[1].owner, "Unassigned")
        XCTAssertEqual(items[1].sourceLabel, "0:49")
        XCTAssertEqual(items[2].title, "Just do the thing")
        XCTAssertEqual(items[2].owner, "Unassigned")
        XCTAssertNil(items[2].sourceLabel)
    }

    func testParseKeepsMalformedLines() {
        // No bullet marker, no owner, no timestamp: still a bullet,
        // never dropped.
        let items = ActionItems.parse("some freeform line\n\n- real bullet")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "some freeform line")
        XCTAssertEqual(items[0].owner, "Unassigned")
        XCTAssertEqual(items[1].title, "real bullet")
    }

    func testParseNonePhrasingYieldsEmpty() {
        XCTAssertTrue(ActionItems.parse("No action items found.").isEmpty)
        XCTAssertTrue(ActionItems.parse("").isEmpty)
        XCTAssertTrue(ActionItems.parse("   \n  ").isEmpty)
    }

    // MARK: - Cache

    func testCacheHitMissInvalidate() {
        var cache = ActionItemsCache()
        let a = cues()
        var edited = a
        edited[1] = TranscriptCue(
            id: 1, speaker: "Megan Harper", startMs: 49_000,
            endMs: 55_000, text: "changed")
        let key = ActionItemsCache.key(sourceID: "tr-1", cues: a)
        let items = [ActionItem(title: "x", owner: "Megan Harper", sourceLabel: nil)]
        XCTAssertNil(cache.lookup(key))
        cache.store(key, items: items)
        XCTAssertEqual(cache.lookup(key), items)
        // Edited cues invalidate.
        XCTAssertNil(cache.lookup(ActionItemsCache.key(sourceID: "tr-1", cues: edited)))
        // Source switch misses (effective reset, no explicit clear).
        XCTAssertNil(cache.lookup(ActionItemsCache.key(sourceID: "tr-2", cues: a)))
    }

    func testCacheMessagesKey() {
        var cache = ActionItemsCache()
        let m = thread()
        let key = ActionItemsCache.key(sourceID: "chat-a", messages: m)
        let items = [ActionItem(title: "x", owner: "Megan Harper", sourceLabel: nil)]
        cache.store(key, items: items)
        XCTAssertEqual(cache.lookup(key), items)
        var grown = m
        grown.append(ChatMessage(
            id: "m3", sender: "Tom Becker", timestamp: "t", content: "new"))
        XCTAssertNil(cache.lookup(ActionItemsCache.key(sourceID: "chat-a", messages: grown)))
    }

    // MARK: - Store: extract + cache + routing

    func testExtractCuesLoadsParsed() async {
        let (s, runner) = store(stub: """
        - Ship the picker — Megan Harper [0:43]
        - Update the docs — Unassigned [0:49]
        """)
        await s.extractFromCues(cues(), transcriptID: "tr-1")
        XCTAssertEqual(runner.calls.count, 1)
        // The prompt carries the cue transcript.
        XCTAssertTrue(runner.calls[0].contains("Ava Lindqvist [0:43]"))
        guard case let .loaded(items) = s.state else {
            return XCTFail("expected loaded, got \(s.state)")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].owner, "Megan Harper")
        XCTAssertEqual(items[0].sourceLabel, "0:43")
        XCTAssertNil(s.lastError)
    }

    func testExtractMessagesLoadsParsed() async {
        let (s, runner) = store(stub: "- Ship the picker — Megan Harper")
        await s.extractFromMessages(thread(), chatID: "chat-a")
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertTrue(runner.calls[0].contains("Ava Lindqvist: Megan, can you ship"))
        guard case let .loaded(items) = s.state else {
            return XCTFail("expected loaded, got \(s.state)")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Ship the picker")
    }

    func testExtractCachesUnchangedSource() async {
        let (s, runner) = store()
        await s.extractFromCues(cues(), transcriptID: "tr-1")
        await s.extractFromCues(cues(), transcriptID: "tr-1")
        XCTAssertEqual(runner.calls.count, 1, "re-tap replays the cache")
        var grown = cues()
        grown.append(TranscriptCue(
            id: 3, speaker: "Tom Becker", startMs: 60_000,
            endMs: 61_000, text: "one more turn"))
        await s.extractFromCues(grown, transcriptID: "tr-1")
        XCTAssertEqual(runner.calls.count, 2, "new cues invalidate")
        await s.extractFromCues(cues(), transcriptID: "tr-2")
        XCTAssertEqual(runner.calls.count, 3, "source switch misses")
    }

    func testEmptySourceShortCircuits() async {
        let (s, runner) = store()
        await s.extractFromCues([], transcriptID: "tr-1")
        XCTAssertTrue(runner.calls.isEmpty, "no model call on empty input")
        XCTAssertEqual(s.state, .empty(ActionItems.emptySourceCopy))
        await s.extractFromMessages([], chatID: "chat-a")
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertEqual(s.state, .empty(ActionItems.emptySourceCopy))
        XCTAssertEqual(ActionItems.emptySourceCopy, "Nothing to extract from.")
    }

    func testNoItemsFoundEmptyState() async {
        let (s, runner) = store(stub: "No action items found.")
        await s.extractFromCues(cues(), transcriptID: "tr-1")
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(s.state, .empty(ActionItems.noItemsCopy))
        XCTAssertEqual(ActionItems.noItemsCopy, "No action items found.")
        // Cached like a hit: re-tap spends no new session.
        await s.extractFromCues(cues(), transcriptID: "tr-1")
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testDefaultTransportIsOnDevice() {
        XCTAssertTrue(ActionItemsStore().transport is OnDeviceCatchUpTransport)
    }

    func testOnDeviceGatePassthrough() async {
        for status: OnDeviceAvailability in
            [.unsupportedOS, .unsupportedDevice, .disabled, .downloading]
        {
            let (s, runner) = store(availability: status)
            await s.extractFromCues(cues(), transcriptID: "tr-1")
            XCTAssertTrue(runner.calls.isEmpty, "\(status): no model session")
            let expected = OnDeviceSummary.error(for: status)!
            XCTAssertEqual(s.lastError, expected, "\(status)")
            XCTAssertEqual(s.state, .failed(expected.message), "\(status)")
            XCTAssertTrue(expected.isOnDevice)
        }
    }

    func testRunnerFailureMapsToOnDeviceFailed() async {
        struct Boom: Error {}
        let (s, _) = store(stub: "", failure: Boom())
        await s.extractFromMessages(thread(), chatID: "chat-a")
        guard case let .failed(detail) = s.state else {
            return XCTFail("expected failed, got \(s.state)")
        }
        XCTAssertTrue(detail.contains("On-device"))
        XCTAssertEqual(
            s.lastError, .onDeviceFailed(String(describing: Boom())))
    }

    func testResetReturnsToIdle() async {
        let (s, _) = store()
        await s.extractFromCues(cues(), transcriptID: "tr-1")
        s.reset()
        XCTAssertEqual(s.state, .idle)
        XCTAssertNil(s.lastError)
    }

    // MARK: - TranscriptsViewModel wiring

    private func vm(
        runner: OnDeviceMockRunner,
        availability: OnDeviceAvailability = .available
    ) -> TranscriptsViewModel {
        TranscriptsViewModel(
            listFetcher: {
                TranscriptsResponse(ok: true, transcripts: [
                    TranscriptItem(id: "a", name: "a.vtt", drive_id: "d"),
                    TranscriptItem(id: "b", name: "b.vtt", drive_id: "d"),
                ])
            },
            downloadFetcher: { _, _, dest in
                try TranscriptsDemo.sampleVTT.write(
                    toFile: dest, atomically: true, encoding: .utf8)
                return dest
            },
            actionItemsTransport: OnDeviceCatchUpTransport(
                runner: runner, availability: { availability }))
    }

    func testVMExtractLoadsAndCaches() async throws {
        let runner = OnDeviceMockRunner(
            stub: "- Ship the picker — Megan Harper [0:43]")
        let m = vm(runner: runner)
        await m.load()
        m.select(m.items[0])
        let landed = await waitFor { m.content == .loaded }
        XCTAssertTrue(landed)
        await m.extractActionItems()
        guard case let .loaded(items) = m.actionItems.state else {
            return XCTFail("expected loaded, got \(m.actionItems.state)")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].owner, "Megan Harper")
        await m.extractActionItems()
        XCTAssertEqual(runner.calls.count, 1, "re-tap replays the cache")
    }

    func testVMExtractResetsOnSwitchAndClose() async throws {
        let runner = OnDeviceMockRunner(stub: "- Ship the picker — Megan Harper")
        let m = vm(runner: runner)
        await m.load()
        m.select(m.items[0])
        let landed = await waitFor { m.content == .loaded }
        XCTAssertTrue(landed)
        await m.extractActionItems()
        guard case .loaded = m.actionItems.state else {
            return XCTFail("expected loaded, got \(m.actionItems.state)")
        }
        m.select(m.items[1])
        XCTAssertEqual(m.actionItems.state, .idle, "source switch resets")
        let relanded = await waitFor { m.content == .loaded }
        XCTAssertTrue(relanded)
        m.closeTranscript()
        XCTAssertEqual(m.actionItems.state, .idle, "close resets")
    }

    func testVMExtractWithoutCuesShortCircuits() async throws {
        let runner = OnDeviceMockRunner(stub: "- Ship the picker — Megan Harper")
        let m = vm(runner: runner)
        await m.extractActionItems()
        XCTAssertTrue(runner.calls.isEmpty, "no selection spends no session")
        XCTAssertEqual(
            m.actionItems.state, .empty(ActionItems.emptySourceCopy))
    }
}
