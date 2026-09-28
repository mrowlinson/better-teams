// NotifBadgeTests — om-notifbadge: rules-driven unread + dock badge.
import XCTest

@testable import OstMacCore

@MainActor
final class NotifBadgeTests: XCTestCase {
    func msg(
        chatID: String = "19:chat@thread.v2",
        msgId: String = "m1",
        sender: String = "Megan",
        senderID: String? = "8:orgid:megan",
        text: String = "hello",
        time: String = "2026-09-23T10:00:00Z",
        isEdit: Bool = false,
        editedID: String? = nil,
        raw: String? = nil,
        messageType: String? = "Text"
    ) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chatID, msgId: msgId, sender: sender,
            senderID: senderID, text: text, time: time,
            isEdit: isEdit, editedID: editedID, raw: raw,
            messageType: messageType)
    }

    func cfg(_ rules: [NotifyRule] = [], owner: String = "Me", mri: String = "8:orgid:me") -> RulesConfig {
        var c = RulesConfig(owner: RulesOwner(displayName: owner, mri: mri))
        c.notifyRules = rules
        c.applyRules()
        return c
    }

    func store() -> (UnreadStore, FakeDockBadge) {
        let dock = FakeDockBadge()
        return (UnreadStore(dock: dock), dock)
    }

    // MARK: pure gates

    func testBadgeLabelPure() {
        XCTAssertNil(UnreadStore.badgeLabel(forTotal: 0))
        XCTAssertEqual(UnreadStore.badgeLabel(forTotal: 1), "1")
        XCTAssertEqual(UnreadStore.badgeLabel(forTotal: 42), "42")
    }

    func testShouldCountPure() {
        XCTAssertTrue(UnreadStore.shouldCount(
            decision: .notify(reason: "chat-message"), chatID: "a", openChatID: "b"))
        XCTAssertTrue(UnreadStore.shouldCount(
            decision: .notify(reason: "chat-message"), chatID: "a", openChatID: nil))
        XCTAssertFalse(UnreadStore.shouldCount(
            decision: .notify(reason: "chat-message"), chatID: "a", openChatID: "a"))
        XCTAssertFalse(UnreadStore.shouldCount(
            decision: .skip(reason: "own-message"), chatID: "a", openChatID: nil))
        XCTAssertFalse(UnreadStore.shouldCount(
            decision: .notify(reason: "chat-message"), chatID: "  ", openChatID: nil))
    }

    // MARK: accrue + dock

    func testNotifyIncrementsAndSetsDock() {
        let (s, dock) = store()
        s.ingest(decision: .notify(reason: "chat-message"), chatID: "a", openChatID: nil)
        s.ingest(decision: .notify(reason: "chat-message"), chatID: "a", openChatID: nil)
        s.ingest(decision: .notify(reason: "chat-message"), chatID: "b", openChatID: nil)
        XCTAssertEqual(s.count(for: "a"), 2)
        XCTAssertEqual(s.count(for: "b"), 1)
        XCTAssertEqual(s.total, 3)
        XCTAssertEqual(s.badgeLabel, "3")
        XCTAssertEqual(dock.labels, ["1", "2", "3"])
    }

    func testSkipNeverCountsOrTouchesDock() {
        // CONTRACT CHANGE (fid-lists D19): mute skips ("muted",
        // "teams-muted", "chat-muted") now accrue ROW unread (Teams:
        // muted chats still bold) while staying out of the badge —
        // see FidListsTests. Every other skip still never counts.
        let (s, dock) = store()
        for reason in ["keyword-block", "empty-text", "own-message", "edit", "snoozed"] {
            s.ingest(decision: .skip(reason: reason), chatID: "a", openChatID: nil)
        }
        XCTAssertEqual(s.count(for: "a"), 0)
        XCTAssertEqual(s.total, 0)
        XCTAssertNil(s.badgeLabel)
        XCTAssertTrue(dock.labels.isEmpty)
    }

    func testOpenChatNeverAccrues() {
        let (s, dock) = store()
        s.ingest(decision: .notify(reason: "chat-message"), chatID: "a", openChatID: "a")
        XCTAssertEqual(s.total, 0)
        XCTAssertTrue(dock.labels.isEmpty)
    }

    // MARK: mark-read

    func testMarkReadClearsOneAndSyncsDock() {
        let (s, dock) = store()
        s.ingest(decision: .notify(reason: "x"), chatID: "a", openChatID: nil)
        s.ingest(decision: .notify(reason: "x"), chatID: "b", openChatID: nil)
        s.markRead(chatID: "a")
        XCTAssertEqual(s.count(for: "a"), 0)
        XCTAssertEqual(s.total, 1)
        XCTAssertEqual(s.badgeLabel, "1")
        XCTAssertEqual(dock.labels, ["1", "2", "1"])
        // Unknown id: no dock write.
        let n = dock.labels.count
        s.markRead(chatID: "zzz")
        XCTAssertEqual(dock.labels.count, n)
    }

    func testMarkAllReadClearsBadge() {
        let (s, dock) = store()
        s.ingest(decision: .notify(reason: "x"), chatID: "a", openChatID: nil)
        s.markAllRead()
        XCTAssertEqual(s.total, 0)
        XCTAssertNil(s.badgeLabel)
        XCTAssertEqual(dock.labels, ["1", nil])
        // Empty: no dock write.
        let n = dock.labels.count
        s.markAllRead()
        XCTAssertEqual(dock.labels.count, n)
    }

    func testBadgeClearsWhenCaughtUp() {
        let (s, dock) = store()
        s.ingest(decision: .notify(reason: "x"), chatID: "a", openChatID: nil)
        s.ingest(decision: .notify(reason: "x"), chatID: "b", openChatID: nil)
        s.markRead(chatID: "a")
        XCTAssertEqual(s.badgeLabel, "1")
        s.markRead(chatID: "b")
        XCTAssertEqual(s.total, 0)
        XCTAssertNil(s.badgeLabel)
        XCTAssertEqual(dock.labels, ["1", "2", "1", nil])
    }

    // MARK: per-rule: blank / own / type / edit

    func testBlankRulesNotifyCounts() {
        let (s, _) = store()
        var dedup = MeetingStartDedup()
        let d = s.ingest(
            message: msg(), chatDisplayName: "Team Chat",
            ownerMRI: "8:orgid:me", rules: cfg(),
            meetingDedup: &dedup, now: Date(), openChatID: nil)
        XCTAssertEqual(d, .notify(reason: "chat-message"))
        XCTAssertEqual(s.total, 1)
    }

    func testSkipOwnNoBadge() {
        let (s, _) = store()
        var dedup = MeetingStartDedup()
        let c = cfg([NotifyRule(kind: NotifyRule.skipMyMessages)])
        let d = s.ingest(
            message: msg(sender: "Me", senderID: "8:orgid:me", text: "echo"),
            chatDisplayName: "Team Chat", ownerMRI: "8:orgid:me", rules: c,
            meetingDedup: &dedup, now: Date(), openChatID: nil)
        XCTAssertEqual(d, .skip(reason: "own-message"))
        XCTAssertEqual(s.total, 0)
    }

    func testTypeGateBadge() {
        let (s, _) = store()
        var dedup = MeetingStartDedup()
        let c = cfg([NotifyRule(kind: NotifyRule.messageTypes, value: "Text, RichText")])
        // Blocked type: no badge.
        let d1 = s.ingest(
            message: msg(msgId: "t1", messageType: "Control/Typing"),
            chatDisplayName: "Team Chat", ownerMRI: "8:orgid:me", rules: c,
            meetingDedup: &dedup, now: Date(), openChatID: nil)
        XCTAssertEqual(d1, .skip(reason: "type:Control"))
        XCTAssertEqual(s.total, 0)
        // Allowed type: badge.
        let d2 = s.ingest(
            message: msg(msgId: "t2", messageType: "RichText/Html"),
            chatDisplayName: "Team Chat", ownerMRI: "8:orgid:me", rules: c,
            meetingDedup: &dedup, now: Date(), openChatID: nil)
        XCTAssertEqual(d2, .notify(reason: "chat-message"))
        XCTAssertEqual(s.total, 1)
        // Unknown type passes: badge.
        let d3 = s.ingest(
            message: msg(msgId: "t3", messageType: nil),
            chatDisplayName: "Team Chat", ownerMRI: "8:orgid:me", rules: c,
            meetingDedup: &dedup, now: Date(), openChatID: nil)
        XCTAssertEqual(d3, .notify(reason: "chat-message"))
        XCTAssertEqual(s.total, 2)
    }

    func testEditGateBadge() {
        let (s, _) = store()
        var dedup = MeetingStartDedup()
        let skipping = cfg([NotifyRule(kind: NotifyRule.skipEdited)])
        let d1 = s.ingest(
            message: msg(msgId: "e1", isEdit: true, editedID: "m0"),
            chatDisplayName: "Team Chat", ownerMRI: "8:orgid:me", rules: skipping,
            meetingDedup: &dedup, now: Date(), openChatID: nil)
        XCTAssertEqual(d1, .skip(reason: "edit"))
        XCTAssertEqual(s.total, 0)
        // Absent rule: edits notify → badge.
        let d2 = s.ingest(
            message: msg(msgId: "e2", isEdit: true, editedID: "m0"),
            chatDisplayName: "Team Chat", ownerMRI: "8:orgid:me", rules: cfg(),
            meetingDedup: &dedup, now: Date(), openChatID: nil)
        XCTAssertEqual(d2, .notify(reason: "chat-message"))
        XCTAssertEqual(s.total, 1)
    }

    // MARK: per-rule: noisy + mentions

    func testNoisySkipNoBadgeMentionBadges() {
        let (s, _) = store()
        var dedup = MeetingStartDedup()
        let c = cfg([NotifyRule(kind: NotifyRule.noisyChats, value: "Watercooler")])
        let d1 = s.ingest(
            message: msg(msgId: "n1"), chatDisplayName: "Watercooler Chat",
            ownerMRI: "8:orgid:me", rules: c,
            meetingDedup: &dedup, now: Date(), openChatID: nil)
        XCTAssertEqual(d1, .skip(reason: "loud-no-mention"))
        XCTAssertEqual(s.total, 0)
        let d2 = s.ingest(
            message: msg(msgId: "n2", text: "hi Me", raw: #"hi <at id="0">Me</at>"#),
            chatDisplayName: "Watercooler Chat", ownerMRI: "8:orgid:me", rules: c,
            meetingDedup: &dedup, now: Date(), openChatID: nil)
        XCTAssertEqual(d2, .notify(reason: "loud-owner-mention"))
        XCTAssertEqual(s.total, 1)
    }

    func testNoisyChannelGateBadge() {
        var dedup = MeetingStartDedup()
        let on = cfg([NotifyRule(kind: NotifyRule.noisyChats, value: "Watercooler")])
        let off = cfg([
            NotifyRule(kind: NotifyRule.noisyChats, value: "Watercooler"),
            NotifyRule(kind: NotifyRule.noisyChannel, enabled: false),
        ])
        let m = msg(text: "hi channel", raw: #"hi <at id="0">channel</at>"#)
        let (s1, _) = store()
        let d1 = s1.ingest(
            message: m, chatDisplayName: "Watercooler Chat",
            ownerMRI: "8:orgid:me", rules: on,
            meetingDedup: &dedup, now: Date(), openChatID: nil)
        XCTAssertEqual(d1, .notify(reason: "loud-channel-mention"))
        XCTAssertEqual(s1.total, 1)
        let (s2, _) = store()
        let d2 = s2.ingest(
            message: m, chatDisplayName: "Watercooler Chat",
            ownerMRI: "8:orgid:me", rules: off,
            meetingDedup: &dedup, now: Date(), openChatID: nil)
        XCTAssertEqual(d2, .skip(reason: "loud-no-mention"))
        XCTAssertEqual(s2.total, 0)
    }

    func testNameBackupGateBadge() {
        var dedup = MeetingStartDedup()
        let c = cfg([
            NotifyRule(kind: NotifyRule.skipMyMessages),
            NotifyRule(kind: NotifyRule.nameBackup, enabled: false),
        ])
        // IDs only: name-echo without MRI notifies → badge.
        let (s, _) = store()
        let d = s.ingest(
            message: msg(sender: "Me", senderID: nil, text: "echo"),
            chatDisplayName: "Team Chat", ownerMRI: "8:orgid:me", rules: c,
            meetingDedup: &dedup, now: Date(), openChatID: nil)
        XCTAssertEqual(d, .notify(reason: "chat-message"))
        XCTAssertEqual(s.total, 1)
    }

    // MARK: per-rule: keywords

    func testKeywordAllowBadgesThroughSkip() {
        let (s, _) = store()
        var dedup = MeetingStartDedup()
        let c = cfg([
            NotifyRule(kind: NotifyRule.skipMyMessages),
            NotifyRule(kind: NotifyRule.keywordAllow, value: "outage"),
        ])
        let d = s.ingest(
            message: msg(sender: "Me", senderID: "8:orgid:me", text: "outage in prod"),
            chatDisplayName: "Team Chat", ownerMRI: "8:orgid:me", rules: c,
            meetingDedup: &dedup, now: Date(), openChatID: nil)
        XCTAssertEqual(d, .notify(reason: "keyword-allow"))
        XCTAssertEqual(s.total, 1)
    }

    func testKeywordBlockNoBadge() {
        let (s, _) = store()
        var dedup = MeetingStartDedup()
        let c = cfg([
            NotifyRule(kind: NotifyRule.keywordAllow, value: "outage"),
            NotifyRule(kind: NotifyRule.keywordBlock, value: "lunch"),
        ])
        let d = s.ingest(
            message: msg(text: "outage postmortem over lunch"),
            chatDisplayName: "Team Chat", ownerMRI: "8:orgid:me", rules: c,
            meetingDedup: &dedup, now: Date(), openChatID: nil)
        XCTAssertEqual(d, .skip(reason: "keyword-block"))
        XCTAssertEqual(s.total, 0)
    }

    // MARK: per-rule: mute gates + meeting + structural

    func testMutedNoBadge() {
        let (s, _) = store()
        var dedup = MeetingStartDedup()
        var c = cfg()
        c.muted = true
        let d = s.ingest(
            message: msg(), chatDisplayName: "Team Chat",
            ownerMRI: "8:orgid:me", rules: c,
            meetingDedup: &dedup, now: Date(), openChatID: nil)
        XCTAssertEqual(d, .skip(reason: "muted"))
        XCTAssertEqual(s.total, 0)
    }

    func testTeamsMutedNoBadge() {
        let (s, _) = store()
        var dedup = MeetingStartDedup()
        let d = s.ingest(
            message: msg(), chatDisplayName: "Team Chat",
            ownerMRI: "8:orgid:me", rules: cfg(),
            meetingDedup: &dedup, now: Date(), openChatID: nil,
            teamsMutedChatIDs: ["19:chat@thread.v2"])
        XCTAssertEqual(d, .skip(reason: "teams-muted"))
        XCTAssertEqual(s.total, 0)
    }

    func testMeetingStartBadgesOnce() {
        let (s, _) = store()
        var dedup = MeetingStartDedup()
        let now = Date()
        let beacon = msg(chatID: "19:meeting_abc@thread.v2", sender: "?", senderID: nil, text: "StandupPlay")
        let d1 = s.ingest(
            message: beacon, chatDisplayName: "Standup",
            ownerMRI: nil, rules: cfg(),
            meetingDedup: &dedup, now: now, openChatID: nil)
        XCTAssertEqual(d1, .notify(reason: "meeting-starting"))
        XCTAssertEqual(s.total, 1)
        let d2 = s.ingest(
            message: beacon, chatDisplayName: "Standup",
            ownerMRI: nil, rules: cfg(),
            meetingDedup: &dedup, now: now.addingTimeInterval(60), openChatID: nil)
        XCTAssertEqual(d2, .skip(reason: "meeting-start-suppressed"))
        XCTAssertEqual(s.total, 1)
    }

    func testStructuralBodiesNoBadge() {
        let (s, _) = store()
        var dedup = MeetingStartDedup()
        let bodies = [
            msg(msgId: "s1", text: ""),
            msg(msgId: "s2", text: #"{"a":1}"#),
            msg(msgId: "s3", text: "```code```"),
        ]
        for m in bodies {
            let d = s.ingest(
                message: m, chatDisplayName: "Team Chat",
                ownerMRI: "8:orgid:me", rules: cfg(),
                meetingDedup: &dedup, now: Date(), openChatID: nil)
            if case .skip = d {} else {
                XCTFail("structural body should skip, got \(d)")
            }
        }
        XCTAssertEqual(s.total, 0)
    }

    func testScopedRuleBadge() {
        var dedup = MeetingStartDedup()
        let c = cfg([NotifyRule(kind: NotifyRule.keywordBlock, value: "lunch", scope: "Watercooler")])
        let (s1, _) = store()
        let d1 = s1.ingest(
            message: msg(text: "lunch?"), chatDisplayName: "Watercooler Chat",
            ownerMRI: "8:orgid:me", rules: c,
            meetingDedup: &dedup, now: Date(), openChatID: nil)
        XCTAssertEqual(d1, .skip(reason: "keyword-block"))
        XCTAssertEqual(s1.total, 0)
        let (s2, _) = store()
        let d2 = s2.ingest(
            message: msg(text: "lunch?"), chatDisplayName: "Team Chat",
            ownerMRI: "8:orgid:me", rules: c,
            meetingDedup: &dedup, now: Date(), openChatID: nil)
        XCTAssertEqual(d2, .notify(reason: "chat-message"))
        XCTAssertEqual(s2.total, 1)
    }

    func testConvenienceReturnsSingleDecision() {
        // One ingest = one meeting-window claim: the returned decision is
        // the accrued one (callers reuse it for the banner, never re-decide).
        let (s, _) = store()
        var dedup = MeetingStartDedup()
        let now = Date()
        let beacon = msg(chatID: "19:m@thread.v2", sender: "?", senderID: nil, text: "StandupPlay")
        let first = s.ingest(
            message: beacon, chatDisplayName: "Standup",
            ownerMRI: nil, rules: cfg(),
            meetingDedup: &dedup, now: now, openChatID: nil)
        XCTAssertEqual(first, .notify(reason: "meeting-starting"))
        XCTAssertEqual(s.total, 1)
        let second = s.ingest(
            message: beacon, chatDisplayName: "Standup",
            ownerMRI: nil, rules: cfg(),
            meetingDedup: &dedup, now: now.addingTimeInterval(10), openChatID: nil)
        XCTAssertEqual(second, .skip(reason: "meeting-start-suppressed"))
        XCTAssertEqual(s.total, 1)
    }
}
