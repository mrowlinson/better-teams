// LeaveBlockTests.swift — leave flow, block/unblock store, selection fallback.
import XCTest

@testable import OstMacCore

/// Sendable boxes for asserting calls crossed the detached-task boundary.
private final class CountBox: @unchecked Sendable {
    var value = 0
}

private final class FlagBox: @unchecked Sendable {
    var entered = false
    var released = false
}

@MainActor
final class LeaveBlockTests: XCTestCase {
    // MARK: - Fixtures

    func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-leave-block-\(UUID().uuidString)") ?? .standard
    }

    func memoryBlocked() -> BlockedStore {
        BlockedStore(defaults: nil)
    }

    nonisolated static func response(_ rows: [(id: String, name: String, group: Bool)]) -> ChatsResponse {
        // Descending times so load's Recent order (UI-SPEC §6.2, bff2295
        // recencyOrdered) keeps the listed row order these tests assume.
        ChatListTests.chatsJSON(rows.enumerated().map { i, row in
            ChatListTests.chatJSON(
                id: row.id, name: row.name, group: row.group,
                time: String(format: "2026-09-22T10:%02d:00Z", 59 - i))
        }.joined(separator: ","))
    }

    nonisolated static func groups3() -> ChatsResponse {
        response([
            (id: "g1", name: "Alpha", group: true),
            (id: "g2", name: "Beta", group: true),
            (id: "g3", name: "Gamma", group: true),
        ])
    }

    func loadedModel(
        _ resp: ChatsResponse = groups3(),
        leaver: @escaping ChatListViewModel.Leaver = { LeaveResponse(ok: true, chat_id: $0) },
        blocked: BlockedStore? = nil
    ) async -> ChatListViewModel {
        let model = ChatListViewModel(
            fetcher: { _ in resp }, leaver: leaver,
            blocked: blocked ?? memoryBlocked())
        await model.load()
        return model
    }

    // MARK: - Selection fallback (pure)

    func testFallbackUntouchedSelectionStays() {
        let chats = [
            ChatItem(chatId: "a", name: "A", is_group: true),
            ChatItem(chatId: "b", name: "B", is_group: true),
        ]
        XCTAssertEqual(
            LeaveSelection.fallback(removedID: "a", chats: chats, selectedID: "b"), "b")
        XCTAssertNil(
            LeaveSelection.fallback(removedID: "a", chats: chats, selectedID: nil))
        // Unknown-but-untouched selections survive a real-row removal too.
        XCTAssertEqual(
            LeaveSelection.fallback(
                removedID: "a", chats: chats,
                selectedID: "zz-other"),
            "zz-other")
    }

    func testFallbackMiddleGoesNext() {
        let chats = [
            ChatItem(chatId: "a", name: "A", is_group: true),
            ChatItem(chatId: "b", name: "B", is_group: true),
            ChatItem(chatId: "c", name: "C", is_group: true),
        ]
        XCTAssertEqual(
            LeaveSelection.fallback(removedID: "b", chats: chats, selectedID: "b"), "c")
    }

    func testFallbackLastGoesPrevious() {
        let chats = [
            ChatItem(chatId: "a", name: "A", is_group: true),
            ChatItem(chatId: "b", name: "B", is_group: true),
            ChatItem(chatId: "c", name: "C", is_group: true),
        ]
        XCTAssertEqual(
            LeaveSelection.fallback(removedID: "c", chats: chats, selectedID: "c"), "b")
    }

    func testFallbackOnlyGoesNil() {
        let chats = [ChatItem(chatId: "a", name: "A", is_group: true)]
        XCTAssertNil(
            LeaveSelection.fallback(removedID: "a", chats: chats, selectedID: "a"))
    }

    func testFallbackAbsentRemovedFallsToFirst() {
        let chats = [
            ChatItem(chatId: "a", name: "A", is_group: true),
            ChatItem(chatId: "b", name: "B", is_group: true),
        ]
        // Direct-opened thread (not in the list): first row wins.
        XCTAssertEqual(
            LeaveSelection.fallback(removedID: "x", chats: chats, selectedID: "x"), "a")
        XCTAssertNil(
            LeaveSelection.fallback(removedID: "x", chats: [], selectedID: "x"))
        // Untouched selections stay even when the removed id is unknown.
        XCTAssertEqual(
            LeaveSelection.fallback(removedID: "x", chats: chats, selectedID: "b"), "b")
    }

    func testFallbackNeverReturnsRemoved() {
        let chats = [
            ChatItem(chatId: "a", name: "A", is_group: true),
            ChatItem(chatId: "b", name: "B", is_group: true),
        ]
        for removed in ["a", "b", "x"] {
            for selected: String? in ["a", "b", "x", nil] {
                let next = LeaveSelection.fallback(
                    removedID: removed, chats: chats, selectedID: selected)
                XCTAssertNotEqual(next, removed, "removed=\(removed) selected=\(String(describing: selected))")
            }
        }
    }

    // MARK: - Leave flow

    func testLeaveSuccessRemovesAndMigratesWithoutRefetch() async {
        let fetches = CountBox()
        let resp = Self.groups3()
        let model = ChatListViewModel(
            fetcher: { _ in fetches.value += 1; return resp },
            leaver: { LeaveResponse(ok: true, chat_id: $0) },
            blocked: memoryBlocked())
        await model.load()
        XCTAssertEqual(fetches.value, 1)
        model.selectedChatID = "g2"
        var removed: [String] = []
        model.onLocalRemove = { removed.append($0) }
        await model.leave(chatID: "g2")
        XCTAssertEqual(model.chats.map(\.id), ["g1", "g3"])
        XCTAssertEqual(model.selectedChatID, "g3") // next row
        XCTAssertEqual(model.leavesCompleted, 1)
        XCTAssertEqual(model.leaveFailures, 0)
        XCTAssertNil(model.leaveError)
        XCTAssertTrue(model.leavingIDs.isEmpty)
        XCTAssertEqual(removed, ["g2"])
        XCTAssertEqual(fetches.value, 1) // never refetches
    }

    func testLeaveSuccessLastMigratesPrevious() async {
        let model = await loadedModel()
        model.selectedChatID = "g3"
        await model.leave(chatID: "g3")
        XCTAssertEqual(model.chats.map(\.id), ["g1", "g2"])
        XCTAssertEqual(model.selectedChatID, "g2")
    }

    func testLeaveSuccessOtherSelectionStays() async {
        let model = await loadedModel()
        model.selectedChatID = "g1"
        await model.leave(chatID: "g3")
        XCTAssertEqual(model.chats.map(\.id), ["g1", "g2"])
        XCTAssertEqual(model.selectedChatID, "g1")
    }

    func testLeaveOnlyRowClearsSelection() async {
        let model = await loadedModel(Self.response([(id: "g1", name: "Solo", group: true)]))
        model.selectedChatID = "g1"
        await model.leave(chatID: "g1")
        XCTAssertTrue(model.chats.isEmpty)
        XCTAssertNil(model.selectedChatID)
    }

    func testLeaveFailureKeepsRowAndSetsErrorThenRetries() async {
        let succeed = LockedBox(false)
        let model = await loadedModel(
            Self.groups3(),
            leaver: { id -> LeaveResponse in
                if succeed.value { return LeaveResponse(ok: true, chat_id: id) }
                throw CoreCallError.failed("boom")
            })
        model.selectedChatID = "g2"
        await model.leave(chatID: "g2")
        XCTAssertEqual(model.chats.map(\.id), ["g1", "g2", "g3"]) // row stays
        XCTAssertEqual(model.selectedChatID, "g2")
        XCTAssertEqual(model.leaveError, "boom")
        XCTAssertEqual(model.leaveFailures, 1)
        XCTAssertEqual(model.leavesCompleted, 0)
        XCTAssertTrue(model.leavingIDs.isEmpty)
        // Retry succeeds and clears the error.
        succeed.value = true
        await model.leave(chatID: "g2")
        XCTAssertEqual(model.chats.map(\.id), ["g1", "g3"])
        XCTAssertEqual(model.selectedChatID, "g3")
        XCTAssertNil(model.leaveError)
        XCTAssertEqual(model.leavesCompleted, 1)
    }

    func testLeaveClearError() async {
        let model = await loadedModel(
            Self.groups3(),
            leaver: { _ in throw CoreCallError.failed("boom") })
        await model.leave(chatID: "g1")
        XCTAssertNotNil(model.leaveError)
        model.clearLeaveError()
        XCTAssertNil(model.leaveError)
    }

    func testLeaveNoops() async {
        let calls = CountBox()
        let model = await loadedModel(
            Self.groups3(),
            leaver: { _ in calls.value += 1; return LeaveResponse(ok: true) })
        model.selectedChatID = "g1"
        await model.leave(chatID: "unknown")
        await model.leave(chatID: "om-stale-id")
        await model.leave(chatID: "   ")
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(model.chats.map(\.id), ["g1", "g2", "g3"])
        XCTAssertEqual(model.selectedChatID, "g1")
        XCTAssertNil(model.leaveError)
        XCTAssertEqual(model.leavesCompleted, 0)
        XCTAssertEqual(model.leaveFailures, 0)
    }

    func testLeaveWhileLeavingSingleFlight() async {
        let box = FlagBox()
        let calls = CountBox()
        let model = await loadedModel(
            Self.groups3(),
            leaver: { _ in
                calls.value += 1
                box.entered = true
                while !box.released {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return LeaveResponse(ok: true)
            })
        async let first: Void = model.leave(chatID: "g1")
        // Wait for the first call to go in flight (condition wait, hang ceiling only).
        let entered = await TestWait.until(interval: 0.001) { box.entered }
        XCTAssertTrue(entered, "first leave never went in flight")
        await model.leave(chatID: "g1") // second: no-op while pending
        box.released = true
        await first
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(model.chats.map(\.id), ["g2", "g3"])
    }

    func testRemoveLocallyUnknownIsNoop() async {
        let model = await loadedModel()
        model.selectedChatID = "g1"
        var removed: [String] = []
        model.onLocalRemove = { removed.append($0) }
        model.removeLocally(chatID: "unknown")
        XCTAssertEqual(model.chats.map(\.id), ["g1", "g2", "g3"])
        XCTAssertEqual(model.selectedChatID, "g1")
        XCTAssertTrue(removed.isEmpty)
    }

    // MARK: - Load filtering

    func testLoadFiltersBlocked() async {
        let resp = Self.response([
            (id: "g1", name: "Alpha", group: true),
            (id: "dm1", name: "Ava Lindqvist", group: false),
            (id: "g2", name: "Beta", group: true),
        ])
        let blocked = memoryBlocked()
        blocked.block(chatID: "dm1", name: "Ava Lindqvist")
        let model = ChatListViewModel(
            fetcher: { _ in resp },
            leaver: { LeaveResponse(ok: true, chat_id: $0) },
            blocked: blocked)
        await model.load()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.chats.map(\.id), ["g1", "g2"])
        // Unblocking re-includes the thread on the next load (no refresh
        // is triggered by unblock itself — verified by call absence).
        blocked.unblock(chatID: "dm1")
        XCTAssertEqual(model.chats.map(\.id), ["g1", "g2"])
        await model.load()
        XCTAssertEqual(model.chats.map(\.id), ["g1", "dm1", "g2"])
    }

    func testLoadFiltersNewThreadByBlockedName() async {
        let resp = Self.response([
            (id: "dm-new", name: "Ava Lindqvist", group: false),
            (id: "g-fan", name: "Ava Lindqvist Fans", group: true),
        ])
        let blocked = memoryBlocked()
        blocked.block(chatID: "dm-old", name: "Ava Lindqvist")
        let model = ChatListViewModel(
            fetcher: { _ in resp },
            leaver: { LeaveResponse(ok: true, chat_id: $0) },
            blocked: blocked)
        await model.load()
        // Same-name 1:1 thread matches; group rows never match by name.
        XCTAssertEqual(model.chats.map(\.id), ["g-fan"])
    }

    // MARK: - Block flow

    func testBlockRecordsAndRemoves() async {
        let fetches = CountBox()
        let resp = Self.response([
            (id: "g1", name: "Alpha", group: true),
            (id: "dm1", name: "Ava Lindqvist", group: false),
            (id: "g2", name: "Beta", group: true),
        ])
        let blocked = memoryBlocked()
        let model = ChatListViewModel(
            fetcher: { _ in fetches.value += 1; return resp },
            leaver: { LeaveResponse(ok: true, chat_id: $0) },
            blocked: blocked)
        await model.load()
        model.selectedChatID = "dm1"
        var removed: [String] = []
        model.onLocalRemove = { removed.append($0) }
        model.block(chatID: "dm1")
        XCTAssertEqual(blocked.users.map(\.chatID), ["dm1"])
        XCTAssertEqual(blocked.users.first?.name, "Ava Lindqvist")
        XCTAssertEqual(model.chats.map(\.id), ["g1", "g2"])
        XCTAssertEqual(model.selectedChatID, "g2") // next row
        XCTAssertEqual(removed, ["dm1"])
        XCTAssertEqual(fetches.value, 1) // never refetches
    }

    func testBlockNoops() async {
        let blocked = memoryBlocked()
        let model = await loadedModel(Self.groups3(), blocked: blocked)
        model.selectedChatID = "g1"
        model.block(chatID: "unknown")
        model.block(chatID: "om-stale-id")
        model.block(chatID: "   ")
        XCTAssertTrue(blocked.users.isEmpty)
        XCTAssertEqual(model.chats.map(\.id), ["g1", "g2", "g3"])
        XCTAssertEqual(model.selectedChatID, "g1")
    }

    // MARK: - Blocked store

    func testBlockUnblockRoundTrip() {
        let store = BlockedStore(defaults: isolatedDefaults())
        XCTAssertFalse(store.isBlocked(chatID: "dm1"))
        store.block(chatID: "dm1", name: "Ava Lindqvist")
        XCTAssertEqual(store.count, 1)
        XCTAssertTrue(store.isBlocked(chatID: "dm1"))
        XCTAssertTrue(store.isBlocked(chatID: "dm-other", senderName: "ava lindqvist", isGroup: false))
        XCTAssertFalse(store.isBlocked(chatID: "dm-other", senderName: "ava lindqvist", isGroup: true))
        store.unblock(chatID: "dm1")
        XCTAssertEqual(store.count, 0)
        XCTAssertFalse(store.isBlocked(chatID: "dm1"))
        // Unknown unblock is a no-op.
        store.unblock(chatID: "dm1")
        XCTAssertEqual(store.count, 0)
    }

    func testBlockIgnoresBlankID() {
        let store = memoryBlocked()
        store.block(chatID: "   ", name: "Nobody")
        XCTAssertTrue(store.users.isEmpty)
    }

    func testReblockUpdatesName() {
        let store = memoryBlocked()
        store.block(chatID: "dm1", name: "Ava")
        store.block(chatID: "dm1", name: "Ava Lindqvist")
        XCTAssertEqual(store.users.count, 1)
        XCTAssertEqual(store.users.first?.name, "Ava Lindqvist")
    }

    func testMatchesMatrix() {
        let users = [BlockedUser(chatID: "dm1", name: "  Ava Lindqvist ")]
        // Exact thread id always hits (either thread shape).
        XCTAssertTrue(BlockedUsers.matches(users: users, chatID: "dm1", senderName: nil, isGroup: false))
        XCTAssertTrue(BlockedUsers.matches(users: users, chatID: "dm1", senderName: "X", isGroup: true))
        // Same-name 1:1 sender hits (case-insensitive, trimmed).
        XCTAssertTrue(BlockedUsers.matches(users: users, chatID: "dm9", senderName: "ava LINDQVIST", isGroup: false))
        // Name never matches groups, strangers, or blank senders.
        XCTAssertFalse(BlockedUsers.matches(users: users, chatID: "dm9", senderName: "Ava Lindqvist", isGroup: true))
        XCTAssertFalse(BlockedUsers.matches(users: users, chatID: "dm9", senderName: "Tom Becker", isGroup: false))
        XCTAssertFalse(BlockedUsers.matches(users: users, chatID: "dm9", senderName: nil, isGroup: false))
        XCTAssertFalse(BlockedUsers.matches(users: users, chatID: "dm9", senderName: "  ", isGroup: false))
        XCTAssertFalse(BlockedUsers.matches(users: [], chatID: "dm1", senderName: "Ava Lindqvist", isGroup: false))
    }

    func testPersistenceRoundTrip() {
        let defaults = isolatedDefaults()
        let first = BlockedStore(defaults: defaults)
        first.block(chatID: "dm1", name: "Ava Lindqvist")
        let second = BlockedStore(defaults: defaults)
        XCTAssertEqual(second.users.map(\.chatID), ["dm1"])
        XCTAssertEqual(second.users.first?.name, "Ava Lindqvist")
        XCTAssertTrue(second.isBlocked(chatID: "dm1"))
    }

    func testMemoryOnlyStore() {
        let store = memoryBlocked()
        store.block(chatID: "dm1", name: "Ava")
        XCTAssertTrue(store.isBlocked(chatID: "dm1"))
        store.unblock(chatID: "dm1")
        XCTAssertFalse(store.isBlocked(chatID: "dm1"))
        // A fresh memory store starts empty.
        XCTAssertTrue(memoryBlocked().users.isEmpty)
    }

    func testSortedUsersAndDisplayName() {
        let store = memoryBlocked()
        store.block(chatID: "dm-b", name: "Zed")
        store.block(chatID: "dm-a", name: "ava")
        store.block(chatID: "dm-c", name: "  ")
        XCTAssertEqual(store.sortedUsers.map(\.chatID), ["dm-a", "dm-c", "dm-b"])
        XCTAssertEqual(store.sortedUsers.first?.displayName, "ava")
        XCTAssertEqual(BlockedUser(chatID: "dm-c", name: "  ").displayName, "dm-c")
    }

    // MARK: - Diagnostics + close + envelope

    func testLeaveBlockLine() {
        XCTAssertEqual(
            DiagnosticsFormat.leaveBlockLine(leaves: 2, blocks: 1, failed: 3),
            "2 left · 1 blocked · 3 failed")
    }

    func testConversationCloseClears() {
        let store = ConversationStore()
        store.showDemo(
            chatID: "g1", chatName: "Alpha",
            messages: [ChatMessage(id: "m1", sender: "A", timestamp: "2026-09-24T09:00:00Z", content: "hi")],
            failed: ["m1"])
        store.beginReply(to: store.messages[0])
        store.seedDemoError("boom")
        store.close()
        XCTAssertNil(store.chatID)
        XCTAssertNil(store.chatName)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertNil(store.pageToken)
        XCTAssertFalse(store.loading)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.didLoad)
        XCTAssertTrue(store.failedIDs.isEmpty)
        XCTAssertNil(store.replyTarget)
    }

    func testLeaveResponseDecodes() {
        let json = #"{"ok":true,"chat_id":"g1"}"#
        let resp = try! decodeOrThrow(LeaveResponse.self, from: Data(json.utf8))
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.chat_id, "g1")
    }
}
