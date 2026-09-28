// HistoryLoadTests.swift — histload: cached-first open, bounded newest
// fetch, lazy older pages, cursor fallback, cancel on switch, snapshot
// persistence. Core calls go through a scripted runner (no network).
import Foundation
import XCTest

@testable import OstMacCore

/// Scripted core runner: whoami → "Me"; every messages / messagesPage
/// call pops the next scripted page (after `delay`). Never runs the op.
private final class ScriptedRunner: AccountCoreRunner, @unchecked Sendable {
    struct Fail: Error {}
    private let lock = NSLock()
    private var script: [Result<MessagesResponse, Error>]
    private var calls = 0
    let delay: TimeInterval
    /// Unscripted calls: a fresh 2-message page per call (`cN-a/b`).
    let generate: Bool

    init(_ script: [Result<MessagesResponse, Error>] = [], delay: TimeInterval = 0, generate: Bool = false) {
        self.script = script
        self.delay = delay
        self.generate = generate
    }

    var pageCalls: Int { lock.withLock { calls } }

    func run<T>(_ op: () throws -> T, accountID: String?) throws -> T {
        if T.self == String.self { return "Me" as! T }
        guard T.self == MessagesResponse.self else { throw Fail() }
        let next: Result<MessagesResponse, Error> = lock.withLock {
            calls += 1
            if !script.isEmpty { return script.removeFirst() }
            if generate {
                let n = calls
                return .success(page(["c\(n)-a", "c\(n)-b"], token: "t\(n)"))
            }
            return .success(page([], token: nil))
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return try next.get() as! T
    }
}

private func msg(_ id: String, _ content: String = "x", ts: String = "2020-01-01T00:00:00Z") -> ChatMessage {
    ChatMessage(id: id, sender: "Pat", timestamp: ts, content: content)
}

private func page(_ ids: [String], token: String?, ts: String = "2020-01-01T00:00:00Z") -> MessagesResponse {
    MessagesResponse(ok: true, chat_id: "c", messages: ids.map { msg($0, ts: ts) }, page_token: token)
}

@MainActor
final class HistoryLoadTests: XCTestCase {
    private func store(_ runner: ScriptedRunner, cache: MessageHistoryCache? = .memoryOnly()) -> ConversationStore {
        let s = ConversationStore()
        s.coreRunner = runner
        s.historyCache = cache
        return s
    }

    private func settle(_ s: ConversationStore, _ extra: (() -> Bool)? = nil) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !s.loading, !s.refreshing, !s.loadingMore, extra?() ?? true { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("store never settled")
    }

    // MARK: open

    func testCachedOpenPaintsInstantlyThenMergesNewestPageOnly() async {
        let cache = MessageHistoryCache.memoryOnly()
        cache.store(chatID: "c", messages: [msg("m1"), msg("m2"), msg("m3", "old")], pageToken: "https://x/conversations/c?tokC")
        let runner = ScriptedRunner([.success(MessagesResponse(
            ok: true, chat_id: "c", messages: [msg("m3", "edited"), msg("m4")], page_token: "https://x/conversations/c?tokF"))])
        let s = store(runner, cache: cache)
        s.open(chatID: "c")
        // Painted synchronously: no loading pane, refresh runs behind.
        XCTAssertEqual(s.messages.map(\.id), ["m1", "m2", "m3"])
        XCTAssertFalse(s.loading)
        XCTAssertTrue(s.didLoad)
        XCTAssertTrue(s.refreshing)
        await settle(s)
        XCTAssertEqual(s.messages.map(\.id), ["m1", "m2", "m3", "m4"])
        XCTAssertEqual(s.messages[2].content, "edited")
        XCTAssertEqual(runner.pageCalls, 1, "cached open fetches the newest page only")
        XCTAssertEqual(s.pageToken, "https://x/conversations/c?tokC", "snapshot cursor continues before cached oldest")
        XCTAssertEqual(cache.load(chatID: "c")?.messages.map(\.id), ["m1", "m2", "m3", "m4"])
    }

