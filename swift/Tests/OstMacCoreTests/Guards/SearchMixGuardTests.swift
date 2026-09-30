// SearchMixGuardTests — R7 (REGFIX-B): message search mixes the on-device
// index into the online results again (old behavior, gap-g6g7; bcdbac8 had
// dropped it, inverting MessageSearchOfflineTests). Online hits come
// first, on-device-only hits follow, overlaps dedupe, offline still works.
import XCTest

@testable import OstMacCore

@MainActor
final class SearchMixGuardTests: XCTestCase {
    private func local() -> LocalSearchStore {
        let l = LocalSearchStore()
        l.index(chatID: "c1", messages: [
            ChatMessage(id: "m1", sender: "Megan Harper", timestamp: "2026-09-20T09:12:05Z",
                        content: "Ship the release notes today"),
            ChatMessage(id: "m2", sender: "Tom Becker", timestamp: "2026-09-21T10:00:00Z",
                        content: "shipping lane booked for friday"),
        ])
        return l
    }

    private let online = SearchHit(messageID: "m9", chatID: "19:online@thread.v2", sender: "Ava Lindqvist",
                                   timestamp: "2026-09-22T09:12:05Z", preview: "ship it online")

    func testOnlineResultsIncludeOnDeviceHitsAfterTheServerOnes() async {
        let hit = online
        let store = MessageSearchStore(searcher: { _, _, _ in SearchResponse(ok: true, total: 1, more: false, hits: [hit]) })
        store.local = local()
        await store.search(query: "ship")
        XCTAssertEqual(store.hits.first?.id, hit.id, "server hits rank first")
        XCTAssertEqual(store.hits.count, 3, "1 server hit + the 2 on-device-only hits")
        XCTAssertEqual(store.source, .mixed)
        XCTAssertEqual(store.onlineIDs, [hit.id])
    }

    func testOnDeviceOnlyHitsSurviveAnEmptyServerAnswer() async {
        let store = MessageSearchStore(searcher: { _, _, _ in SearchResponse(ok: true, total: 0, more: false, hits: []) })
        store.local = local()
        await store.search(query: "ship")
        XCTAssertEqual(store.hits.count, 2)
        XCTAssertEqual(store.source, .offline)
    }
}
