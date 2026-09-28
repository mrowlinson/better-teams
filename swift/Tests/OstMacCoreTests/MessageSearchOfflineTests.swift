// MessageSearchOfflineTests.swift — gap-g6g7 lane: offline-first merge.
//
// MessageSearchStore with `local` attached runs the on-device index
// first (instant, timed), merges online hits above the offline-only
// extras, and falls back to local hits when the network fails.
import XCTest

@testable import OstMacCore

@MainActor
final class MessageSearchOfflineTests: XCTestCase {
    nonisolated static func localSeed() -> [ChatMessage] {
        [
            ChatMessage(
                id: "m1", sender: "Megan Harper",
                timestamp: "2026-09-20T09:12:05Z",
                content: "Ship the release notes today"),
            ChatMessage(
                id: "m2", sender: "Tom Becker",
                timestamp: "2026-09-21T10:00:00Z",
                content: "shipping lane booked for friday"),
        ]
    }

    nonisolated static func onlineHit() -> SearchHit {
        SearchHit(
            messageID: "m9", chatID: "19:online@thread.v2",
            sender: "Ava Lindqvist",
            timestamp: "2026-09-22T09:12:05Z",
            preview: "ship it online")
    }

    /// Attach a `local` seeded with `localSeed()` in chat "c1".
    func attachedLocal() -> LocalSearchStore {
        let local = LocalSearchStore()
        local.index(chatID: "c1", messages: Self.localSeed())
        return local
    }

    // MARK: - Online = server results only (UI-SPEC §5.5)

    /// The offline index merges only when offline: online, the server
    /// window replaces the interim local hits (no "On This Mac" extras).
    func testOnlineResultsAreServerOnly() async {
        let online = Self.onlineHit()
        let store = MessageSearchStore(searcher: { _, _, _ in
            SearchResponse(ok: true, total: 1, more: false, hits: [online])
        })
        store.local = attachedLocal()
        await store.search(query: "ship")
        XCTAssertEqual(store.hits.map(\.id), [online.id])
        XCTAssertEqual(store.onlineIDs, [online.id])
        XCTAssertEqual(store.source, .online)
        XCTAssertNotNil(store.offlineMs) // the local pass still ran (interim + fallback)
        XCTAssertEqual(store.total, 1)
    }

    func testOverlappingHitDedupesKeepsOnlineRank() async {
        // Online returns the same bubble the index holds (m1 in c1):
        // one row, online rank, no duplicate.
        let dup = SearchHit(
            messageID: "m1", chatID: "c1",
            sender: "Megan Harper",
            timestamp: "2026-09-20T09:12:05Z",
            preview: "Ship the release notes today")
        let store = MessageSearchStore(searcher: { _, _, _ in
            SearchResponse(ok: true, total: 1, more: false, hits: [dup])
        })
        store.local = attachedLocal()
        await store.search(query: "release") // local matches m1 only
        XCTAssertEqual(store.hits.map(\.id), [dup.id])
        XCTAssertEqual(store.source, .online) // no extras left
    }

    func testOnlineOnlyHitsWhenLocalEmpty() async {
        let online = Self.onlineHit()
        let store = MessageSearchStore(searcher: { _, _, _ in
            SearchResponse(ok: true, total: 1, more: false, hits: [online])
        })
        store.local = LocalSearchStore() // attached but empty
        await store.search(query: "ship")
        XCTAssertEqual(store.hits.map(\.id), [online.id])
        XCTAssertEqual(store.source, .online)
        XCTAssertNotNil(store.offlineMs)
    }

    func testNoLocalAttachedIsLegacyOnlineOnly() async {
        let online = Self.onlineHit()
        let store = MessageSearchStore(searcher: { _, _, _ in
            SearchResponse(ok: true, total: 1, more: false, hits: [online])
        })
        await store.search(query: "ship")
        XCTAssertEqual(store.hits.map(\.id), [online.id])
        XCTAssertEqual(store.source, .online)
        XCTAssertNil(store.offlineMs)
    }

