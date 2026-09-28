// ActivityTests.swift — e1-activity: feed + mentions center. Classifiers,
// review coupling with MentionStore, redaction, persistence, cap, jump
// targets. No core calls (isolated UserDefaults suites).
import XCTest

@testable import OstMacCore

@MainActor
final class ActivityTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "test-activity-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func store() -> ActivityStore {
        ActivityStore(defaults: defaults)
    }

    private func live(
        chatID: String = "19:chat@thread.v2", msgId: String = "m1",
        sender: String = "Doe, Jane", senderID: String? = nil,
        text: String = "hello", raw: String? = nil,
        reactions: [ReactionCount]? = nil
    ) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chatID, msgId: msgId, sender: sender,
            senderID: senderID, text: text, time: "2026-09-25T12:00:00Z",
            isEdit: false, raw: raw, reactions: reactions)
    }

    private func ingest(
        _ s: ActivityStore, _ msg: RealtimeMessage,
        ownName: String? = "Smith, Alex", ownerMRI: String? = nil,
        openChatID: String? = nil, chatName: String = "General"
    ) {
        s.ingest(
            realtime: msg, ownName: ownName, ownerMRI: ownerMRI,
            openChatID: openChatID, chatName: chatName)
    }

    // MARK: - Empty state

    func testFreshStoreIsEmpty() {
        let s = store()
        XCTAssertTrue(s.visibleItems.isEmpty)
        XCTAssertTrue(s.mentionItems.isEmpty)
        XCTAssertEqual(s.unreviewedCount, 0)
    }

    func testEmptyStateCopyIsNamed() {
        XCTAssertFalse(ActivityStore.feedEmptyTitle.isEmpty)
        XCTAssertFalse(ActivityStore.feedEmptyMessage.isEmpty)
        XCTAssertFalse(ActivityStore.mentionsEmptyTitle.isEmpty)
        XCTAssertFalse(ActivityStore.mentionsEmptyMessage.isEmpty)
    }

    // MARK: - Mention ingest (owner + channel blast)

    func testOwnerMentionIngests() {
        let s = store()
        ingest(s, live(raw: #"<at>Smith, Alex</at> ping"#))
        XCTAssertEqual(s.visibleItems.count, 1)
        let item = s.visibleItems[0]
        XCTAssertEqual(item.kind, .mention)
        XCTAssertEqual(item.chatID, "19:chat@thread.v2")
        XCTAssertEqual(item.messageID, "m1")
        XCTAssertEqual(item.actor, "Doe, Jane")
        XCTAssertEqual(item.chatName, "General")
        XCTAssertFalse(item.snippet.isEmpty)
        XCTAssertEqual(s.mentionItems.count, 1)
    }

    func testChannelBlastIngestsAsMentionKind() {
        let s = store()
        ingest(s, live(raw: #"<at>channel</at> all hands"#))
        XCTAssertEqual(s.visibleItems.count, 1)
        XCTAssertEqual(s.visibleItems[0].kind, .channelBlast)
        XCTAssertEqual(s.mentionItems.count, 1)
    }

    func testPlainMessageNeverIngests() {
        let s = store()
        ingest(s, live(raw: "<p>hello</p>"))
        XCTAssertTrue(s.visibleItems.isEmpty)
    }

    func testOwnMentionNeverIngests() {
        let s = store()
        ingest(
            s, live(sender: "Smith, Alex", raw: "<at>Smith, Alex</at> self"),
            ownerMRI: "8:orgid:owner")
        XCTAssertTrue(s.visibleItems.isEmpty)
    }

    func testOpenChatNeverIngests() {
        let s = store()
        ingest(
            s, live(raw: "<at>Smith, Alex</at> ping"),
            openChatID: "19:chat@thread.v2")
        XCTAssertTrue(s.visibleItems.isEmpty)
    }

    func testNewestFirstOrder() {
        let s = store()
        ingest(s, live(msgId: "m1", raw: "<at>Smith, Alex</at> one"))
        ingest(s, live(msgId: "m2", raw: "<at>Smith, Alex</at> two"))
        XCTAssertEqual(s.visibleItems.map(\.messageID), ["m2", "m1"])
    }

    func testDuplicateIngestNeverResurrects() {
        let s = store()
        let msg = live(raw: "<at>Smith, Alex</at> ping")
        ingest(s, msg)
        s.markReviewed(id: s.visibleItems[0].id)
        XCTAssertTrue(s.visibleItems.isEmpty)
        ingest(s, msg)
        XCTAssertTrue(s.visibleItems.isEmpty)
    }

    // MARK: - Reply detection (live miner + history reply_to)

    func testLiveReplyToOwnerIngests() {
        let s = store()
        ingest(s, live(
            sender: "Doe, Jane",
            raw: #"<quote author="Smith, Alex" guid="p1">orig</quote><p>reply</p>"#))
        XCTAssertEqual(s.visibleItems.count, 1)
        XCTAssertEqual(s.visibleItems[0].kind, .reply)
    }

    func testLiveReplyToOtherNeverIngests() {
        let s = store()
        ingest(s, live(
            raw: #"<quote author="Chen, Tom" guid="p1">orig</quote><p>reply</p>"#))
        XCTAssertTrue(s.visibleItems.isEmpty)
    }

    func testLiveReplyOwnMessageNeverIngests() {
        let s = store()
        ingest(
            s, live(
                sender: "Smith, Alex",
                raw: #"<quote author="Smith, Alex" guid="p1">o</quote><p>self</p>"#))
        XCTAssertTrue(s.visibleItems.isEmpty)
    }

    func testHistoryReplyToOwnIngests() {
        let s = store()
        let parent = ChatMessage(
            id: "p1", sender: "Smith, Alex", timestamp: "t",
            content: "orig", isOwn: true)
        let reply = ChatMessage(
            id: "r1", sender: "Doe, Jane", timestamp: "t",
            content: "reply", reply_to: "p1")
        s.noteHistory(
            chatID: "19:c@thread.v2", messages: [parent, reply],
            ownName: "Smith, Alex", chatName: "General")
        XCTAssertEqual(s.visibleItems.count, 1)
        XCTAssertEqual(s.visibleItems[0].kind, .reply)
        XCTAssertEqual(s.visibleItems[0].messageID, "r1")
    }

    func testHistoryReplyToOtherNeverIngests() {
        let s = store()
        let parent = ChatMessage(
            id: "p1", sender: "Chen, Tom", timestamp: "t", content: "orig")
        let reply = ChatMessage(
            id: "r1", sender: "Doe, Jane", timestamp: "t",
            content: "reply", reply_to: "p1")
        s.noteHistory(
            chatID: "19:c@thread.v2", messages: [parent, reply],
            ownName: "Smith, Alex", chatName: "General")
        XCTAssertTrue(s.visibleItems.isEmpty)
    }

    func testQuoteMinerParityWithHistoryReplyTo() {
        let raw = #"<quote author="Smith, Alex" guid="p1">orig</quote><p>x</p>"#
        XCTAssertEqual(ActivityStore.quoteParentGuid(raw: raw), "p1")
        XCTAssertEqual(ActivityStore.quoteParentAuthor(raw: raw), "Smith, Alex")
        XCTAssertTrue(ActivityStore.isReplyToOwner(raw: raw, ownName: "Smith, Alex"))
        XCTAssertFalse(ActivityStore.isReplyToOwner(raw: raw, ownName: "Chen, Tom"))
        XCTAssertFalse(ActivityStore.isReplyToOwner(raw: nil, ownName: "Smith, Alex"))
        XCTAssertFalse(ActivityStore.isReplyToOwner(raw: "<p>no quote</p>", ownName: "Smith, Alex"))
    }

    // MARK: - Reaction contract (i): count-delta, actor unknown

    func testReactionBaselineThenDeltaIngestsWithoutActor() {
        let s = store()
        s.noteReaction(
            chatID: "19:c@thread.v2", messageID: "m9",
            reactions: [ReactionCount(emoji: "👍", count: 1)],
            chatName: "General", isOwnMessage: true)
        XCTAssertTrue(s.visibleItems.isEmpty, "baseline sets totals, no item")
        s.noteReaction(
            chatID: "19:c@thread.v2", messageID: "m9",
            reactions: [ReactionCount(emoji: "👍", count: 3)],
            chatName: "General", isOwnMessage: true)
        XCTAssertEqual(s.visibleItems.count, 1)
        let item = s.visibleItems[0]
        XCTAssertEqual(item.kind, .reaction)
        XCTAssertTrue(item.actor.isEmpty, "unknown actor never shows a sender")
        XCTAssertFalse(item.snippet.isEmpty)
    }

    func testReactionOnOthersMessageNeverIngests() {
        let s = store()
        s.noteReaction(
            chatID: "19:c@thread.v2", messageID: "m9",
            reactions: [ReactionCount(emoji: "👍", count: 2)],
            chatName: "General", isOwnMessage: false)
        s.noteReaction(
            chatID: "19:c@thread.v2", messageID: "m9",
            reactions: [ReactionCount(emoji: "👍", count: 5)],
            chatName: "General", isOwnMessage: false)
        XCTAssertTrue(s.visibleItems.isEmpty)
    }

    func testReactionUnknownOwnershipNeverIngests() {
        let s = store()
        s.noteReaction(
            chatID: "19:c@thread.v2", messageID: "m9",
            reactions: [ReactionCount(emoji: "👍", count: 2)],
            chatName: "General", isOwnMessage: nil)
        s.noteReaction(
            chatID: "19:c@thread.v2", messageID: "m9",
            reactions: [ReactionCount(emoji: "👍", count: 5)],
            chatName: "General", isOwnMessage: nil)
        XCTAssertTrue(s.visibleItems.isEmpty)
    }

    func testReactionRowLabelNeverShowsSender() {
        let item = ActivityItem(
            kind: .reaction, chatID: "c", messageID: "m", actor: "",
            chatName: "General", snippet: "x", at: 1_700_000_000)
        XCTAssertNil(item.actorDisplayName)
        XCTAssertEqual(item.rowTitle, "New reaction")
    }

    func testReactionDeltaUpdatesSingleItem() {
        let s = store()
        s.noteReaction(
            chatID: "c", messageID: "m",
            reactions: [ReactionCount(emoji: "👍", count: 1)],
            chatName: "G", isOwnMessage: true)
        s.noteReaction(
            chatID: "c", messageID: "m",
            reactions: [ReactionCount(emoji: "👍", count: 2)],
            chatName: "G", isOwnMessage: true)
        s.noteReaction(
            chatID: "c", messageID: "m",
            reactions: [ReactionCount(emoji: "👍", count: 3)],
            chatName: "G", isOwnMessage: true)
        XCTAssertEqual(s.visibleItems.count, 1)
    }

    // MARK: - Missed-call ingest

    func testMissedCallIngests() {
        let s = store()
        s.noteCallRecord(CallRecord(
            id: "c1", direction: .missed, peerName: "Doe, Jane",
            thread: "19:c@thread.v2", startedAt: 1_700_000_000,
            endedAt: 1_700_000_030), chatName: "Doe, Jane")
        XCTAssertEqual(s.visibleItems.count, 1)
        let item = s.visibleItems[0]
        XCTAssertEqual(item.kind, .missedCall)
        XCTAssertEqual(item.actor, "Doe, Jane")
        XCTAssertNil(item.messageID)
    }

    func testConnectedCallNeverIngests() {
        let s = store()
        s.noteCallRecord(CallRecord(
            id: "c1", direction: .incoming, peerName: "Doe, Jane",
            startedAt: 1_700_000_000, endedAt: 1_700_000_030,
            durationSecs: 30), chatName: "Doe, Jane")
        XCTAssertTrue(s.visibleItems.isEmpty)
    }

    // MARK: - Review + MentionStore coupling

    func testMarkReviewedHidesItem() {
        let s = store()
        ingest(s, live(raw: "<at>Smith, Alex</at> ping"))
        s.markReviewed(id: s.visibleItems[0].id)
        XCTAssertTrue(s.visibleItems.isEmpty)
        XCTAssertEqual(s.unreviewedCount, 0)
    }

    func testMarkChatReviewedClearsThatChatOnly() {
        let s = store()
        ingest(s, live(chatID: "c1", msgId: "m1", raw: "<at>Smith, Alex</at> a"))
        ingest(s, live(chatID: "c2", msgId: "m2", raw: "<at>Smith, Alex</at> b"))
        s.markChatReviewed(chatID: "c1")
        XCTAssertEqual(s.visibleItems.count, 1)
        XCTAssertEqual(s.visibleItems[0].chatID, "c2")
    }

    func testMarkAllReviewedClearsFeed() {
        let s = store()
        ingest(s, live(msgId: "m1", raw: "<at>Smith, Alex</at> a"))
        ingest(s, live(msgId: "m2", raw: "<at>channel</at> b"))
        s.markAllReviewed()
        XCTAssertTrue(s.visibleItems.isEmpty)
        XCTAssertEqual(s.unreviewedCount, 0)
    }

    func testLastMentionReviewFiresFlagClearHook() {
        let s = store()
        var cleared: [String] = []
        s.onMentionFlagsCleared = { cleared.append($0) }
        ingest(s, live(chatID: "c1", msgId: "m1", raw: "<at>Smith, Alex</at> a"))
        ingest(s, live(chatID: "c1", msgId: "m2", raw: "<at>Smith, Alex</at> b"))
        s.markReviewed(id: s.visibleItems[0].id)
        XCTAssertTrue(cleared.isEmpty, "one mention left, no clear")
        s.markReviewed(id: s.visibleItems[0].id)
        XCTAssertEqual(cleared, ["c1"])
    }

    func testChannelBlastReviewNeverFiresFlagHook() {
        let s = store()
        var cleared: [String] = []
        s.onMentionFlagsCleared = { cleared.append($0) }
        ingest(s, live(raw: "<at>channel</at> all"))
        s.markReviewed(id: s.visibleItems[0].id)
        XCTAssertTrue(cleared.isEmpty, "blasts never held a MentionStore flag")
    }

    func testHasUnreviewedMentions() {
        let s = store()
        ingest(s, live(chatID: "c1", raw: "<at>Smith, Alex</at> a"))
        XCTAssertTrue(s.hasUnreviewedMentions(chatID: "c1"))
        XCTAssertFalse(s.hasUnreviewedMentions(chatID: "c2"))
        s.markChatReviewed(chatID: "c1")
        XCTAssertFalse(s.hasUnreviewedMentions(chatID: "c1"))
    }

    // MARK: - Persistence + cap

    func testRelaunchRoundTripKeepsReviewedHidden() {
        let s = store()
        ingest(s, live(msgId: "m1", raw: "<at>Smith, Alex</at> a"))
        ingest(s, live(msgId: "m2", raw: "<at>Smith, Alex</at> b"))
        s.markReviewed(id: s.item(id: "mention:19:chat@thread.v2:m1")!.id)
        let reopened = ActivityStore(defaults: defaults)
        XCTAssertEqual(reopened.visibleItems.count, 1)
        XCTAssertEqual(reopened.visibleItems[0].messageID, "m2")
    }

    func testCapBoundsGrowth() {
        let s = store()
        for i in 0..<(ActivityStore.maxItems + 20) {
            ingest(s, live(msgId: "m\(i)", raw: "<at>Smith, Alex</at> \(i)"))
        }
        XCTAssertLessThanOrEqual(s.storedCount, ActivityStore.maxItems)
        XCTAssertEqual(s.visibleItems.first?.messageID, "m\(ActivityStore.maxItems + 19)")
    }

    // MARK: - Redaction

    func testPreviewOffHidesSnippet() {
        let item = ActivityItem(
            kind: .mention, chatID: "c", messageID: "m", actor: "Doe, Jane",
            chatName: "G", snippet: "secret Q3 numbers", at: 1_700_000_000)
        XCTAssertEqual(item.snippet, "secret Q3 numbers")
        XCTAssertEqual(
            ActivityItem.displaySnippet(item, showPreview: false),
            ActivityItem.redactedSnippet)
        XCTAssertFalse(ActivityItem.redactedSnippet.contains("secret"))
        XCTAssertEqual(
            ActivityItem.displaySnippet(item, showPreview: true),
            "secret Q3 numbers")
    }

    // MARK: - Jump targets

    func testJumpTargetCarriesChatAndMessage() {
        let s = store()
        ingest(s, live(raw: "<at>Smith, Alex</at> ping"))
        let target = s.jumpTarget(id: s.visibleItems[0].id)
        XCTAssertEqual(target?.chatID, "19:chat@thread.v2")
        XCTAssertEqual(target?.messageID, "m1")
    }

    func testJumpTargetUnknownIDIsNil() {
        XCTAssertNil(store().jumpTarget(id: "mention:evicted:x"))
    }

    func testMissedCallWithoutThreadHasNoChatTarget() {
        let s = store()
        s.noteCallRecord(CallRecord(
            id: "c1", direction: .missed, peerName: "Doe, Jane",
            startedAt: 1_700_000_000, endedAt: 1_700_000_030),
            chatName: "Doe, Jane")
        let target = s.jumpTarget(id: s.visibleItems[0].id)
        XCTAssertNotNil(target)
        XCTAssertFalse(target!.canJump, "never conjure a chat for threadless rows")
    }

    // MARK: - In-window panes (e1-inwindow)

    func testVisibleChatNeverIngests() {
        let s = store()
        s.ingest(
            realtime: live(raw: "<at>Smith, Alex</at> ping"),
            ownName: "Smith, Alex", ownerMRI: nil, openChatID: nil,
            chatName: "General",
            visibleChatIDs: ["19:chat@thread.v2"])
        XCTAssertTrue(
            s.visibleItems.isEmpty,
            "popped chats count as open (e1-popout parity)")
    }

    func testNonVisibleChatStillIngests() {
        let s = store()
        s.ingest(
            realtime: live(raw: "<at>Smith, Alex</at> ping"),
            ownName: "Smith, Alex", ownerMRI: nil, openChatID: nil,
            chatName: "General", visibleChatIDs: ["19:other@thread.v2"])
        XCTAssertEqual(s.visibleItems.count, 1)
    }
}
