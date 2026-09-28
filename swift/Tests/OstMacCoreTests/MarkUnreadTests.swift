// MarkUnreadTests — om-markunread: horizon overrides, badge math, open-clears.
import XCTest

@testable import OstMacCore

@MainActor
final class MarkUnreadTests: XCTestCase {
    func store() -> (UnreadStore, FakeDockBadge) {
        let dock = FakeDockBadge()
        return (UnreadStore(dock: dock), dock)
    }

    // MARK: pure badge math

    func testVisibleCountPure() {
        XCTAssertEqual(UnreadStore.visibleCount(auto: 0, overridden: false), 0)
        XCTAssertEqual(UnreadStore.visibleCount(auto: 3, overridden: false), 3)
        XCTAssertEqual(UnreadStore.visibleCount(auto: 0, overridden: true), 1)
        XCTAssertEqual(UnreadStore.visibleCount(auto: 1, overridden: true), 1)
        XCTAssertEqual(UnreadStore.visibleCount(auto: 4, overridden: true), 4)
    }

    func testVisibleTotalPure() {
        XCTAssertEqual(
            UnreadStore.visibleTotal(counts: [:], overrides: []), 0)
        XCTAssertEqual(
            UnreadStore.visibleTotal(counts: ["a": 2], overrides: []), 2)
        XCTAssertEqual(
            UnreadStore.visibleTotal(counts: [:], overrides: ["a"]), 1)
        XCTAssertEqual(
            UnreadStore.visibleTotal(counts: ["a": 2], overrides: ["a"]), 2)
        XCTAssertEqual(
            UnreadStore.visibleTotal(counts: ["a": 2], overrides: ["b"]), 3)
    }

    func testVisibleChatsPure() {
        XCTAssertEqual(
            UnreadStore.visibleChats(counts: [:], overrides: []), 0)
        XCTAssertEqual(
            UnreadStore.visibleChats(counts: ["a": 2], overrides: []), 1)
        XCTAssertEqual(
            UnreadStore.visibleChats(counts: [:], overrides: ["a"]), 1)
        XCTAssertEqual(
            UnreadStore.visibleChats(counts: ["a": 2], overrides: ["a"]), 1)
        XCTAssertEqual(
            UnreadStore.visibleChats(counts: ["a": 2], overrides: ["b"]), 2)
    }

    // MARK: override set

    func testMarkUnreadSetsOverrideAndBadge() {
        let (s, dock) = store()
        s.markUnread(chatID: "a")
        XCTAssertTrue(s.isOverridden(chatID: "a"))
        XCTAssertTrue(s.isUnread(chatID: "a"))
        XCTAssertEqual(s.count(for: "a"), 1)
        XCTAssertEqual(s.total, 1)
        XCTAssertEqual(s.chatCount, 1)
        XCTAssertEqual(s.badgeLabel, "1")
        XCTAssertEqual(dock.labels, ["1"])
        XCTAssertFalse(s.isUnread(chatID: "b"))
    }

    func testMarkUnreadBlankIsNoop() {
        let (s, dock) = store()
        s.markUnread(chatID: "  ")
        s.markUnread(chatID: "")
        XCTAssertEqual(s.total, 0)
        XCTAssertTrue(s.overrides.isEmpty)
        XCTAssertTrue(dock.labels.isEmpty)
    }

    func testMarkUnreadTwiceWritesDockOnce() {
        let (s, dock) = store()
        s.markUnread(chatID: "a")
        s.markUnread(chatID: "a")
        XCTAssertEqual(s.count(for: "a"), 1)
        XCTAssertEqual(dock.labels, ["1"])
    }

    func testMarkUnreadTrimsID() {
        let (s, dock) = store()
        s.markUnread(chatID: "  a  ")
        XCTAssertTrue(s.isOverridden(chatID: "a"))
        XCTAssertEqual(dock.labels, ["1"])
    }

    /// Marking an already-unread thread still records the override
    /// (one open clears everything) but the visible total is unchanged,
    /// so the dock stays quiet.
    func testMarkUnreadOnUnreadThreadRecordsQuietly() {
        let (s, dock) = store()
        s.ingest(decision: .notify(reason: "x"), chatID: "a", openChatID: nil)
        s.ingest(decision: .notify(reason: "x"), chatID: "a", openChatID: nil)
        s.markUnread(chatID: "a")
        XCTAssertTrue(s.isOverridden(chatID: "a"))
        XCTAssertEqual(s.count(for: "a"), 2)
        XCTAssertEqual(s.total, 2)
        XCTAssertEqual(dock.labels, ["1", "2"])
    }

