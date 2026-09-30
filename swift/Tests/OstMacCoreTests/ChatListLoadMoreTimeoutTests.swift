import XCTest
@testable import OstMacCore

/// FIXPACK F9: the full-list footer's older-page read has a deadline and a
/// visible retry state instead of an endless spinner.
@MainActor
final class ChatListLoadMoreTimeoutTests: XCTestCase {
    nonisolated private func item(_ id: String, _ minute: Int) -> ChatItem {
        ChatItem(
            chatId: id, name: "Chat \(id)", is_group: true,
            last_message_time: String(format: "2026-09-28T08:%02d:00.000Z", minute),
            last_message_sender: nil, last_message_preview: "hi")
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var hang = true
        private var calls = 0
        private var returned = false
        /// The hung read parks here until the test releases it (a gate, not a
        /// stopwatch: the deadline must win while the read is still parked).
        let parked = DispatchSemaphore(value: 0)
        var readReturned: Bool { get { lock.withLock { returned } } set { lock.withLock { returned = newValue } } }
        var hanging: Bool { get { lock.withLock { hang } } set { lock.withLock { hang = newValue } } }
        func call() -> Int { lock.withLock { calls += 1; return calls } }
        var count: Int { lock.withLock { calls } }
    }

    func testHungPageFailsAtTheDeadlineThenRetrySucceeds() async {
        let gate = Gate()
        defer { gate.parked.signal() }   // never leave the parked read stuck
        let vm = ChatListViewModel(
            fetcher: { _ in ChatsResponse(ok: true, chats: [self.item("a", 50)], next_link: "p1") },
            pageFetcher: { _ in
                _ = gate.call()
                if gate.hanging { gate.parked.wait(); gate.readReturned = true }
                return ChatsResponse(ok: true, chats: [self.item("old", 10)], next_link: nil)
            })
        vm.pageTimeout = 0.2
        await vm.load()
        await vm.loadMore()
        XCTAssertFalse(gate.readReturned, "returns at the deadline, not when the read ends")
        XCTAssertTrue(vm.loadMoreFailed)
        XCTAssertFalse(vm.isLoadingMore, "no endless spinner")
        XCTAssertEqual(vm.chats.map(\.id), ["a"])
        XCTAssertTrue(vm.hasMore, "the link is kept for the retry")
        // No auto-retry loop while failed.
        await vm.loadMore()
        vm.loadMoreIfNeeded(currentID: "a", in: vm.chats)
        XCTAssertEqual(gate.count, 1)
        // Retry (the read is quick now) pages and clears the state.
        gate.hanging = false
        await vm.retryLoadMore()
        XCTAssertFalse(vm.loadMoreFailed)
        XCTAssertEqual(Set(vm.chats.map(\.id)), ["a", "old"])
        XCTAssertFalse(vm.hasMore)
    }

    func testThrowingPageIsTheSameVisibleFailure() async {
        let vm = ChatListViewModel(
            fetcher: { _ in ChatsResponse(ok: true, chats: [self.item("a", 50)], next_link: "p1") },
            pageFetcher: { _ in throw CoreCallError.failed("HTTP 500") })
        await vm.load()
        await vm.loadMore()
        XCTAssertTrue(vm.loadMoreFailed)
        XCTAssertFalse(vm.isLoadingMore)
    }
}