    func testCachedOpenWithGapReplacesSnapshot() async {
        let cache = MessageHistoryCache.memoryOnly()
        cache.store(chatID: "c", messages: [msg("m1"), msg("m2")], pageToken: "tokC")
        let s = store(ScriptedRunner([.success(page(["m9", "m10"], token: "tokF"))]), cache: cache)
        s.open(chatID: "c")
        await settle(s)
        XCTAssertEqual(s.messages.map(\.id), ["m9", "m10"])
        XCTAssertEqual(s.pageToken, "tokF")
    }

    func testCachedOpenFailureKeepsSnapshotQuietly() async {
        let cache = MessageHistoryCache.memoryOnly()
        cache.store(chatID: "c", messages: [msg("m1")], pageToken: nil)
        let s = store(ScriptedRunner([.failure(ScriptedRunner.Fail())]), cache: cache)
        s.open(chatID: "c")
        await settle(s)
        XCTAssertEqual(s.messages.map(\.id), ["m1"])
        XCTAssertNil(s.error)
        XCTAssertNotNil(s.refreshError)
    }

    func testUncachedOpenStopsAtPageCapNotFullHistory() async {
        // Recent stamps: the 72h window is never covered, so only the
        // page cap stops the chain.
        let now = ISO8601DateFormatter().string(from: Date())
        let runner = ScriptedRunner([
            .success(page(["p1a", "p1b"], token: "t1", ts: now)),
            .success(page(["p2a", "p2b"], token: "t2", ts: now)),
            .success(page(["p3a", "p3b"], token: "t3", ts: now)),
        ])
        let s = store(runner)
        s.open(chatID: "c")
        XCTAssertTrue(s.loading)
        XCTAssertTrue(s.messages.isEmpty)
        await settle(s)
        XCTAssertEqual(runner.pageCalls, ConversationStore.openMaxPages)
        XCTAssertEqual(s.messages.map(\.id), ["p2a", "p2b", "p1a", "p1b"])
        XCTAssertEqual(s.pageToken, "t2")
        XCTAssertTrue(s.canLoadMore)
    }

    func testCachedSeekHitArmsJumpWithoutPaging() async {
        let cache = MessageHistoryCache.memoryOnly()
        cache.store(chatID: "c", messages: [msg("old"), msg("m1")], pageToken: "tokC")
        let runner = ScriptedRunner([.success(page(["m1", "m2"], token: "tokF"))])
        let s = store(runner, cache: cache)
        s.open(chatID: "c", seekMessageID: "old")
        XCTAssertEqual(s.jumpTargetID, "old")
        await settle(s)
        XCTAssertEqual(runner.pageCalls, 1)
    }

    // MARK: lazy older pages

    func testLoadMorePrependsUntilEndOfHistory() async {
        let runner = ScriptedRunner([
            .success(page(["m3", "m4"], token: "t1")),
            .success(MessagesResponse(ok: true, chat_id: "c",
                                      messages: [msg("m1", ts: "2019-12-30T00:00:00Z"), msg("m2", ts: "2019-12-30T00:00:00Z")],
                                      page_token: nil)),
        ])
        let s = store(runner)
        s.open(chatID: "c")
        await settle(s)
        XCTAssertTrue(s.canLoadMore)
        s.loadMore()
        XCTAssertTrue(s.loadingMore)
        await settle(s)
        XCTAssertEqual(s.messages.map(\.id), ["m1", "m2", "m3", "m4"])
        XCTAssertNil(s.pageToken)
        XCTAssertFalse(s.canLoadMore, "end of history stops paging")
    }

    func testStaleSnapshotCursorFallsBackToFreshCursorOnce() async {
        let cache = MessageHistoryCache.memoryOnly()
        cache.store(chatID: "c", messages: [msg("m2"), msg("m3")], pageToken: "stale")
        let runner = ScriptedRunner([
            .success(page(["m3", "m4"], token: "fresh")),
            .failure(ScriptedRunner.Fail()), // stale cursor
            .success(MessagesResponse(ok: true, chat_id: "c",
                                      messages: [msg("m1", ts: "2019-12-30T00:00:00Z"), msg("m2")], page_token: nil)),
        ])
        let s = store(runner, cache: cache)
        s.open(chatID: "c")
        await settle(s)
        s.loadMore()
        await settle(s)
        XCTAssertNil(s.error)
        XCTAssertEqual(s.messages.map(\.id), ["m1", "m2", "m3", "m4"])
    }

