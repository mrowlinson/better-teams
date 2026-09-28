// TabPrefetchTests.swift — om-fix-tabs: instant native tab switches.
//
// (a) Shared root lists are cached per chat: reopening a chat shows the
// cached files synchronously (no network wait), then refreshes in the
// background. (b) The Shared tab shows a skeleton only when data is
// truly absent (loading + empty); a refresh over cached rows keeps the
// list on screen. No custom .transition/.animation on tab content.
import XCTest

@testable import OstMacCore

@MainActor
final class TabPrefetchTests: XCTestCase {
    private func file(_ id: String, _ name: String) -> SharedFile {
        SharedFile(id: id, name: name, size: 10)
    }

    private func loaded(_ store: SharedFilesStore) async {
        for _ in 0 ..< 100 {
            if store.state == .loaded || store.state == .empty { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func ids(_ store: SharedFilesStore) -> [String] {
        store.files.map { $0.id }
    }

    /// Reopening a chat shows cached files instantly (sync, pre-fetch).
    func testSharedReopenShowsCacheInstantly() async {
        let calls = LockedBox<[String]>([])
        let store = SharedFilesStore(list: { chat, _ in
            calls.mutate { $0.append(chat) }
            return SharedFilesResponse(ok: true, files: [
                SharedFile(id: "\(chat)-f", name: "\(chat).docx", size: 10),
            ])
        })
        store.open(chatID: "19:a")
        await loaded(store)
        XCTAssertEqual(store.state, .loaded)
        store.open(chatID: "19:b")
        await loaded(store)
        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(calls.value, ["19:a", "19:b"])

        // Cache hit: rows + loaded state synchronously, no wait.
        store.open(chatID: "19:a")
        XCTAssertEqual(ids(store), ["19:a-f"])
        XCTAssertEqual(store.state, .loaded)

        // Background refresh still refetches (freshness), rows stay.
        await loaded(store)
        for _ in 0 ..< 100 {
            if calls.value.count >= 3 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(calls.value, ["19:a", "19:b", "19:a"])
        XCTAssertEqual(ids(store), ["19:a-f"])
        XCTAssertEqual(store.state, .loaded)
    }

    /// Prefetch gate: any chat change loads Shared (tab-independent).
    func testPrefetchGateIgnoresTab() {
        XCTAssertTrue(ConversationStore.shouldPrefetchShared(sharedChatID: nil, chatID: "19:a"))
        XCTAssertTrue(ConversationStore.shouldPrefetchShared(sharedChatID: "19:b", chatID: "19:a"))
        XCTAssertFalse(ConversationStore.shouldPrefetchShared(sharedChatID: "19:a", chatID: "19:a"))
        XCTAssertFalse(ConversationStore.shouldPrefetchShared(sharedChatID: "19:a", chatID: nil))
    }
}
