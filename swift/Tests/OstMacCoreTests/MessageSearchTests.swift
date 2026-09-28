// MessageSearchTests.swift — om-ja-search lane: Graph MESSAGE search decode,
// MessageSearchStore paging, ConversationStore seek-to-message.
import XCTest

@testable import OstMacCore

@MainActor
final class MessageSearchTests: XCTestCase {
    // MARK: - Fixtures

    nonisolated static func searchJSON() -> SearchResponse {
        let json = """
            {"ok":true,"query":"ship","from":0,"size":25,"total":2,\
            "more":false,"next_from":null,"hits":[\
            {"message_id":"1758600000000","chat_id":"19:chat1@thread.v2",\
            "team_id":null,"channel_id":null,"sender":"Megan Harper",\
            "timestamp":"2026-09-22T09:12:05Z","preview":"...Ship it...","subject":null},\
            {"message_id":"1758600001000","chat_id":"demo-chan-general",\
            "team_id":"demo-team-eng","channel_id":"demo-chan-general",\
            "sender":"Tom Becker","timestamp":"2026-09-22T09:13:05Z",\
            "preview":"...shipping lane...","subject":""}]}
            """
        return try! decodeOrThrow(SearchResponse.self, from: Data(json.utf8))
    }

    // MARK: - Wire decode

