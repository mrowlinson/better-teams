// LocalSearchTests.swift — d2-archive lane: offline index/query/persist.
import XCTest

@testable import OstMacCore

@MainActor
final class LocalSearchTests: XCTestCase {
    static func msg(_ id: String, _ sender: String, _ ts: String, _ content: String) -> ChatMessage {
        ChatMessage(id: id, sender: sender, timestamp: ts, content: content)
    }

    static func seedMessages() -> [ChatMessage] {
        [
            msg("1001", "Megan Harper", "2026-09-20T09:12:00Z",
                "Shipping the release candidate on Friday morning"),
            msg("1002", "Tom Becker", "2026-09-20T09:13:00Z",
                "Can someone approve the pull request for shipping"),
            msg("1003", "Paige Sutton", "2026-09-21T10:00:00Z",
                "The quarterly planning document needs signatures"),
            msg("1004", "Sam Whitfield", "2026-09-22T11:30:00Z",
                "Shipping lane delays may push the Friday deploy"),
            msg("1005", "Elena Novak", "2026-09-22T12:00:00Z",
                "Reminder that expense reports are due this Friday"),
        ]
    }

    func tmpURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("d2-\(name)-\(UInt32.random(in: 0 ... .max)).omix")
    }

    // MARK: - Basics

    func testEmptyIndex() async {
        let store = LocalSearchStore()
        XCTAssertEqual(store.docCount, 0)
        await store.search(query: "ship")
        XCTAssertTrue(store.hits.isEmpty)
        XCTAssertEqual(store.total, 0)
        XCTAssertFalse(store.more)
        XCTAssertNil(store.nextFrom)
    }

    func testBlankQueryClears() async {
        let store = LocalSearchStore()
        store.index(chatID: "c1", messages: Self.seedMessages())
        await store.search(query: "ship")
        XCTAssertFalse(store.hits.isEmpty)
        await store.search(query: "   ")
        XCTAssertTrue(store.hits.isEmpty)
        XCTAssertNil(store.total)
        XCTAssertEqual(store.lastQuery, "")
    }

    // MARK: - Matching

    func testPrefixMatch() async {
        let store = LocalSearchStore()
        store.index(chatID: "c1", messages: Self.seedMessages())
        await store.search(query: "ship") // prefix of "shipping" + exact "ship"? none exact
        let ids = Set(store.hits.map(\.messageID))
        XCTAssertEqual(ids, ["1001", "1002", "1004"])
        XCTAssertEqual(store.total, 3)
    }

    func testMultiTermAND() async {
        let store = LocalSearchStore()
        store.index(chatID: "c1", messages: Self.seedMessages())
        await store.search(query: "shipping friday")
        let ids = Set(store.hits.map(\.messageID))
        XCTAssertEqual(ids, ["1001", "1004"]) // both terms present
        await store.search(query: "shipping signatures")
        XCTAssertTrue(store.hits.isEmpty) // no doc has both
        XCTAssertEqual(store.total, 0)
    }

    func testSenderMatches() async {
        let store = LocalSearchStore()
        store.index(chatID: "c1", messages: Self.seedMessages())
        await store.search(query: "paige")
        XCTAssertEqual(store.hits.map(\.messageID), ["1003"])
    }

    func testRankingExactBeatsPrefix() async {
        let store = LocalSearchStore()
        store.index(chatID: "c1", messages: [
            Self.msg("2001", "Marcus Reed", "2026-09-20T08:00:00Z", "the shipping manifest arrived"),
            Self.msg("2002", "Hannah Calloway", "2026-09-19T08:00:00Z", "we will ship it today"),
        ])
        await store.search(query: "ship")
        // 2002 has the exact token "ship"; 2001 only the prefix "shipping".
        XCTAssertEqual(store.hits.map(\.messageID), ["2002", "2001"])
    }

    func testRankingNewestFirstOnTie() async {
        let store = LocalSearchStore()
        store.index(chatID: "c1", messages: [
            Self.msg("3001", "David Bennett", "2026-09-18T08:00:00Z", "deploy friday"),
            Self.msg("3002", "Laura Sloan", "2026-09-22T08:00:00Z", "deploy friday"),
        ])
        await store.search(query: "deploy")
        XCTAssertEqual(store.hits.map(\.messageID), ["3002", "3001"])
    }

    // MARK: - Paging (MessageSearchStore shape)

    func testPaging() async {
        let store = LocalSearchStore()
        var msgs: [ChatMessage] = []
        for i in 0 ..< 60 {
            msgs.append(Self.msg(
                "\(4000 + i)", "James Mercer",
                String(format: "2026-09-%02dT08:00:00Z", 1 + (i % 22)),
                "weekly sync notes number \(i) for the team"))
        }
        store.index(chatID: "c1", messages: msgs)
        await store.search(query: "sync")
        XCTAssertEqual(store.total, 60)
        XCTAssertEqual(store.hits.count, 25)
        XCTAssertTrue(store.more)
        XCTAssertNotNil(store.nextFrom)
        XCTAssertTrue(store.canLoadMore)
        await store.loadMore()
        XCTAssertEqual(store.hits.count, 50)
        XCTAssertTrue(store.more)
        await store.loadMore()
        XCTAssertEqual(store.hits.count, 60)
        XCTAssertFalse(store.more)
        XCTAssertFalse(store.canLoadMore)
        // Ids unique across windows (merged, deduped).
        XCTAssertEqual(Set(store.hits.map(\.id)).count, 60)
    }

    func testRetryAndClear() async {
        let store = LocalSearchStore()
        store.index(chatID: "c1", messages: Self.seedMessages())
        await store.search(query: "friday")
        XCTAssertEqual(store.total, 3)
        store.clear()
        XCTAssertTrue(store.hits.isEmpty)
        XCTAssertNil(store.total)
        XCTAssertEqual(store.lastQuery, "")
        XCTAssertEqual(store.docCount, 5) // clear drops the query, not the index
        await store.search(query: "friday")
        store.retry()
        // Retry re-runs; allow the Task a moment (local, instant).
        for _ in 0 ..< 50 where store.lastQuery != "friday" {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(store.lastQuery, "friday")
    }

    // MARK: - Archived + live

    func testArchivedPlusLive() async throws {
        let archived = Array(Self.seedMessages().prefix(3))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("d2-archlive-\(UInt32.random(in: 0 ... .max)).omar")
        defer { try? FileManager.default.removeItem(at: url) }
        try ArchiveStore.export(archived, to: url)
        let (decoded, _) = try ArchiveStore.load(from: url)
        let store = LocalSearchStore()
        store.index(chatID: "archived-thread", messages: decoded)
        store.index(chatID: "live-thread", messages: Array(Self.seedMessages().suffix(2)))
        await store.search(query: "friday")
        let chats = Set(store.hits.map(\.chatID))
        XCTAssertEqual(chats, ["archived-thread", "live-thread"])
        XCTAssertEqual(store.total, 3)
    }

    // MARK: - Persistence

    func testPersistenceRoundTrip() async throws {
        let url = tmpURL("persist")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalSearchStore()
        store.index(chatID: "c1", teamID: "t1", messages: Self.seedMessages())
        await store.search(query: "ship")
        let before = store.hits
        try store.save(to: url)
        // New instance, same query → same hits (acceptance 6).
        let reopened = LocalSearchStore()
        try reopened.load(from: url)
        XCTAssertEqual(reopened.docCount, 5)
        await reopened.search(query: "ship")
        XCTAssertEqual(reopened.hits, before)
        XCTAssertEqual(reopened.total, 3)
        // Team id survives the round-trip.
        XCTAssertEqual(reopened.hits.first?.teamID, "t1")
    }

    func testPersistenceBadMagic() async {
        let url = tmpURL("badmagic")
        defer { try? FileManager.default.removeItem(at: url) }
        try! Data("XXXX0123456789abcdef".utf8).write(to: url)
        let store = LocalSearchStore()
        XCTAssertThrowsError(try store.load(from: url)) { e in
            XCTAssertEqual(e as? LocalSearchError, .badMagic)
        }
    }

    // MARK: - Offline (acceptance 5)

    func testOfflineByConstruction() async {
        // LocalSearchStore exposes no searcher/network seam: the query path
        // cannot call RustCore.search because there is no reference to it.
        // This test pins that seam shut — it must not grow a defaulted
        // network parameter — and proves results come from the local index.
        let store = LocalSearchStore()
        store.index(chatID: "c1", messages: Self.seedMessages())
        await store.search(query: "signatures")
        XCTAssertEqual(store.hits.map(\.messageID), ["1003"])
        XCTAssertEqual(store.total, 1)
        XCTAssertFalse(store.hits.isEmpty)
    }

    // MARK: - Wiring (gap-g6g7)

    func testQueryIsTimed() async {
        let store = LocalSearchStore()
        XCTAssertNil(store.lastQueryMs)
        store.index(chatID: "c1", messages: Self.seedMessages())
        await store.search(query: "ship")
        XCTAssertNotNil(store.lastQueryMs)
        XCTAssertLessThan(store.lastQueryMs ?? 999, 200)
    }

    func testRemoveDropsDocAndPrunesPostings() async {
        let store = LocalSearchStore()
        store.index(chatID: "c1", messages: Self.seedMessages())
        XCTAssertEqual(store.docCount, 5)
        store.remove(chatID: "c1", messageID: "1003")
        XCTAssertEqual(store.docCount, 4)
        await store.search(query: "signatures") // only lived in 1003
        XCTAssertTrue(store.hits.isEmpty)
        // Unknown keys are a no-op.
        store.remove(chatID: "c1", messageID: "nope")
        XCTAssertEqual(store.docCount, 4)
    }

    func testRemoveAllDropsIndexAndQuery() async {
        let store = LocalSearchStore()
        store.index(chatID: "c1", messages: Self.seedMessages())
        await store.search(query: "ship")
        XCTAssertFalse(store.hits.isEmpty)
        store.removeAll()
        XCTAssertEqual(store.docCount, 0)
        XCTAssertTrue(store.hits.isEmpty)
        XCTAssertEqual(store.lastQuery, "")
        await store.search(query: "ship")
        XCTAssertTrue(store.hits.isEmpty)
    }

    func testWeekScaleQueryUnder200ms() async {
        // G6 accept shape: a week's worth of threads indexed, one
        // query finds the old message within the 200ms budget.
        let store = LocalSearchStore()
        var msgs: [ChatMessage] = []
        for i in 0 ..< 2000 {
            msgs.append(Self.msg(
                "w\(i)", "Mate \(i % 40)",
                "2026-09-\(10 + (i % 12))T09:12:00Z",
                "weekly sync notes number \(i) about the deploy plan"))
        }
        msgs.append(Self.msg(
            "w-target", "Megan Harper", "2026-09-14T09:12:00Z",
            "last week we agreed the zebra migration ships monday"))
        store.index(chatID: "c-week", messages: msgs)
        XCTAssertEqual(store.docCount, 2001)
        await store.search(query: "zebra migration")
        XCTAssertEqual(store.hits.map(\.messageID), ["w-target"])
        XCTAssertLessThan(store.lastQueryMs ?? 999, 200)
    }

    func testDefaultIndexURLNames() {
        let base = LocalSearchStore.defaultIndexURL()
        XCTAssertEqual(base?.lastPathComponent, "search-index.omix")
        XCTAssertTrue(base?.path.contains(AppIdentity.name) == true)
        let acct = LocalSearchStore.defaultIndexURL(for: "acct-1")
        XCTAssertEqual(acct?.lastPathComponent, "search-index.acct-1.omix")
        // Unsafe ids sanitize (no separators escape the leaf).
        let evil = LocalSearchStore.defaultIndexURL(for: "../../x")
        XCTAssertEqual(evil?.lastPathComponent, "search-index..._.._x.omix")
    }
}
