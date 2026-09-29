import XCTest
@testable import OstMacCore

/// Chat list paging (merge, order, lazy pages), the list filter's
/// never-messaged rule, spinners clearing on every terminal state, the
/// Teams folder move (optimistic + rollback), and the sync bridge
/// making progress when the cooperative pool is saturated.
@MainActor
final class ChatListPagingTests: XCTestCase {
    private func chat(_ id: String, _ minute: Int?) -> ChatItem {
        ChatItem(
            chatId: id, name: "Chat \(id)", is_group: true,
            last_message_time: minute.map { String(format: "2026-09-28T08:%02d:00.000Z", $0) },
            last_message_sender: nil, last_message_preview: "hi")
    }

    private struct Boom: Error {}

    // MARK: merge + order

    func testCompleteFetchReplacesAndSortsByRecency() {
        let out = ChatListViewModel.merged(
            existing: [chat("gone", 50)], fetched: [chat("a", 10), chat("b", 30)], complete: true)
        XCTAssertEqual(out.map(\.id), ["b", "a"])
    }

    func testPartialFetchKeepsOlderRowsAndDropsNewerAbsentOnes() {
        let existing = [chat("stale-new", 40), chat("a", 20), chat("old", 5), chat("undated", nil)]
        let fetched = [chat("a", 25), chat("b", 30), chat("c", 15)]
        let out = ChatListViewModel.merged(existing: existing, fetched: fetched, complete: false)
        // "stale-new" sits inside the re-read window but is gone: dropped.
        // "old" is older than the window: kept. Fetched "a" wins.
        XCTAssertEqual(out.map(\.id), ["b", "a", "c", "old"])
        XCTAssertEqual(out.first { $0.id == "a" }?.last_message_time, chat("a", 25).last_message_time)
    }

    func testOlderPageMergeKeepsEveryRow() {
        let out = ChatListViewModel.merged(
            existing: [chat("a", 30), chat("b", 20)], fetched: [chat("c", 10), chat("a", 30)],
            complete: false, dropNewerAbsent: false)
        XCTAssertEqual(out.map(\.id), ["a", "b", "c"])
    }

    // MARK: paging through the view model

    func testLoadThenLoadMoreWalksPagesAndClearsSpinner() async {
        let vm = ChatListViewModel(
            fetcher: { _ in ChatsResponse(ok: true, chats: [self.chatSync("a", 30)], next_link: "p2") },
            pageFetcher: { link in
                XCTAssertEqual(link, "p2")
                return ChatsResponse(ok: true, chats: [self.chatSync("b", 10)], next_link: nil)
            })
        await vm.load()
        XCTAssertEqual(vm.chats.map(\.id), ["a"])
        XCTAssertTrue(vm.hasMore)
        await vm.loadMore()
        XCTAssertEqual(vm.chats.map(\.id), ["a", "b"])
        XCTAssertFalse(vm.hasMore)
        XCTAssertFalse(vm.isLoadingMore)
        XCTAssertEqual(vm.loadedPages, 2)
    }

    func testRefreshRereadsLoadedPages() async {
        let calls = PageCallCounter()
        let vm = ChatListViewModel(
            fetcher: { _ in ChatsResponse(ok: true, chats: [self.chatSync("a", 30)], next_link: "p2") },
            pageFetcher: { _ in
                calls.bump()
                return ChatsResponse(ok: true, chats: [self.chatSync("b", 10)], next_link: "p3")
            })
        await vm.load()
        await vm.loadMore()
        await vm.load()
        XCTAssertEqual(calls.value, 2) // the refresh re-read page 2 too
        XCTAssertEqual(vm.chats.map(\.id), ["a", "b"])
        XCTAssertEqual(vm.nextPageLink, "p3")
    }

    // MARK: spinners clear on every terminal state

    func testListSpinnerClearsOnSuccessEmptyErrorAndSupersede() async {
        let ok = ChatListViewModel(fetcher: { _ in ChatsResponse(ok: true, chats: [self.chatSync("a", 1)]) })
        await ok.load()
        XCTAssertEqual(ok.state, .loaded)

        let empty = ChatListViewModel(fetcher: { _ in ChatsResponse(ok: true, chats: []) })
        await empty.load()
        XCTAssertEqual(empty.state, .empty)

        let failing = ChatListViewModel(fetcher: { _ in throw Boom() })
        await failing.load()
        if case .error = failing.state {} else { XCTFail("error state expected, got \(failing.state)") }

        // Superseded (account switch mid-fetch): never left on .loading.
        let gate = DispatchSemaphore(value: 0)
        let slow = ChatListViewModel(fetcher: { _ in
            gate.wait()
            return ChatsResponse(ok: true, chats: [self.chatSync("x", 1)])
        })
        let task = Task { await slow.load() }
        await Task.yield()
        slow.resetForAccount()
        gate.signal()
        await task.value
        XCTAssertEqual(slow.state, .empty)
        XCTAssertTrue(slow.chats.isEmpty)
    }