    func testDecodeSearchEnvelope() {
        let response = Self.searchJSON()
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.query, "ship")
        XCTAssertEqual(response.total, 2)
        XCTAssertFalse(response.more)
        XCTAssertNil(response.next_from)
        XCTAssertEqual(response.hits.count, 2)
        let chat = response.hits[0]
        XCTAssertEqual(chat.messageID, "1758600000000")
        XCTAssertEqual(chat.chatID, "19:chat1@thread.v2")
        XCTAssertNil(chat.teamID)
        XCTAssertEqual(chat.sender, "Megan Harper")
        XCTAssertEqual(chat.preview, "...Ship it...")
        // Routes through ChatMessage rules (local + locale clock; exact
        // pins live in FidTimeTests with explicit zone/locale).
        XCTAssertEqual(chat.displayTime, ChatMessage.shortTime("2026-09-22T09:12:05Z"))
        // Channel hit: conversation id is the channel, team retained.
        let channel = response.hits[1]
        XCTAssertEqual(channel.chatID, "demo-chan-general")
        XCTAssertEqual(channel.teamID, "demo-team-eng")
        XCTAssertEqual(channel.channelID, "demo-chan-general")
        // Row ids stay unique across chats sharing a message id.
        XCTAssertNotEqual(chat.id, channel.id)
    }

    func testErrorEnvelopeThrows() {
        let json = #"{"ok":false,"error":"search","detail":"403"}"#
        XCTAssertThrowsError(
            try decodeOrThrow(SearchResponse.self, from: Data(json.utf8)))
    }

    // MARK: - Store search

    func testSearchBlankQueryClearsWithoutFetching() async {
        let calls = LockedBox(0)
        let store = MessageSearchStore(searcher: { _, _, _ in
            calls.mutate { $0 += 1 }
            return Self.searchJSON()
        })
        await store.search(query: "   ")
        XCTAssertEqual(calls.value, 0)
        XCTAssertTrue(store.hits.isEmpty)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isSearching)
    }

    func testSearchLoadsHits() async {
        let store = MessageSearchStore(searcher: { _, _, _ in Self.searchJSON() })
        await store.search(query: "ship")
        XCTAssertEqual(store.hits.count, 2)
        XCTAssertEqual(store.lastQuery, "ship")
        XCTAssertEqual(store.total, 2)
        XCTAssertFalse(store.more)
        XCTAssertNil(store.nextFrom)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isSearching)
    }

    func testSearchErrorSurfaces() async {
        let store = MessageSearchStore(searcher: { _, _, _ in
            throw CoreCallError.failed("search denied")
        })
        await store.search(query: "ship")
        XCTAssertTrue(store.hits.isEmpty)
        XCTAssertEqual(store.error, "search denied")
        XCTAssertFalse(store.isSearching)
    }

    // MARK: - Paging

    func testLoadMoreAppendsAndDedupes() async {
        let page0 = SearchResponse(
            ok: true, query: "ship", from: 0, size: 1, total: 2,
            more: true, next_from: 1,
            hits: [SearchHit(
                messageID: "m1", chatID: "c1", sender: "A",
                timestamp: "2026-09-22T09:12:05Z", preview: "one")])
        let page1 = SearchResponse(
            ok: true, query: "ship", from: 1, size: 1, total: 2,
            more: false, next_from: nil,
            hits: [
                SearchHit(
                    messageID: "m1", chatID: "c1", sender: "A",
                    timestamp: "2026-09-22T09:12:05Z", preview: "one"),
                SearchHit(
                    messageID: "m2", chatID: "c1", sender: "B",
                    timestamp: "2026-09-22T09:13:05Z", preview: "two"),
            ])
        let calls = LockedBox<[Int]>([])
        let store = MessageSearchStore(searcher: { _, from, _ in
            calls.mutate { $0.append(Int(from)) }
            return from == 0 ? page0 : page1
        })
        await store.search(query: "ship")
        XCTAssertEqual(store.hits.count, 1)
        XCTAssertTrue(store.more)
        await store.loadMore()
        XCTAssertEqual(calls.value, [0, 1])
        XCTAssertEqual(store.hits.map(\.messageID), ["m1", "m2"])
        XCTAssertFalse(store.more)
        XCTAssertNil(store.nextFrom)
    }

    func testLoadMoreWithoutCursorIsNoop() async {
        let calls = LockedBox(0)
        let store = MessageSearchStore(searcher: { _, _, _ in
            calls.mutate { $0 += 1 }
            return Self.searchJSON()
        })
        await store.search(query: "ship") // more=false fixture
        await store.loadMore()
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(store.hits.count, 2)
    }

    // MARK: - Seek-to-message (jump target)

    func testSeekFindsLoadedMessage() {
        let store = ConversationStore()
        store.showDemo(
            chatID: DemoData.repliesID, chatName: "Replies",
            messages: DemoData.messages(for: DemoData.repliesID))
        XCTAssertNil(store.jumpTargetID)
        store.seek(messageID: "rep-2")
        XCTAssertEqual(store.jumpTargetID, "rep-2")
        store.clearJumpTarget()
        XCTAssertNil(store.jumpTargetID)
    }

    func testSeekMissingWithoutCursorArmsMiss() {
        let store = ConversationStore()
        store.showDemo(
            chatID: DemoData.repliesID, chatName: "Replies",
            messages: DemoData.messages(for: DemoData.repliesID))
        // Gap-g9: definitive miss (demo has no page token: no fetch)
        // banners instead of a silent no-op.
        store.seek(messageID: "no-such-bubble")
        XCTAssertNil(store.jumpTargetID)
        XCTAssertEqual(store.jumpMissedID, "no-such-bubble")
        store.seek(messageID: "   ")
        XCTAssertNil(store.jumpTargetID)
        XCTAssertNil(store.jumpMissedID)
    }

    // MARK: - Demo fixture

    func testDemoSearchSubstringsAndJumpLandsInMemory() {
        let all = DemoData.messageSearchResponse(for: "")
        XCTAssertEqual(all.hits.count, 5)
        let illustration = DemoData.messageSearchResponse(for: "illustration")
        XCTAssertTrue(illustration.hits.contains { $0.messageID == "rep-2" })
        let standup = DemoData.messageSearchResponse(for: "standup")
        XCTAssertEqual(standup.hits.map(\.messageID), ["ava-3"])
        XCTAssertEqual(standup.total, 1)
        XCTAssertFalse(standup.more)
        // Every canned hit id exists in its demo thread: jump-to-message
        // seeks in-memory in demo (no paging, no network).
        for hit in all.hits {
            let thread = DemoData.messages(for: hit.chatID)
            XCTAssertTrue(
                thread.contains { $0.id == hit.messageID },
                "hit \(hit.id) missing from its demo thread")
        }
    }

    // MARK: - Live FFI (no network: arg guard)

    func testLiveFFIEmptyQueryThrows() {
        XCTAssertThrowsError(try RustCore.search(query: "  "))
        XCTAssertThrowsError(try RustCore.search(query: "", from: 0, size: 25))
    }
}