    /// The override absorbs the first auto point: mark-unread then one
    /// live message still shows 1 (not 2); the second counts past it.
    func testOverrideAbsorbsFirstAutoPoint() {
        let (s, dock) = store()
        s.markUnread(chatID: "a")
        s.ingest(decision: .notify(reason: "x"), chatID: "a", openChatID: nil)
        XCTAssertEqual(s.count(for: "a"), 1)
        XCTAssertEqual(s.total, 1)
        XCTAssertEqual(dock.labels, ["1"])
        s.ingest(decision: .notify(reason: "x"), chatID: "a", openChatID: nil)
        XCTAssertEqual(s.count(for: "a"), 2)
        XCTAssertEqual(s.total, 2)
        XCTAssertEqual(dock.labels, ["1", "2"])
    }

    // MARK: override clear + open-clears

    /// The open path (AppState.open → unread.markRead) clears the
    /// override: one open, badge gone.
    func testOpenClearsOverride() {
        let (s, dock) = store()
        s.markUnread(chatID: "a")
        s.markRead(chatID: "a") // what opening the thread calls
        XCTAssertFalse(s.isOverridden(chatID: "a"))
        XCTAssertFalse(s.isUnread(chatID: "a"))
        XCTAssertEqual(s.total, 0)
        XCTAssertEqual(s.chatCount, 0)
        XCTAssertNil(s.badgeLabel)
        XCTAssertEqual(dock.labels, ["1", nil])
        // Unknown id: no dock write.
        let n = dock.labels.count
        s.markRead(chatID: "zzz")
        XCTAssertEqual(dock.labels.count, n)
    }

    /// One open clears counts and overrides together with one dock write.
    func testMarkReadClearsCountAndOverrideTogether() {
        let (s, dock) = store()
        s.ingest(decision: .notify(reason: "x"), chatID: "a", openChatID: nil)
        s.ingest(decision: .notify(reason: "x"), chatID: "a", openChatID: nil)
        s.markUnread(chatID: "a")
        s.markRead(chatID: "a")
        XCTAssertEqual(s.count(for: "a"), 0)
        XCTAssertFalse(s.isOverridden(chatID: "a"))
        XCTAssertEqual(s.total, 0)
        XCTAssertEqual(dock.labels, ["1", "2", nil])
    }

    func testMarkAllReadClearsOverrides() {
        let (s, dock) = store()
        s.markUnread(chatID: "a")
        s.ingest(decision: .notify(reason: "x"), chatID: "b", openChatID: nil)
        s.markAllRead()
        XCTAssertEqual(s.total, 0)
        XCTAssertEqual(s.chatCount, 0)
        XCTAssertTrue(s.overrides.isEmpty)
        XCTAssertNil(s.badgeLabel)
        XCTAssertEqual(dock.labels, ["1", "2", nil])
        // Empty: no dock write.
        let n = dock.labels.count
        s.markAllRead()
        XCTAssertEqual(dock.labels.count, n)
    }

    // MARK: no-refresh + Diagnostics

    /// Mark-unread never touches the auto counts map (the list rows'
    /// only other input): the badge updates in place via `count(for:)`,
    /// the ChatListViewModel is never involved — no refetch, no reorder.
    func testMarkUnreadLeavesCountsUntouched() {
        let (s, _) = store()
        s.markUnread(chatID: "a")
        XCTAssertTrue(s.counts.isEmpty)
        XCTAssertEqual(s.count(for: "a"), 1)
    }

    func testDiagnosticsLineWithOverrides() {
        let (s, _) = store()
        s.ingest(decision: .notify(reason: "x"), chatID: "a", openChatID: nil)
        s.ingest(decision: .notify(reason: "x"), chatID: "a", openChatID: nil)
        s.markUnread(chatID: "b")
        XCTAssertEqual(
            DiagnosticsFormat.unreadLine(total: s.total, chats: s.chatCount),
            "3 messages · 2 chats")
    }
}