    // MARK: - Airplane fallback

    func testNetworkFailureFallsBackToLocalHits() async {
        let store = MessageSearchStore(searcher: { _, _, _ in
            throw CoreCallError.failed("network unreachable")
        })
        store.local = attachedLocal()
        await store.search(query: "ship")
        XCTAssertEqual(store.hits.count, 2)
        XCTAssertEqual(store.source, .offline)
        XCTAssertNil(store.error) // no error banner over offline hits
        XCTAssertNotNil(store.offlineMs)
        XCTAssertLessThan(store.offlineMs ?? 999, 200) // G6 <200ms accept
    }

    func testNetworkFailureWithoutLocalHitsSurfacesError() async {
        let store = MessageSearchStore(searcher: { _, _, _ in
            throw CoreCallError.failed("network unreachable")
        })
        store.local = LocalSearchStore()
        await store.search(query: "ship")
        XCTAssertTrue(store.hits.isEmpty)
        XCTAssertEqual(store.error, "network unreachable")
        XCTAssertEqual(store.source, .none)
    }

    func testEmptyOnlineDropsLocalHits() async {
        let store = MessageSearchStore(searcher: { _, _, _ in
            SearchResponse(ok: true, total: 0, more: false, hits: [])
        })
        store.local = attachedLocal()
        await store.search(query: "ship")
        XCTAssertTrue(store.hits.isEmpty)
        XCTAssertEqual(store.source, .none)
        XCTAssertNil(store.error)
    }

    // MARK: - Paging + clear with local attached

    func testLoadMoreAppendsServerWindowOnly() async {
        let first = Self.onlineHit()
        let second = SearchHit(
            messageID: "m10", chatID: "19:online@thread.v2",
            sender: "Ava Lindqvist",
            timestamp: "2026-09-22T09:13:05Z",
            preview: "ship second window")
        let calls = LockedBox(0)
        let store = MessageSearchStore(searcher: { _, _, _ in
            let n = calls.mutate { $0 += 1; return $0 }
            if n == 1 {
                return SearchResponse(ok: true, total: 2, more: true, next_from: 1, hits: [first])
            }
            return SearchResponse(ok: true, total: 2, more: false, next_from: nil, hits: [second])
        })
        store.local = attachedLocal()
        await store.search(query: "ship")
        XCTAssertEqual(store.hits.count, 1) // server window only
        await store.loadMore()
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(store.hits.map(\.id), [first.id, second.id])
        XCTAssertFalse(store.hits.contains(where: { $0.id == "c1:m1" }))
    }

    func testClearResetsSourceAndLocal() async {
        let online = Self.onlineHit()
        let store = MessageSearchStore(searcher: { _, _, _ in
            SearchResponse(ok: true, total: 1, more: false, hits: [online])
        })
        let local = attachedLocal()
        store.local = local
        await store.search(query: "ship")
        XCTAssertFalse(store.hits.isEmpty)
        store.clear()
        XCTAssertTrue(store.hits.isEmpty)
        XCTAssertEqual(store.source, .none)
        XCTAssertNil(store.offlineMs)
        XCTAssertTrue(local.hits.isEmpty)
        XCTAssertEqual(local.lastQuery, "")
    }

    func testBlankQueryClearsWithoutTouchingEither() async {
        let calls = LockedBox(0)
        let store = MessageSearchStore(searcher: { _, _, _ in
            calls.mutate { $0 += 1 }
            return SearchResponse(ok: true, more: false, hits: [])
        })
        let local = attachedLocal()
        store.local = local
        await local.search(query: "ship")
        XCTAssertFalse(local.hits.isEmpty)
        await store.search(query: "   ")
        XCTAssertEqual(calls.value, 0)
        XCTAssertTrue(store.hits.isEmpty)
        XCTAssertEqual(store.source, .none)
        XCTAssertTrue(local.hits.isEmpty) // blank clears the local window too
    }
}
