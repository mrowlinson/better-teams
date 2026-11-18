// LaunchPaintGuardTests.swift — launch-perf: usable paint must not wait on network.
//
// Regression: content.open/startup.done fired 4-6s after launch (cold
// AND warm), gated on `await chats.load()` + requestAuthorization +
// feed.start, while the cached paint landed in ~0.3s and the restored
// chat opened only at the very end (chat.first-open == content.open).
// The paint phase restores snapshots, selects + opens from cache, and
// marks content.open synchronously — network revalidation and live
// wiring continue behind the mark. Target: launch to usable <2s.
import XCTest

@testable import OstMacCore

@MainActor
final class LaunchPaintGuardTests: XCTestCase {
    /// Cached rows + explicit selection: paint restores, selects, and
    /// marks content.open with zero network. The helper is synchronous,
    /// so the type system forbids awaiting a fetch on this path.
    func testCachedPaintMarksOpenWithoutNetwork() {
        ColdStart.reset()
        defer { RichMediaCache.memoryOnly = false } // process-global (demo flips it)
        let row = DemoData.chats[0]
        let app = AppState(args: ["--demo", "--chat", row.id])
        let cache = SectionCache.memoryOnly()
        cache.save(DemoData.chats, key: ChatListViewModel.snapshotKey)
        app.chats.snapshots = cache
        ColdStart.arm()
        XCTAssertTrue(app.paintCachedContent())
        XCTAssertTrue(ColdStart.hasMarked("content.cached"))
        XCTAssertTrue(ColdStart.hasMarked("content.open"), "usable mark must not wait for network")
        let ms = ColdStart.elapsedMs() ?? -1
        XCTAssertLessThan(ms, 2000, "launch-to-usable target <2s (paint phase)")
        XCTAssertEqual(app.chats.selectedChatID, row.id)
    }

    /// The open follows through the selection sink from the cached rows.
    func testCachedPaintOpensChatFromCache() async throws {
        ColdStart.reset()
        defer { RichMediaCache.memoryOnly = false } // process-global (demo flips it)
        let row = DemoData.chats[0]
        let app = AppState(args: ["--demo", "--chat", row.id])
        let cache = SectionCache.memoryOnly()
        cache.save(DemoData.chats, key: ChatListViewModel.snapshotKey)
        app.chats.snapshots = cache
        ColdStart.arm()
        XCTAssertTrue(app.paintCachedContent())
        var opened = false
        for _ in 0..<200 where !opened {
            try? await Task.sleep(nanoseconds: 5_000_000)
            opened = ColdStart.hasMarked("chat.first-open")
        }
        XCTAssertTrue(opened, "restored chat must open from cache")
        XCTAssertEqual(app.openChatID, row.id)
    }

    /// No cache (first launch): paint selects nothing and marks nothing;
    /// the caller awaits the fresh list first (honest slow path, never a
    /// fake mark).
    func testEmptyCachePaintsNothing() {
        ColdStart.reset()
        defer { RichMediaCache.memoryOnly = false } // process-global (demo flips it)
        let app = AppState(args: ["--demo", "--chat", DemoData.chats[0].id])
        ColdStart.arm()
        XCTAssertFalse(app.paintCachedContent())
        XCTAssertFalse(ColdStart.hasMarked("content.open"))
    }
}
