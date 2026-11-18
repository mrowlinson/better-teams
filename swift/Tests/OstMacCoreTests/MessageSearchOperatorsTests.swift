// MessageSearchOperatorsTests — SHORTCUTS-R2 (SRCH-02/04): operators +
// slash commands across the server post-filter (MessageSearchStore) and
// the on-device index (LocalSearchStore). Same query, same answer.
import XCTest

@testable import OstMacCore

@MainActor
final class MessageSearchOperatorsTests: XCTestCase {
    nonisolated static func hit(
        _ id: String, sender: String, chat: String, ts: String, preview: String
    ) -> SearchHit {
        SearchHit(
            messageID: id, chatID: chat, sender: sender,
            timestamp: ts, preview: preview)
    }

    nonisolated static func serverHits() -> [SearchHit] {
        [
            hit("m1", sender: "Ava Lindqvist", chat: "19:chat1@thread.v2",
                ts: "2026-11-17T10:00:00Z", preview: "ship the release"),
            hit("m2", sender: "Tom Becker", chat: "chan-general",
                ts: "2026-11-18T10:00:00Z", preview: "shipping lane update"),
        ]
    }

    /// Store whose searcher captures the server query text.
    func capturingStore(_ hits: [SearchHit]) -> (MessageSearchStore, LockedBox<String>) {
        let seen = LockedBox("")
        let store = MessageSearchStore(searcher: { query, _, _ in
            seen.mutate { $0 = query }
            return SearchResponse(ok: true, total: hits.count, more: false, hits: hits)
        })
        return (store, seen)
    }

    // MARK: - Server text + post-filter

    func testServerGetsTextOnly() async {
        let (store, seen) = capturingStore(Self.serverHits())
        await store.search(query: "ship from:ava")
        XCTAssertEqual(seen.value, "ship")
        XCTAssertEqual(store.hits.map(\.messageID), ["m1"])
        XCTAssertEqual(store.total, 1)
    }

    func testDateNarrowsServerHits() async {
        let (store, _) = capturingStore(Self.serverHits())
        await store.search(query: "ship date:2026-11-18")
        XCTAssertEqual(store.hits.map(\.messageID), ["m2"])
    }

    func testInMatchesChatNameViaHook() async {
        let (store, _) = capturingStore(Self.serverHits())
        store.chatName = { $0 == "chan-general" ? "General" : nil }
        await store.search(query: "ship in:general")
        XCTAssertEqual(store.hits.map(\.messageID), ["m2"])
    }

    func testUnreadNarrowsViaHook() async {
        let (store, _) = capturingStore(Self.serverHits())
        store.isUnread = { $0 == "chan-general" }
        await store.search(query: "/unread ship")
        XCTAssertEqual(store.hits.map(\.messageID), ["m2"])
    }

    func testUnreadWithoutHookMatchesNothing() async {
        let (store, _) = capturingStore(Self.serverHits())
        await store.search(query: "/unread ship")
        XCTAssertTrue(store.hits.isEmpty)
    }

    // MARK: - Operators alone skip the server

    func testOperatorsAloneUseLocalOnly() async {
        let local = LocalSearchStore()
        local.index(
            chatID: "c1",
            messages: [ChatMessage(
                id: "m1", sender: "Megan Harper",
                timestamp: "2026-11-17T10:00:00Z", content: "ship it")])
        let (store, seen) = capturingStore(Self.serverHits())
        store.local = local
        await store.search(query: "from:megan")
        XCTAssertEqual(seen.value, "", "no server window for operators alone")
        XCTAssertEqual(store.hits.map(\.messageID), ["m1"])
        XCTAssertEqual(store.source, .offline)
    }

    func testOperatorsAloneWithNoLocalClear() async {
        let (store, seen) = capturingStore(Self.serverHits())
        await store.search(query: "ship")
        XCTAssertEqual(store.hits.count, 2)
        await store.search(query: "from:nobody")
        XCTAssertEqual(seen.value, "ship", "no second fetch")
        XCTAssertTrue(store.hits.isEmpty)
        XCTAssertEqual(store.source, .none)
    }