    func testSwitchChatDropsInFlightOlderPage() async {
        let runner = ScriptedRunner(delay: 0.05, generate: true)
        let s = store(runner)
        s.open(chatID: "a")
        await settle(s)
        s.loadMore()
        XCTAssertTrue(s.loadingMore)
        s.open(chatID: "b") // leave mid-fetch
        XCTAssertFalse(s.loadingMore)
        await settle(s)
        try? await Task.sleep(nanoseconds: 150_000_000) // let a's page land (dropped)
        let prefixes = Set(s.messages.map { $0.id.split(separator: "-")[0] })
        XCTAssertEqual(prefixes.count, 1, "only b's page, never a's older page: \(s.messages.map(\.id))")
        XCTAssertEqual(s.chatID, "b")
    }

    // MARK: pure merge + snapshot store

    func testMergedFreshKeepsPendingAndFlagsGap() {
        let cached = [msg("m1"), msg("m2"), msg("pending-1")]
        let hit = ConversationStore.mergedFresh([msg("m2", "e"), msg("m3")], into: cached)
        XCTAssertTrue(hit.contiguous)
        XCTAssertEqual(hit.messages.map(\.id), ["m1", "m2", "m3", "pending-1"])
        let gap = ConversationStore.mergedFresh([msg("m8"), msg("m9")], into: cached)
        XCTAssertFalse(gap.contiguous)
        XCTAssertEqual(gap.messages.map(\.id), ["m8", "m9", "pending-1"])
        let empty = ConversationStore.mergedFresh([], into: cached)
        XCTAssertTrue(empty.contiguous)
        XCTAssertEqual(empty.messages, cached)
    }

    func testDiskSnapshotRoundTripsAndTrimsCursor() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("histload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = MessageHistoryCache(directory: dir)
        a.store(chatID: "19:x@thread.v2", messages: [msg("m1"), msg("m2")], pageToken: "tok")
        a.flush()
        let b = MessageHistoryCache(directory: dir)
        let e = try XCTUnwrap(b.load(chatID: "19:x@thread.v2"))
        XCTAssertEqual(e.messages.map(\.id), ["m1", "m2"])
        XCTAssertEqual(e.pageToken, "tok")
        XCTAssertFalse(e.endOfHistory)
        let trimmed = MessageHistoryCache.diskEntry(e, cap: 1)
        XCTAssertEqual(trimmed.messages.map(\.id), ["m2"])
        XCTAssertNil(trimmed.pageToken)
        XCTAssertFalse(trimmed.endOfHistory, "trimmed copy is not end of history")
        XCTAssertNotEqual(MessageHistoryCache.fileName(for: "19:a@thread.v2"),
                          MessageHistoryCache.fileName(for: "19_a@thread.v2"))
        b.removeAll()
        b.flush()
        XCTAssertNil(MessageHistoryCache(directory: dir).load(chatID: "19:x@thread.v2"))
    }

    // MARK: timing (fixture; printed for the lane report)

    func testTimingCachedFirstContentVsFresh() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("histload-t-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rows = (0..<500).map { msg("m\($0)", String(repeating: "word ", count: 30)) }
        let seed = MessageHistoryCache(directory: dir)
        seed.store(chatID: "c", messages: rows, pageToken: "tok")
        seed.flush()
        // Cold disk load (new instance) + a 300 ms simulated network page.
        let runner = ScriptedRunner([.success(MessagesResponse(
            ok: true, chat_id: "c", messages: Array(rows.suffix(49)) + [msg("new")], page_token: "fresh"))],
            delay: 0.3)
        let s = store(runner, cache: MessageHistoryCache(directory: dir))
        let t0 = Date()
        s.open(chatID: "c")
        let first = Date().timeIntervalSince(t0) * 1000
        XCTAssertEqual(s.messages.count, 500)
        await settle(s)
        let fresh = Date().timeIntervalSince(t0) * 1000
        XCTAssertEqual(s.messages.last?.id, "new")
        print(String(format: "HISTLOAD timing: first-content(cached,500 msgs cold disk)=%.1fms fresh(300ms net)=%.1fms", first, fresh))
        XCTAssertLessThan(first, 250)
    }
}
