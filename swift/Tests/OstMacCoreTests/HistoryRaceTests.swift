// HistoryRaceTests.swift — CHATPOLISH: reopening a stale (>1 page)
// snapshot and scrolling to the top before the fresh page lands must
// not put the snapshot's older page in front of the fresh page (gap).
import Foundation
import XCTest

@testable import OstMacCore

/// whoami waits on `gate`, so the older-page call (from `loadMore`) is
/// deterministically call 1 and the open's fresh page call 2.
private final class GatedRunner: AccountCoreRunner, @unchecked Sendable {
    struct Fail: Error {}
    let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    var pageCalls: Int { lock.withLock { calls } }
    private var done = 0
    /// Page calls whose result has been handed back to the store.
    var finishedCalls: Int { lock.withLock { done } }

    private func page(_ ids: [String], token: String?) -> MessagesResponse {
        MessagesResponse(ok: true, chat_id: "c",
                         messages: ids.map { ChatMessage(id: $0, sender: "Pat", timestamp: "2020-01-01T00:00:00Z",
                                                         content: "x") },
                         page_token: token)
    }

    func run<T>(_ op: () throws -> T, accountID: String?) throws -> T {
        if T.self == String.self {
            gate.wait()
            return "Me" as! T
        }
        guard T.self == MessagesResponse.self else { throw Fail() }
        let n = lock.withLock { calls += 1; return calls }
        switch n {
        case 1: // loadMore from the snapshot cursor: slow, lands last
            Thread.sleep(forTimeInterval: 0.3)
            lock.withLock { done += 1 }
            return page(["old1", "old2"], token: "tokOlder") as! T
        case 2: // the open's fresh newest page: not contiguous with the snapshot
            lock.withLock { done += 1 }
            return page(["m9", "m10"], token: "tokF") as! T
        default: // never: the fresh page covers the (old-stamped) window
            return page([], token: nil) as! T
        }
    }
}

@MainActor
final class HistoryRaceTests: XCTestCase {
    func testOlderPageFromStaleSnapshotCursorIsDroppedAfterFreshPage() async throws {
        let cache = MessageHistoryCache.memoryOnly()
        cache.store(chatID: "c", messages: [msg("m1"), msg("m2")], pageToken: "tokC")
        let runner = GatedRunner()
        let s = ConversationStore()
        s.coreRunner = runner
        s.historyCache = cache
        s.open(chatID: "c")
        XCTAssertEqual(s.messages.map(\.id), ["m1", "m2"]) // snapshot painted
        s.loadMore() // scrolled to the top at once
        XCTAssertTrue(s.loadingMore)
        let started = await TestWait.until(interval: 0.002) { runner.pageCalls >= 1 }
        XCTAssertTrue(started, "loadMore never reached the core")
        runner.gate.signal() // now the open proceeds to its fresh page
        let drained = await TestWait.until(interval: 0.005) {
            !(s.refreshing || s.loadingMore || runner.pageCalls < 2)
        }
        XCTAssertTrue(drained, "open + loadMore never drained")
        // The slow older page lands: both page calls have handed their
        // result back; then drain the main-actor hops that apply them.
        let landed = await TestWait.until { runner.finishedCalls >= 2 }
        XCTAssertTrue(landed, "slow older page never returned")
        for _ in 0 ..< 200 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 200_000_000) // negative window: a stale page must NOT land; yields alone are microseconds
        XCTAssertEqual(s.messages.map(\.id), ["m9", "m10"], "no snapshot-older page before the fresh page")
        XCTAssertEqual(s.pageToken, "tokF") // the fresh cursor, not the dropped page's
        XCTAssertFalse(s.loadingMore)
    }

    private func msg(_ id: String) -> ChatMessage {
        ChatMessage(id: id, sender: "Pat", timestamp: "2020-01-01T00:00:00Z", content: "x")
    }
}