    // MARK: - /saved

    func testSavedServesSavedHits() async {
        let saved = Self.hit(
            "s1", sender: "Ava Lindqvist", chat: "19:chat1@thread.v2",
            ts: "2026-11-17T10:00:00Z", preview: "keep this design")
        let (store, seen) = capturingStore(Self.serverHits())
        store.savedHits = { [saved] }
        await store.search(query: "/saved")
        XCTAssertEqual(seen.value, "", "no server window for /saved")
        XCTAssertEqual(store.hits.map(\.messageID), ["s1"])
        XCTAssertEqual(store.source, .offline)
        await store.search(query: "/saved design")
        XCTAssertEqual(store.hits.map(\.messageID), ["s1"])
        await store.search(query: "/saved shipping")
        XCTAssertTrue(store.hits.isEmpty)
    }

    // MARK: - Load more stays filtered

    func testLoadMoreFiltersNextWindow() async {
        let page = Self.serverHits()
        let store = MessageSearchStore(searcher: { _, from, _ in
            SearchResponse(
                ok: true, total: 3, more: from == 0,
                next_from: from == 0 ? 2 : nil, hits: page)
        })
        await store.search(query: "ship from:ava")
        XCTAssertEqual(store.hits.map(\.messageID), ["m1"])
        await store.loadMore()
        XCTAssertEqual(store.hits.map(\.messageID), ["m1"], "no duplicate, page filtered")
    }

    // MARK: - Local index

    func testLocalFromDateUnread() async {
        let local = LocalSearchStore()
        local.index(chatID: "c1", messages: [
            ChatMessage(
                id: "m1", sender: "Megan Harper",
                timestamp: "2026-11-17T10:00:00Z", content: "ship the release"),
            ChatMessage(
                id: "m2", sender: "Tom Becker",
                timestamp: "2026-11-18T10:00:00Z", content: "shipping lane update"),
        ])
        await local.search(query: "ship from:megan")
        XCTAssertEqual(local.hits.map(\.messageID), ["m1"])
        await local.search(query: "ship date:2026-11-18")
        XCTAssertEqual(local.hits.map(\.messageID), ["m2"])
        local.isUnread = { _ in false }
        await local.search(query: "/unread ship")
        XCTAssertTrue(local.hits.isEmpty)
        local.isUnread = { _ in true }
        await local.search(query: "/unread ship")
        XCTAssertEqual(local.hits.count, 2)
        await local.search(query: "/saved ship")
        XCTAssertTrue(local.hits.isEmpty, "/saved never matches the index")
    }

    func testLocalOperatorsAloneScanAllDocs() async {
        let local = LocalSearchStore()
        local.index(chatID: "c1", messages: [
            ChatMessage(
                id: "m1", sender: "Megan Harper",
                timestamp: "2026-11-17T10:00:00Z", content: "ship the release"),
            ChatMessage(
                id: "m2", sender: "Tom Becker",
                timestamp: "2026-11-18T10:00:00Z", content: "other topic here"),
        ])
        await local.search(query: "from:tom")
        XCTAssertEqual(local.hits.map(\.messageID), ["m2"])
    }

    func testLocalInChatHonorsOperators() {
        let local = LocalSearchStore()
        local.index(chatID: "c1", messages: [
            ChatMessage(
                id: "m1", sender: "Megan Harper",
                timestamp: "2026-11-17T10:00:00Z", content: "ship the release"),
        ])
        XCTAssertEqual(local.hits(matching: "ship from:megan", inChat: "c1").count, 1)
        XCTAssertTrue(local.hits(matching: "ship from:tom", inChat: "c1").isEmpty)
        XCTAssertTrue(local.hits(matching: "/saved", inChat: "c1").isEmpty)
    }
}
