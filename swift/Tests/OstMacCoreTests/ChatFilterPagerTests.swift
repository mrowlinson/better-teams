import XCTest
@testable import OstMacCore

/// Test clock: time moves only on `advance`.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by d: Duration) -> Instant { Instant(offset: offset + d) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [(Instant, CheckedContinuation<Void, Never>)] = []

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if deadline <= current {
                lock.unlock()
                c.resume()
                return
            }
            sleepers.append((deadline, c))
            lock.unlock()
        }
    }

    func advance(by d: Duration) {
        lock.lock()
        current = current.advanced(by: d)
        let now = current
        let due = sleepers.filter { $0.0 <= now }
        sleepers.removeAll { $0.0 <= now }
        lock.unlock()
        due.forEach { $0.1.resume() }
    }
}

/// Chat list filter look-back: bounded (pages, matches, clock timeout),
/// always terminal, never the whole history.
@MainActor
final class ChatFilterPagerTests: XCTestCase {
    /// Real-time wait for async hops (GCD page fetch → main actor).
    private func eventually(_ what: String, _ cond: () -> Bool) async {
        await TestWait.until(interval: 0.005, cond)
        XCTAssertTrue(cond(), what)
    }

    /// Endless history: every page links to another (the live account
    /// has 14+ pages, each seconds long).
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.withLock { n += 1; return n } }
        var count: Int { lock.withLock { n } }
    }

    private func endlessList(_ calls: Counter) -> ChatListViewModel {
        ChatListViewModel(
            fetcher: { _ in ChatsResponse(ok: true, chats: [self.chatSync("a", 50)], next_link: "p1") },
            pageFetcher: { _ in
                let n = calls.next()
                return ChatsResponse(ok: true, chats: [self.chatSync("old\(n)", 40 - n)], next_link: "p\(n + 1)")
            })
    }

    nonisolated private func chatSync(_ id: String, _ minute: Int) -> ChatItem {
        ChatItem(
            chatId: id, name: "Chat \(id)", is_group: true,
            last_message_time: String(format: "2026-09-28T08:%02d:00.000Z", minute),
            last_message_sender: nil, last_message_preview: "hi")
    }

    func testStopsAfterMaxPagesInsteadOfWalkingTheWholeHistory() async {
        let calls = Counter()
        let vm = endlessList(calls)
        await vm.load()
        let pager = ChatFilterPager(maxPages: 2, timeout: .seconds(10), clock: ManualClock())
        pager.start(vm) { 0 }
        XCTAssertEqual(pager.phase, .searching)
        await eventually("finished after 2 pages") { pager.phase == .finished }
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(pager.pagesFetched, 2)
        XCTAssertTrue(vm.hasMore, "older chats remain for Check Older Chats")
        XCTAssertFalse(vm.isLoadingMore)
        // Another bounded look: two more pages, then terminal again.
        pager.start(vm) { 0 }
        await eventually("second look finished") { pager.phase == .finished }
        XCTAssertEqual(calls.count, 4)
    }

    func testPageThatNeverReturnsStillEndsAtTheTimeout() async {
        let gate = DispatchSemaphore(value: 0)
        let vm = ChatListViewModel(
            fetcher: { _ in ChatsResponse(ok: true, chats: [self.chatSync("a", 50)], next_link: "p1") },
            pageFetcher: { _ in
                gate.wait()
                return ChatsResponse(ok: true, chats: [], next_link: nil)
            })
        addTeardownBlock { gate.signal() }
        await vm.load()
        let clock = ManualClock()
        let pager = ChatFilterPager(maxPages: 2, timeout: .seconds(10), clock: clock)
        pager.start(vm) { 0 }
        await eventually("timeout armed") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(9))
        await Task.yield()
        XCTAssertEqual(pager.phase, .searching, "within the budget")
        clock.advance(by: .seconds(1))
        await eventually("terminal at 10 s with the page still out") { pager.phase == .finished }
        XCTAssertTrue(vm.isLoadingMore, "control: the page really is still in flight")
    }

    func testEnoughMatchesOrNoOlderChatsFinishAtOnce() async {
        let calls = Counter()
        let vm = endlessList(calls)
        await vm.load()
        let pager = ChatFilterPager(maxPages: 2, target: 1, clock: ManualClock())
        pager.start(vm) { 1 }
        XCTAssertEqual(pager.phase, .finished)
        XCTAssertEqual(calls.count, 0)

        let done = ChatListViewModel(
            fetcher: { _ in ChatsResponse(ok: true, chats: [self.chatSync("a", 50)], next_link: nil) },
            pageFetcher: { _ in XCTFail("no page to fetch"); return ChatsResponse(ok: true, chats: [], next_link: nil) })
        await done.load()
        pager.start(done) { 0 }
        XCTAssertEqual(pager.phase, .finished)
    }

    func testFailedPageEndsTheSearch() async {
        struct Boom: Error {}
        let calls = Counter()
        let vm = ChatListViewModel(
            fetcher: { _ in ChatsResponse(ok: true, chats: [self.chatSync("a", 50)], next_link: "p1") },
            pageFetcher: { _ in _ = calls.next(); throw Boom() })
        await vm.load()
        let pager = ChatFilterPager(maxPages: 3, clock: ManualClock())
        pager.start(vm) { 0 }
        await eventually("terminal after the failure") { pager.phase == .finished }
        XCTAssertEqual(calls.count, 1, "no retry loop")
        XCTAssertTrue(vm.hasMore, "link kept")
    }

    func testCancelGoesIdleAndALatePageDoesNotRevive() async {
        let gate = DispatchSemaphore(value: 0)
        let vm = ChatListViewModel(
            fetcher: { _ in ChatsResponse(ok: true, chats: [self.chatSync("a", 50)], next_link: "p1") },
            pageFetcher: { _ in
                gate.wait()
                return ChatsResponse(ok: true, chats: [self.chatSync("b", 10)], next_link: "p2")
            })
        await vm.load()
        let pager = ChatFilterPager(maxPages: 2, clock: ManualClock())
        pager.start(vm) { 0 }
        await eventually("page in flight") { vm.isLoadingMore }
        pager.cancel()
        XCTAssertEqual(pager.phase, .idle)
        gate.signal()
        await eventually("late page landed") { vm.chats.count == 2 }
        await Task.yield()
        XCTAssertEqual(pager.phase, .idle)
        XCTAssertEqual(pager.pagesFetched, 0)
    }
}