    func testPageSpinnerClearsOnFailureAndKeepsLink() async {
        let vm = ChatListViewModel(
            fetcher: { _ in ChatsResponse(ok: true, chats: [self.chatSync("a", 30)], next_link: "p2") },
            pageFetcher: { _ in throw Boom() })
        await vm.load()
        await vm.loadMore()
        XCTAssertFalse(vm.isLoadingMore)
        XCTAssertEqual(vm.nextPageLink, "p2")
        XCTAssertEqual(vm.state, .loaded)
    }

    // MARK: list filter + preview + page link

    func testNeverMessagedConversationsLeaveTheList() {
        func ex(_ id: String, _ has: Bool) -> ChatListFilter.Exclusion? {
            ChatListFilter.exclusion(
                id: id, threadType: "chat", productThreadType: nil, hidden: nil,
                lastJoinAt: nil, lastLeaveAt: nil, isEmpty: nil, hasLastMessage: has)
        }
        XCTAssertEqual(ex("19:m@thread.v2", false), .empty)
        XCTAssertNil(ex("19:m@thread.v2", true))
        XCTAssertNil(ex(ChatListFilter.selfChatID, false))
    }

    func testImageOnlyPreviewAndPageLinkGuard() {
        XCTAssertEqual(CoreReads.listPreview("<p><img src=\"x\" alt=\"image\"></p>"), "Sent an image")
        XCTAssertEqual(CoreReads.listPreview("<p>Hello</p>"), "Hello")
        XCTAssertTrue(CoreReads.isChatPageLink(
            "https://amer.ng.msg.teams.microsoft.com/v1/users/ME/conversations?view=mychats&syncState=s"))
        XCTAssertFalse(CoreReads.isChatPageLink("http://amer.ng.msg.teams.microsoft.com/v1/users/ME/conversations"))
        XCTAssertFalse(CoreReads.isChatPageLink("https://example.com/v1/users/ME/conversations"))
        XCTAssertFalse(CoreReads.isChatPageLink("https://amer.ng.msg.teams.microsoft.com/v1/users/ME/properties"))
    }

    // MARK: Teams folder move

    private func folderStore() -> FolderStore {
        let store = FolderStore(defaults: UserDefaults(suiteName: "chatlist2-\(UUID().uuidString)")!)
        store.applyServer([ServerChatFolder(id: "fav", name: "Favorites", folder_type: "Favorites",
                                            item_ids: ["19:a@thread.v2"])])
        return store
    }

    func testServerMoveAppliesTheAnswer() async {
        let store = folderStore()
        let seen = PageCallCounter()
        store.serverMover = { chat, folder in
            XCTAssertEqual(chat, "48:notes")
            XCTAssertEqual(folder, "fav")
            seen.bump()
            return ChatFoldersResponse(ok: true, folders: [ServerChatFolder(
                id: "fav", name: "Favorites", folder_type: "Favorites",
                item_ids: ["19:a@thread.v2", "48:notes"])])
        }
        await store.moveOnServer(chatID: "48:notes", to: "fav")
        XCTAssertEqual(seen.value, 1)
        XCTAssertEqual(store.favoriteIDs, ["19:a@thread.v2", "48:notes"])
        XCTAssertEqual(store.serverAssignments["48:notes"], "fav")
        XCTAssertTrue(store.movingIDs.isEmpty)
        XCTAssertNil(store.serverSyncError)
    }

    func testServerMoveRollsBackWhenRefused() async {
        let store = folderStore()
        store.serverMover = { _, _ in throw CoreCallError.failed("folder_move: 403") }
        await store.moveOnServer(chatID: "19:a@thread.v2", to: nil)
        XCTAssertEqual(store.favoriteIDs, ["19:a@thread.v2"])
        XCTAssertEqual(store.serverAssignments["19:a@thread.v2"], "fav")
        XCTAssertTrue(store.movingIDs.isEmpty)
        XCTAssertNotNil(store.serverSyncError)
        // Unknown and system targets never reach the server.
        store.serverMover = { _, _ in XCTFail("no call"); throw Boom() }
        await store.moveOnServer(chatID: "19:a@thread.v2", to: "nope")
    }

    // MARK: sync bridge vs a saturated cooperative pool

    nonisolated func testSyncBridgeCompletesWhenEveryPoolThreadWaits() async throws {
        // Far more blocking waiters than pool threads: the old bridge
        // (inner Task on the pool) deadlocked here.
        let n = ProcessInfo.processInfo.activeProcessorCount * 4
        let done = try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<n {
                group.addTask {
                    try await Task.detached {
                        try SyncBridge.run {
                            try await Task.sleep(nanoseconds: 5_000_000)
                            return i
                        }
                    }.value
                }
            }
            return try await group.reduce(0) { acc, _ in acc + 1 }
        }
        XCTAssertEqual(done, n)
    }

    nonisolated private func chatSync(_ id: String, _ minute: Int) -> ChatItem {
        ChatItem(
            chatId: id, name: "Chat \(id)", is_group: true,
            last_message_time: String(format: "2026-09-28T08:%02d:00.000Z", minute),
            last_message_sender: nil, last_message_preview: "hi")
    }
}

private final class PageCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}
