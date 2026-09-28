// PinnedChatsTests.swift — om-p1-placeholders: sidebar order is user pins + recency.
import XCTest

@testable import OstMacCore

@MainActor
final class PinnedChatsTests: XCTestCase {
    // MARK: - Fixtures

    nonisolated static func chat(
        id: String, name: String, preview: String? = nil
    ) -> ChatItem {
        ChatItem(
            chatId: id, name: name,
            last_message_time: "2026-09-22T09:00:00Z",
            last_message_sender: "S",
            last_message_preview: preview ?? "hi")
    }

    nonisolated static func response(_ chats: [ChatItem]) -> ChatsResponse {
        ChatsResponse(ok: true, chats: chats)
    }

    nonisolated static func live(
        chat: String, text: String = "live hello"
    ) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chat, msgId: "m-live", sender: "S",
            text: text, time: "2026-09-22T10:00:00Z", isEdit: false)
    }

    // MARK: - No synthetic rows (focused)

    func testSortedInjectsNothing() {
        // Empty in → empty out (no factory backfill).
        XCTAssertTrue(PinnedChats.sorted([]).isEmpty)
        XCTAssertTrue(PinnedChats.sorted([], pins: ["8:a"]).isEmpty)
        // Output ids are always a subset of the input ids — no
        // injected rows, whatever the pin list claims.
        let chats = [
            Self.chat(id: "8:a", name: "A"),
            Self.chat(id: "8:b", name: "B"),
        ]
        for pins in [[], ["8:b"], ["8:gone", "8:b"], ["  ", "8:b", "8:b"]] {
            let out = PinnedChats.sorted(chats, pins: pins)
            XCTAssertEqual(Set(out.map(\.id)), ["8:a", "8:b"])
            XCTAssertFalse(out.contains { $0.id.hasPrefix("om-") })
        }
    }

    func testDisplayChatsHasNoSyntheticRows() async {
        let model = ChatListViewModel(fetcher: { _ in
            Self.response([
                Self.chat(id: "8:a", name: "A"),
                Self.chat(id: "8:b", name: "B"),
                Self.chat(id: "8:c", name: "C"),
            ])
        })
        await model.load()
        XCTAssertEqual(model.displayChats.map(\.id), ["8:a", "8:b", "8:c"])
        XCTAssertFalse(model.displayChats.contains { $0.id.hasPrefix("om-") })
        // Bubbling + batch churn never inject rows either.
        model.ingest(realtime: Self.live(chat: "8:c"))
        model.ingest(batch: [Self.live(chat: "8:a")])
        XCTAssertEqual(Set(model.displayChats.map(\.id)), ["8:a", "8:b", "8:c"])
        XCTAssertFalse(model.displayChats.contains { $0.id.hasPrefix("om-") })
    }

    func testRealThreadsNamedMentionsOrNotificationsStayInRecency() {
        // No slot promotion, no collapse: same-named real threads are
        // ordinary rows in recency position.
        let out = PinnedChats.sorted([
            Self.chat(id: "8:a", name: "A"),
            Self.chat(id: "19:notify@thread.v2", name: "Notifications"),
            Self.chat(id: "8:m", name: "  MENTIONS "),
        ])
        XCTAssertEqual(out.map(\.id), ["8:a", "19:notify@thread.v2", "8:m"])
        XCTAssertEqual(PinnedChats.sorted(out), out)
    }

    func testStaleSyntheticSelectionDropsOnLoad() async {
        // A persisted pre-removal synthetic selection clears on load
        // (unknown ids never survive — SelectionRestore falls back to
        // the first chat at launch).
        let model = ChatListViewModel(fetcher: { _ in
            Self.response([Self.chat(id: "8:a", name: "A")])
        })
        model.selectedChatID = "om-synthetic-mentions"
        await model.load()
        XCTAssertNil(model.selectedChatID)
        XCTAssertNil(model.selectedChat)
    }

    // MARK: - Sort invariant

    func testSortedPinsOrderThenRecency() {
        let b = Self.chat(id: "8:b", name: "B")
        let a = Self.chat(id: "8:a", name: "A")
        XCTAssertEqual(PinnedChats.sorted([b, a]).map(\.id), ["8:b", "8:a"])
        // Input order (recency) passes through untouched.
        XCTAssertEqual(PinnedChats.sorted([a, b]).map(\.id), ["8:a", "8:b"])
    }

    func testSortedEmptyYieldsEmpty() {
        XCTAssertTrue(PinnedChats.sorted([]).isEmpty)
    }

    func testSortedIdempotentAndDedupes() {
        let input = [
            Self.chat(id: "8:b", name: "B"),
            Self.chat(id: "8:b", name: "B-dup"),
            Self.chat(id: "8:a", name: "A"),
        ]
        let once = PinnedChats.sorted(input)
        XCTAssertEqual(once.map(\.id), ["8:b", "8:a"])
        // First occurrence wins.
        XCTAssertEqual(once[0].last_message_preview, "hi")
        XCTAssertEqual(PinnedChats.sorted(once), once)
    }

    // MARK: - ViewModel projection

    func testDisplayChatsAfterLoad() async {
        let model = ChatListViewModel(fetcher: { _ in
            Self.response([
                Self.chat(id: "8:a", name: "A"),
                Self.chat(id: "8:b", name: "B"),
            ])
        })
        await model.load()
        XCTAssertEqual(model.state, .loaded)
        // Stored rows stay recency-ordered (existing contract).
        XCTAssertEqual(model.chats.map(\.id), ["8:a", "8:b"])
        XCTAssertEqual(model.displayChats.map(\.id), ["8:a", "8:b"])
    }

    func testOrderSurvivesReorder() async {
        let model = ChatListViewModel(fetcher: { _ in
            Self.response([
                Self.chat(id: "8:a", name: "A"),
                Self.chat(id: "8:b", name: "B"),
            ])
        })
        await model.load()
        model.ingest(realtime: Self.live(chat: "8:b"))
        XCTAssertEqual(model.chats.map(\.id), ["8:b", "8:a"])
        XCTAssertEqual(model.displayChats.map(\.id), ["8:b", "8:a"])
    }

    func testOrderSurvivesBatchIngest() async {
        let model = ChatListViewModel(fetcher: { _ in DemoData.churnChatsResponse() })
        await model.load()
        model.ingest(batch: DemoData.churnBurst())
        XCTAssertEqual(
            model.displayChats.map(\.id),
            [DemoData.churnSyncID, DemoData.churnMeetingID,
             DemoData.churnPollyID, DemoData.churnStandupID])
    }

    // MARK: - Filter-clear + restart

    func testOrderSurvivesFilterClear() async {
        let model = ChatListViewModel(fetcher: { _ in
            Self.response([
                Self.chat(id: "8:a", name: "Alice"),
                Self.chat(id: "8:b", name: "Bob"),
            ])
        })
        await model.load()
        let full = model.displayChats
        XCTAssertTrue(ChatListFormat.filter(full, query: "zzz").isEmpty)
        XCTAssertEqual(
            ChatListFormat.filter(full, query: "bob").map(\.id), ["8:b"])
        // Clearing the filter restores the order.
        XCTAssertEqual(ChatListFormat.filter(full, query: ""), full)
        XCTAssertEqual(ChatListFormat.filter(full, query: "   "), full)
    }

    func testOrderSurvivesRestartRestore() async {
        func makeModel() -> ChatListViewModel {
            ChatListViewModel(fetcher: { _ in
                Self.response([
                    Self.chat(id: "8:a", name: "A"),
                    Self.chat(id: "8:b", name: "B"),
                ])
            })
        }
        let first = makeModel()
        await first.load()
        first.ingest(realtime: Self.live(chat: "8:b"))
        let before = first.displayChats.map(\.id)
        // Restart = a fresh instance over the same fetch: same order.
        let second = makeModel()
        await second.load()
        second.ingest(realtime: Self.live(chat: "8:b"))
        XCTAssertEqual(second.displayChats.map(\.id), before)
        XCTAssertEqual(before, ["8:b", "8:a"])
    }

    // MARK: - Unread counts preserved

    func testUnreadCountsPreservedAcrossReorder() async {
        let dock = FakeDockBadge()
        let unread = UnreadStore(dock: dock)
        unread.ingest(
            decision: .notify(reason: "owner-mention"),
            chatID: "8:a", openChatID: nil)
        unread.ingest(
            decision: .notify(reason: "chat-message"),
            chatID: "8:b", openChatID: nil)
        let model = ChatListViewModel(fetcher: { _ in
            Self.response([
                Self.chat(id: "8:a", name: "A"),
                Self.chat(id: "8:b", name: "B"),
            ])
        })
        await model.load()
        // Reorder + batch churn never touch the counts.
        model.ingest(realtime: Self.live(chat: "8:b"))
        model.ingest(batch: [Self.live(chat: "8:a"), Self.live(chat: "8:b")])
        XCTAssertEqual(unread.count(for: "8:a"), 1)
        XCTAssertEqual(unread.count(for: "8:b"), 1)
        XCTAssertEqual(unread.total, 2)
        XCTAssertEqual(model.displayChats.map(\.id), ["8:b", "8:a"])
    }

    func testEmptyFetchKeepsExistingContract() async {
        let model = ChatListViewModel(fetcher: { _ in Self.response([]) })
        await model.load()
        XCTAssertEqual(model.state, .empty)
        XCTAssertTrue(model.chats.isEmpty)
        XCTAssertTrue(model.displayChats.isEmpty)
    }

    // MARK: - User pins

    nonisolated func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-userpins-\(UUID().uuidString)") ?? .standard
    }

    func testIsPinnable() {
        XCTAssertTrue(PinnedChats.isPinnable("8:a"))
        XCTAssertTrue(PinnedChats.isPinnable("19:meeting@thread.v2"))
        XCTAssertFalse(PinnedChats.isPinnable(""))
        XCTAssertFalse(PinnedChats.isPinnable("   "))
    }

    func testUserPinsSitAboveRecency() {
        let out = PinnedChats.sorted(
            [
                Self.chat(id: "8:a", name: "A"),
                Self.chat(id: "8:b", name: "B"),
                Self.chat(id: "8:c", name: "C"),
            ],
            pins: ["8:b"])
        XCTAssertEqual(out.map(\.id), ["8:b", "8:a", "8:c"])
    }

    func testPinTimeOrderOldestFirst() {
        let chats = [
            Self.chat(id: "8:a", name: "A"),
            Self.chat(id: "8:b", name: "B"),
            Self.chat(id: "8:c", name: "C"),
        ]
        // Pin c first, then a: the oldest pin leads the section.
        let out = PinnedChats.sorted(chats, pins: ["8:c", "8:a"])
        XCTAssertEqual(out.map(\.id), ["8:c", "8:a", "8:b"])
    }

    func testPinUnknownIDsDontRender() {
        let out = PinnedChats.sorted(
            [
                Self.chat(id: "8:a", name: "A"),
                Self.chat(id: "8:b", name: "B"),
            ],
            pins: ["8:gone", "8:a"])
        // Unknown ids skip rendering; the rest keep recency order.
        XCTAssertEqual(out.map(\.id), ["8:a", "8:b"])
    }

    func testPinBlankAndDuplicateIDsSkipped() {
        let out = PinnedChats.sorted(
            [
                Self.chat(id: "8:a", name: "A"),
                Self.chat(id: "8:b", name: "B"),
            ],
            pins: ["  ", "8:a", "", "8:a"])
        XCTAssertEqual(out.map(\.id), ["8:a", "8:b"])
    }

    func testSortedWithPinsIdempotent() {
        let input = [
            Self.chat(id: "8:b", name: "B"),
            Self.chat(id: "8:a", name: "A"),
            Self.chat(id: "8:c", name: "C"),
        ]
        let once = PinnedChats.sorted(input, pins: ["8:c", "8:gone"])
        XCTAssertEqual(once.map(\.id), ["8:c", "8:b", "8:a"])
        XCTAssertEqual(PinnedChats.sorted(once, pins: ["8:c", "8:gone"]), once)
    }

    func testPinUnpinViaModel() async {
        let model = ChatListViewModel(
            fetcher: { _ in
                Self.response([
                    Self.chat(id: "8:a", name: "A"),
                    Self.chat(id: "8:b", name: "B"),
                    Self.chat(id: "8:c", name: "C"),
                ])
            },
            pins: UserPinStore(defaults: isolatedDefaults()))
        await model.load()
        XCTAssertFalse(model.isPinned("8:b"))
        model.pin("8:b")
        XCTAssertTrue(model.isPinned("8:b"))
        XCTAssertEqual(model.displayChats.map(\.id), ["8:b", "8:a", "8:c"])
        // Stored rows stay recency-ordered (existing contract).
        XCTAssertEqual(model.chats.map(\.id), ["8:a", "8:b", "8:c"])
        model.pin("8:c")
        XCTAssertEqual(model.displayChats.map(\.id), ["8:b", "8:c", "8:a"])
        model.unpin("8:b")
        XCTAssertFalse(model.isPinned("8:b"))
        // Unpinned rows return to recency order.
        XCTAssertEqual(model.displayChats.map(\.id), ["8:c", "8:a", "8:b"])
        model.unpin("8:unknown")
        XCTAssertEqual(model.pins.count, 1)
    }

    func testPinBlankIsNoop() async {
        let model = ChatListViewModel(
            fetcher: { _ in
                Self.response([Self.chat(id: "8:a", name: "A")])
            },
            pins: UserPinStore(defaults: isolatedDefaults()))
        await model.load()
        let before = model.displayChats
        model.pin("")
        model.pin("   ")
        XCTAssertEqual(model.pins.count, 0)
        XCTAssertEqual(model.displayChats, before)
    }

    func testPinSurvivesIngestOrder() async {
        let model = ChatListViewModel(
            fetcher: { _ in
                Self.response([
                    Self.chat(id: "8:a", name: "A"),
                    Self.chat(id: "8:b", name: "B"),
                    Self.chat(id: "8:c", name: "C"),
                ])
            },
            pins: UserPinStore(defaults: isolatedDefaults()))
        await model.load()
        model.pin("8:b")
        // Bubbled recency never jumps above the pinned section.
        model.ingest(realtime: Self.live(chat: "8:c"))
        XCTAssertEqual(model.chats.map(\.id), ["8:c", "8:a", "8:b"])
        XCTAssertEqual(model.displayChats.map(\.id), ["8:b", "8:c", "8:a"])
        // Live text on the pinned row refreshes its preview in place
        // without moving the pinned section.
        model.ingest(realtime: Self.live(chat: "8:b", text: "pinned hello"))
        XCTAssertEqual(model.displayChats.map(\.id), ["8:b", "8:c", "8:a"])
        XCTAssertEqual(model.displayChats[0].last_message_preview, "pinned hello")
    }

    func testPinsPersistAcrossStores() {
        let defaults = isolatedDefaults()
        let first = UserPinStore(defaults: defaults)
        first.pin("8:b")
        first.pin("8:a")
        XCTAssertEqual(first.orderedIDs, ["8:b", "8:a"])
        let second = UserPinStore(defaults: defaults)
        XCTAssertEqual(second.orderedIDs, ["8:b", "8:a"])
        XCTAssertTrue(second.isPinned("8:b"))
        XCTAssertEqual(second.count, 2)
        second.unpin("8:b")
        let third = UserPinStore(defaults: defaults)
        XCTAssertEqual(third.orderedIDs, ["8:a"])
    }

    func testPinsRestoreIntoDisplayAfterRestart() async {
        let defaults = isolatedDefaults()
        UserPinStore(defaults: defaults).pin("8:b")
        // Restart = a fresh model over the persisted store.
        let model = ChatListViewModel(
            fetcher: { _ in
                Self.response([
                    Self.chat(id: "8:a", name: "A"),
                    Self.chat(id: "8:b", name: "B"),
                ])
            },
            pins: UserPinStore(defaults: defaults))
        await model.load()
        XCTAssertEqual(model.displayChats.map(\.id), ["8:b", "8:a"])
    }

    func testStoreSanitizesOnLoad() {
        let defaults = isolatedDefaults()
        defaults.set(
            ["  ", "8:b", "8:b", "", "8:a"],
            forKey: UserPinStore.defaultsKey)
        let store = UserPinStore(defaults: defaults)
        XCTAssertEqual(store.orderedIDs, ["8:b", "8:a"])
    }

    func testRepinKeepsPinTime() {
        let store = UserPinStore(defaults: isolatedDefaults())
        store.pin("8:b")
        store.pin("8:a")
        store.pin("8:b")
        XCTAssertEqual(store.orderedIDs, ["8:b", "8:a"])
    }
}
