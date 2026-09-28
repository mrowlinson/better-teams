// FidListsTests.swift — fid-lists lane (D17-D23 + D25): Teams-fidelity
// lists/calls/misc. Exact-copy label pins + muted-unread accrual +
// server-truthful reaction fallback. D21 (ghost copy) has no unit seam
// (OstMac app module, untested target) — pinned by shot + proof quote.
import XCTest

@testable import OstMacCore

/// Core runner that fails every op with a canned verdict (stands in
/// for the server/core without network).
private struct FidThrowRunner: AccountCoreRunner {
    let message: String
    func run<T>(_ op: () throws -> T, accountID: String?) throws -> T {
        throw CoreCallError.failed(message)
    }
}

@MainActor
final class FidListsTests: XCTestCase {
    private func tempPath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fid-\(UUID().uuidString).json").path
    }

    private func unreadStore() -> (UnreadStore, FakeDockBadge) {
        let dock = FakeDockBadge()
        return (UnreadStore(dock: dock), dock)
    }

    /// Live store with chatID but zero network: open fails fast through
    /// the throwing runner (loading flips false, error holds the open
    /// failure). Callers seed bubbles via ingest/applyReactions.
    private func liveStore(failing message: String) async -> ConversationStore {
        let store = ConversationStore()
        store.coreRunner = FidThrowRunner(message: message)
        store.open(chatID: "19:live@thread.v2")
        await waitFor { store.loading == false }
        return store
    }

    // MARK: - D17 mute/unmute level round-trip

    func testMuteUnmuteRoundTrip() {
        let rules = RulesStore(path: tempPath())
        XCTAssertEqual(rules.level(chatID: "c1"), .all)
        rules.setLevel(chatID: "c1", level: .muted) // Mute
        XCTAssertEqual(rules.level(chatID: "c1"), .muted)
        XCTAssertTrue(rules.isMuted(chatID: "c1"))
        rules.setLevel(chatID: "c1", level: .all) // Unmute restores All
        XCTAssertEqual(rules.level(chatID: "c1"), .all)
        XCTAssertFalse(rules.isMuted(chatID: "c1"))
    }

    func testUnmuteRestoresAllNotPrevious() {
        // Documented: Unmute restores All even when the chat was
        // Mentions-only before muting (no previous-level memory).
        let rules = RulesStore(path: tempPath())
        rules.setLevel(chatID: "c1", level: .mentions)
        rules.setLevel(chatID: "c1", level: .muted)
        rules.setLevel(chatID: "c1", level: .all)
        XCTAssertEqual(rules.level(chatID: "c1"), .all)
    }

    // MARK: - exact-copy label pins (D18/D22/D23/D25)

    func testCalendarLabel() {
        XCTAssertEqual(CalendarLabels.newMeeting, "New meeting")
    }

    // MARK: - D19 muted chats accrue row unread, skip the badge

    func testIsMutedSkipMatrix() {
        XCTAssertTrue(UnreadStore.isMutedSkip(.skip(reason: "muted")))
        XCTAssertTrue(UnreadStore.isMutedSkip(.skip(reason: "teams-muted")))
        XCTAssertTrue(UnreadStore.isMutedSkip(.skip(reason: "chat-muted")))
        XCTAssertFalse(UnreadStore.isMutedSkip(.skip(reason: "snoozed")))
        XCTAssertFalse(UnreadStore.isMutedSkip(.skip(reason: "dnd")))
        XCTAssertFalse(UnreadStore.isMutedSkip(.skip(reason: "own-message")))
        XCTAssertFalse(UnreadStore.isMutedSkip(.notify(reason: "chat-message")))
    }

    func testShouldCountMutesButNotOtherSkips() {
        for reason in ["muted", "teams-muted", "chat-muted"] {
            XCTAssertTrue(
                UnreadStore.shouldCount(
                    decision: .skip(reason: reason), chatID: "a", openChatID: nil),
                reason)
            // Open chat never accrues, muted or not.
            XCTAssertFalse(
                UnreadStore.shouldCount(
                    decision: .skip(reason: reason), chatID: "a", openChatID: "a"),
                reason)
        }
        for reason in ["snoozed", "dnd", "quiet", "keyword-block", "own-message", "edit"] {
            XCTAssertFalse(
                UnreadStore.shouldCount(
                    decision: .skip(reason: reason), chatID: "a", openChatID: nil),
                reason)
        }
    }

    func testMutedAccruesRowExcludesBadge() {
        let (s, dock) = unreadStore()
        s.ingest(decision: .skip(reason: "chat-muted"), chatID: "a", openChatID: nil)
        s.ingest(decision: .skip(reason: "chat-muted"), chatID: "a", openChatID: nil)
        XCTAssertEqual(s.count(for: "a"), 2) // row bolds
        XCTAssertEqual(s.total, 0) // badge excludes
        XCTAssertNil(s.badgeLabel)
        XCTAssertTrue(dock.labels.isEmpty) // no dock write
        XCTAssertEqual(s.mutedUnreadIDs, ["a"])
        // Row badges still count muted chats; only the dock excludes.
        XCTAssertEqual(s.chatCount, 1)
    }

    func testMixedMutedAndLoudBadgeCountsLoudOnly() {
        let (s, dock) = unreadStore()
        s.ingest(decision: .skip(reason: "teams-muted"), chatID: "a", openChatID: nil)
        s.ingest(decision: .notify(reason: "chat-message"), chatID: "b", openChatID: nil)
        XCTAssertEqual(s.count(for: "a"), 1)
        XCTAssertEqual(s.count(for: "b"), 1)
        XCTAssertEqual(s.total, 1)
        XCTAssertEqual(s.badgeLabel, "1")
        XCTAssertEqual(dock.labels, ["1"])
    }

    func testNotifyClearsMutedFlag() {
        let (s, dock) = unreadStore()
        s.ingest(decision: .skip(reason: "muted"), chatID: "a", openChatID: nil)
        XCTAssertEqual(s.total, 0)
        // A notify proves the chat is unmuted now: flag drops, the
        // whole row (old muted points included) joins the badge.
        s.ingest(decision: .notify(reason: "chat-message"), chatID: "a", openChatID: nil)
        XCTAssertTrue(s.mutedUnreadIDs.isEmpty)
        XCTAssertEqual(s.count(for: "a"), 2)
        XCTAssertEqual(s.total, 2)
        XCTAssertEqual(dock.labels, ["2"])
    }

    func testMarkReadClearsMutedFlag() {
        let (s, _) = unreadStore()
        s.ingest(decision: .skip(reason: "chat-muted"), chatID: "a", openChatID: nil)
        s.markRead(chatID: "a")
        XCTAssertTrue(s.mutedUnreadIDs.isEmpty)
        XCTAssertEqual(s.count(for: "a"), 0)
        XCTAssertEqual(s.total, 0)
    }

    func testMarkUnreadOnMutedChatStaysOutOfBadge() {
        let (s, dock) = unreadStore()
        s.markUnread(chatID: "a", muted: true)
        XCTAssertEqual(s.count(for: "a"), 1)
        XCTAssertEqual(s.total, 0)
        XCTAssertNil(s.badgeLabel)
        XCTAssertTrue(dock.labels.isEmpty)
    }

    func testVisibleTotalExcludingPure() {
        XCTAssertEqual(
            UnreadStore.visibleTotal(
                counts: ["a": 2, "b": 3], overrides: ["c"], excluding: ["a", "c"]),
            3)
        // Default: nothing excluded (old call shape unchanged).
        XCTAssertEqual(
            UnreadStore.visibleTotal(counts: ["a": 2], overrides: []), 2)
    }

    // MARK: - D20 any-emoji live reactions, server-truthful fallback

    func testQuickSixUnchanged() {
        XCTAssertEqual(
            ConversationStore.reactionEmojis, ["👍", "❤️", "😂", "😮", "😢", "😠"])
    }

    func testExtendedEmojiNotPreRefused() {
        // No client refusal: the optimistic add lands, no error. (The
        // old code set "isn't a Teams reaction" synchronously here.)
        let store = ConversationStore()
        store.ingest(ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "hi"))
        store.react(messageID: "m1", emoji: "🎉")
        XCTAssertEqual(
            store.messages[0].reactions, [ReactionCount(emoji: "🎉", count: 1)])
        XCTAssertNil(store.error)
    }

    func testExtendedReactFailureRevertsWithVerbatimDetail() async {
        let store = await liveStore(failing: "400 reactionType rejected by server")
        store.ingest(ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "hi"))
        store.react(messageID: "m1", emoji: "🎉")
        // Optimistic add first…
        XCTAssertEqual(store.messages[0].reactions.count, 1)
        // …then the verdict reverts it and surfaces verbatim.
        await waitFor { store.error?.contains("react failed") == true }
        XCTAssertTrue(store.messages[0].reactions.isEmpty)
        XCTAssertTrue(store.error?.contains("400 reactionType rejected by server") == true)
        XCTAssertFalse(store.error?.contains("isn't a Teams reaction") == true)
    }

    func testRemoveAbsentBucketIsNoOp() async {
        // No local bucket → no core attempt → no failure, no phantom
        // bucket conjured by the revert path.
        let store = await liveStore(failing: "boom")
        store.ingest(ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "hi"))
        let before = store.error
        store.removeReaction(messageID: "m1", emoji: "🎉")
        store.removeReaction(messageID: "m1", emoji: "👍")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(store.messages[0].reactions.isEmpty)
        XCTAssertEqual(store.error, before)
        XCTAssertFalse(store.error?.contains("react failed") == true)
    }

    func testRemovePresentExtendedAttemptsServer() async {
        // Present extended bucket → live remove attempted; the canned
        // rejection reverts (bucket back) with verbatim detail.
        let store = await liveStore(failing: "400 reactionType rejected by server")
        store.ingest(ChatMessage(id: "m1", sender: "A", timestamp: "t", content: "hi"))
        store.applyReactions(id: "m1", reactions: [ReactionCount(emoji: "🎉", count: 1)])
        store.removeReaction(messageID: "m1", emoji: "🎉")
        XCTAssertTrue(store.messages[0].reactions.isEmpty) // optimistic
        await waitFor { store.error?.contains("react failed") == true }
        XCTAssertEqual(
            store.messages[0].reactions, [ReactionCount(emoji: "🎉", count: 1)])
        XCTAssertTrue(store.error?.contains("400 reactionType rejected by server") == true)
    }

    // MARK: - helpers

    /// Spin until `cond` holds (mock transports resolve in ms; 2s cap).
    private func waitFor(
        _ cond: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0 ..< 100 {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition not met in 2s", file: file, line: line)
    }
}
