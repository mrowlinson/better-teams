// CatchUpTabsTests.swift — CATCHTABS lane: period bound (the last-week
// lunch order leak), per-period cache + selected-period-only work,
// backfill, deterministic noise filter on the labeled fixture, rating
// parse/refine, "Not important" feedback, tag mentions.
import XCTest

@testable import OstMacCore

@MainActor
final class CatchUpTabsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z")!

    private func digest(_ t: CatchUpTransport, mode: CatchUpMode = .onClick,
                        defaults: UserDefaults = MemoryDefaults()) -> CatchUpDigestStore {
        let d = CatchUpDigestStore(transport: t, mode: { mode }, conditions: { (false, .nominal) },
                                   observeSystem: false, defaults: defaults)
        d.debounce = .seconds(3600)
        d.fillDelay = .seconds(3600)
        d.ownerDisplayName = { CatchUpFixture.owner }
        let fixed = now
        d.now = { fixed }
        return d
    }

    private func ingestCorpus(_ d: CatchUpDigestStore) {
        for t in CatchUpFixture.threads(now: now) { d.ingest(chatID: t.chatID, chatName: t.chatName, messages: t.messages) }
    }

    // MARK: - The leak: last week's lunch order in the "current" summary

    func testCurrentPeriodNeverReadsLastWeeksLunchOrder() async {
        let t = CatchUpCannedTransport(stub: "SUMMARY: x")
        let d = digest(t)
        ingestCorpus(d)
        XCTAssertEqual(d.period, .day)
        await d.runCycle(userInitiated: true)
        let all = t.prompts.joined(separator: "\n")
        XCTAssertFalse(all.contains("burrito"), "a 6-day-old lunch order must never reach a 24-hour summary")
        XCTAssertFalse(all.contains("Kestrel"), "50-hour-old news is outside 24 hours")
        XCTAssertTrue(all.contains("Atlas release notes"), "in-period signal is read")
        XCTAssertFalse(all.contains("Donuts"), "social noise is filtered before the model")
        // One summary per conversation with in-period signal.
        XCTAssertEqual(Set(d.entries.map(\.chatID)).count, t.prompts.count)
        // Even on the 2-week tab the lunch order stays out (expired social).
        d.select(.twoWeeks)
        await d.runCycle(userInitiated: true)
        XCTAssertFalse(t.prompts.joined(separator: "\n").contains("burrito"))
        XCTAssertFalse(t.prompts.joined(separator: "\n").contains("Zephyr"), "older than two weeks is never held")
    }

    func testIncrementalFoldStopsOnceItsOldestMessageAgesOut() async {
        let t = CatchUpCannedTransport(stub: "SUMMARY: x")
        var clock = now
        let d = digest(t, mode: .onClick)
        d.now = { clock }
        let iso = ISO8601DateFormatter()
        func m(_ id: String, _ hoursAgo: Double, _ text: String) -> ChatMessage {
            ChatMessage(id: id, sender: "Tom Becker", timestamp: iso.string(from: now.addingTimeInterval(-hoursAgo * 3600)),
                        content: text)
        }
        d.ingest(chatID: "c1", chatName: "One", messages: [m("1", 20, "Deploy plan for the Atlas service is ready for review")])
        await d.runCycle(userInitiated: true)
        // 10 hours later a new message lands; message 1 is now 30 hours old.
        clock = now.addingTimeInterval(10 * 3600)
        d.ingest(chatID: "c1", chatName: "One", messages: [m("2", -9, "Staging is blocked on the certificate renewal")])
        await d.runCycle(userInitiated: true)
        XCTAssertEqual(t.prompts.count, 2)
        XCTAssertFalse(t.prompts[1].contains("Current catch-up:"),
                       "the previous summary read a message that left the period: full re-read, no fold")
        XCTAssertFalse(t.prompts[1].contains("Atlas"))
    }

    func testOldHistoryPageDoesNotDirtyTheDigest() {
        let d = digest(CatchUpCannedTransport(stub: "SUMMARY: x"))
        let old = ChatMessage(id: "o", sender: "Tom Becker", timestamp: "2026-09-01T09:00:00Z", content: "Old release plan")
        d.ingest(chatID: "c1", chatName: "One", messages: [old])
        XCTAssertEqual(d.pending, 0, "scrolling back three weeks feeds nothing into Catch Up")
    }

    // MARK: - Tabs: per-period cache, selected period only, persistence

    func testTabsCachePerPeriodAndOnlySelectedPeriodWorks() async {
        let defaults = MemoryDefaults()
        let t = CatchUpCannedTransport(stub: "SUMMARY: x")
        let d = digest(t, mode: .alwaysUpToDate, defaults: defaults)
        ingestCorpus(d)
        await d.runCycle(userInitiated: false)
        XCTAssertEqual(t.prompts.count, 3, "background cycle: selected period, capped at 3")
        XCTAssertTrue(d.filledPeriods == [.day])
        let dayEntries = d.entries
        d.select(.fiveDays)
        XCTAssertTrue(d.entries.isEmpty, "5 days has no cache yet (never shows 24-hour text)")
        XCTAssertGreaterThan(d.pending, 0)
        await d.runCycle(userInitiated: true)
        let afterFive = t.prompts.count
        d.select(.day)
        XCTAssertEqual(d.entries, dayEntries, "switching back paints from cache")
        XCTAssertEqual(t.prompts.count, afterFive, "a cached switch does no model work")
        XCTAssertEqual(defaults.string(forKey: CatchUpPeriod.defaultsKey), "24h")
        d.select(.threeDays)
        d.mentionsCollapsed = true
        let again = digest(t, defaults: defaults)
        XCTAssertEqual(again.period, .threeDays, "selection persists")
        XCTAssertTrue(again.mentionsCollapsed, "collapse persists")
    }

    func testMentionsAreBoundedByPeriodAndIncludeTags() {
        let d = digest(CatchUpCannedTransport(stub: "SUMMARY: x"))
        d.ownerTags = { ["designers"] }
        ingestCorpus(d)
        let tagMsg = ChatMessage(id: "tag1", sender: "Noah Fischer",
                                 timestamp: ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600)),
                                 content: "@Designers please check the new icons", raw: #"<at id="0">Designers</at> please check the new icons"#)
        d.ingest(chatID: "c-design", chatName: "Design Review", messages: [tagMsg])
        XCTAssertEqual(Set(d.mentions.map(\.messageID)), ["l01", "d01", "o01", "o04", "tag1"])
        XCTAssertEqual(d.mentions.first { $0.messageID == "tag1" }?.kind, .tag)
        XCTAssertEqual(d.mentions.first { $0.messageID == "o01" }?.kind, .everyone)
    }

    func testBackfillRunsForLongerPeriodBounded() async {
        let t = CatchUpCannedTransport(stub: "SUMMARY: x")
        let d = digest(t)
        let iso = ISO8601DateFormatter()
        var calls: [(String, Date)] = []
        d.backfill = { id, since in
            await MainActor.run { calls.append((id, since)) }
            return [ChatMessage(id: "older", sender: "Megan Harper",
                                timestamp: iso.string(from: self.now.addingTimeInterval(-9 * 24 * 3600)),
                                content: "Contract for the Orion vendor is signed")]
        }
        d.ingest(chatID: "c1", chatName: "One", messages: [
            ChatMessage(id: "n", sender: "Tom Becker", timestamp: iso.string(from: now.addingTimeInterval(-3600)),
                        content: "Release branch is cut for the Atlas service"),
        ])
        d.select(.twoWeeks)
        await d.runCycle(userInitiated: true)
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(t.prompts.last?.contains("Orion") ?? false, "backfilled history feeds the 2-week summary")
        d.ingest(chatID: "c1", chatName: "One", messages: [
            ChatMessage(id: "n2", sender: "Tom Becker", timestamp: iso.string(from: now), content: "Build for the Atlas service passed"),
        ])
        await d.runCycle(userInitiated: true)
        XCTAssertEqual(calls.count, 1, "history already covered for this period: no second backfill")
    }

    // MARK: - Deterministic filter on the labeled fixture

    func testNoiseFilterOnLabeledFixture() {
        var report: [String] = []
        for p in [CatchUpPeriod.day, .twoWeeks] {
            var keptSignal = 0, keptNoise = 0, signalTotal = 0
            var beforeSignal = 0, beforeTotal = 0
            for thread in CatchUpFixture.threads(now: now) {
                let ctx = CatchUpFilterContext(now: now, chatID: thread.chatID, ownerDisplayName: CatchUpFixture.owner)
                let kept = Set(CatchUpPipeline.prepare(thread.messages, period: p, ctx).map(\.id))
                // Before: the newest 60 per chat, no age bound, no filter.
                for m in thread.messages.suffix(60) {
                    let it = CatchUpFixture.items.first { $0.id == m.id }!
                    beforeTotal += 1
                    if it.signal, CatchUpFixture.inPeriod(it, p) { beforeSignal += 1 }
                }
                for it in CatchUpFixture.items where it.chatID == thread.chatID {
                    let inP = CatchUpFixture.inPeriod(it, p)
                    if it.signal, inP { signalTotal += 1 }
                    guard kept.contains(it.id) else { continue }
                    XCTAssertTrue(inP, "\(it.id) is outside \(p.rawValue)")
                    if it.signal { keptSignal += 1 } else { keptNoise += 1 }
                }
            }
            let precision = Double(keptSignal) / Double(max(1, keptSignal + keptNoise))
            let recall = Double(keptSignal) / Double(max(1, signalTotal))
            let beforeP = Double(beforeSignal) / Double(max(1, beforeTotal))
            report.append(String(format: "%@ before P=%.2f R=1.00 | after P=%.2f R=%.2f (kept %d signal, %d noise of %d signal)",
                                 p.rawValue, beforeP, precision, recall, keptSignal, keptNoise, signalTotal))
            XCTAssertGreaterThanOrEqual(recall, 0.95, p.rawValue)
            XCTAssertGreaterThanOrEqual(precision, 0.9, p.rawValue)
        }
        print("CATCHTABS-FILTER " + report.joined(separator: " || "))
        // The owner's case, directly.
        let lunch = CatchUpFixture.message(CatchUpFixture.items.first { $0.id == "l13" }!, now: now)
        XCTAssertEqual(CatchUpNoise.reason(lunch, now: now), .food)
        let fresh = ChatMessage(id: "q", sender: "Noah Fischer", timestamp: ISO8601DateFormatter().string(from: now.addingTimeInterval(-600)),
                                content: "Anyone around for a quick call?")
        XCTAssertNil(CatchUpNoise.reason(fresh, now: now), "a 10-minute-old immediacy ask is still live")
        XCTAssertEqual(CatchUpNoise.reason(text: "Agreed, ship Friday"), nil, "a short decision is not an acknowledgment")
    }

    func testSalienceRanksWithinBudget() {
        let iso = ISO8601DateFormatter()
        let chatter = (0 ..< 30).map { i in
            ChatMessage(id: "c\(i)", sender: "Tom Becker", timestamp: iso.string(from: now.addingTimeInterval(Double(-7200 + i))),
                        content: "notes on the layout work item \(i)")
        }
        let ask = ChatMessage(id: "ask", sender: "Megan Harper", timestamp: iso.string(from: now.addingTimeInterval(-7300)),
                              content: "Can you approve the budget by Friday?")
        let kept = CatchUpPipeline.prepare([ask] + chatter, period: .day, CatchUpFilterContext(now: now), budget: 60)
        XCTAssertTrue(kept.contains { $0.id == "ask" }, "the oldest message survives the budget when it matters most")
        XCTAssertLessThan(kept.count, 31)
    }

    // MARK: - Bullet pass

    func testBulletPassDropsSocialBulletsOnly() {
        let text = """
            SUMMARY: The launch is on track.
            POINTS:
            - Megan needs your sign-off on the release notes.
            - Chloe is taking lunch orders for the offsite.
            - Tom moved the review to Wednesday.
            - Liam shared a minor typo fix.
            ACTIONS:
            - You: sign off on the release notes.
            """
        let parsed = CatchUpSummaryParser.parse(CatchUpPipeline.refine(text, CatchUpFilterContext(now: now)))
        XCTAssertEqual(parsed.points, ["Megan needs your sign-off on the release notes.",
                                       "Tom moved the review to Wednesday.", "Liam shared a minor typo fix."])
        XCTAssertEqual(parsed.actions, ["You: sign off on the release notes."])
        XCTAssertEqual(CatchUpSummaryParser.parse("POINTS:\n- - Doubled glyph").points, ["Doubled glyph"])
    }

    // MARK: - Not important

    func testNotImportantHidesAndDownWeightsAndResets() {
        let defaults = MemoryDefaults()
        let store = CatchUpFeedbackStore(defaults: defaults)
        store.dismiss("Weekly metrics dashboard refreshed for marketing", chatID: "c1")
        XCTAssertTrue(store.isHidden("weekly metrics dashboard refreshed for marketing.", chatID: "c1"))
        XCTAssertFalse(store.isHidden("weekly metrics dashboard refreshed for marketing", chatID: "c2"))
        let similar = ChatMessage(id: "m", sender: "Tom Becker", timestamp: "2026-09-28T11:00:00Z",
                                  content: "Metrics dashboard refreshed for the marketing team")
        let ctx = CatchUpFilterContext(now: now, chatID: "c1", feedback: store.value)
        XCTAssertLessThan(CatchUpNoise.salience(similar, ctx), 1, "similar items drop out of the model input")
        XCTAssertEqual(CatchUpFeedbackStore(defaults: defaults).count, 1, "stored locally")
        store.reset()
        XCTAssertEqual(CatchUpFeedbackStore(defaults: defaults).count, 0)
    }

    // MARK: - Tags (read-only Graph, fixtures)

    func testTagMembershipReadAndParse() {
        let routes: [String: String] = [
            "/me/joinedTeams?$select=id": #"{"value":[{"id":"t1"},{"id":"t2"}]}"#,
            "/teams/t1/tags": #"{"value":[{"id":"g1","displayName":"Designers"},{"id":"g2","displayName":"On-Call"}]}"#,
            "/teams/t1/tags/g1/members": #"{"value":[{"id":"m1","userId":"ABC-123","displayName":"Jordan Fox"}]}"#,
            "/teams/t1/tags/g2/members": #"{"value":[{"id":"m2","userId":"zzz","displayName":"Noah Fischer"}]}"#,
            "/teams/t2/tags": #"{"error":{"code":"Forbidden"}}"#,
        ]
        var paths: [String] = []
        let names = CatchUpTags.ownerTagNames(userID: "abc-123") { path in
            paths.append(path)
            guard let body = routes[path] else { throw CoreCallError.failed("unstubbed") }
            return Data(body.utf8)
        }
        XCTAssertEqual(names, ["designers"])
        XCTAssertTrue(paths.allSatisfy { $0.hasPrefix("/me/joinedTeams") || $0.hasPrefix("/teams/") }, "GET reads only")
        XCTAssertNil(CatchUpTags.ownerTagNames(userID: "abc-123") { _ in throw CoreCallError.failed("offline") })
        XCTAssertEqual(CatchUpTags.userID(fromMRI: "8:orgid:abc-123"), "abc-123")
        let defaults = MemoryDefaults()
        CatchUpTags.store(["designers"], userID: "abc-123", defaults: defaults, now: now)
        XCTAssertEqual(CatchUpTags.cached(userID: "abc-123", defaults: defaults, now: now.addingTimeInterval(3600)), ["designers"])
        XCTAssertNil(CatchUpTags.cached(userID: "abc-123", defaults: defaults, now: now.addingTimeInterval(2 * 86400)))
        let person = Mention(id: "0", mri: "8:orgid:x", mentionType: "person", displayName: "Designers")
        XCTAssertFalse(CatchUpTags.mentionsTag([person], ownerTags: ["designers"]), "a person named like a tag is not a tag")
        XCTAssertTrue(CatchUpTags.mentionsTag([Mention(id: "0", mri: nil, mentionType: "tag", displayName: "@Designers")],
                                              ownerTags: ["designers"]))
    }
}
