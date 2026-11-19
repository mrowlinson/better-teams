// LocalNotifTests — lanes/localnotif: client-side thread mute + rules
// engine + saved verdict pins.
//   - Mute reclassify: muting a chat moves its PRE-EXISTING unread out
//     of the dock total at once (ingest only flags NEW arrivals);
//     unmuting moves it back. Rows keep their badge either way (D19).
//   - Rules parity: the background snapshot preserves the mute /
//     mentions-only / priority sets, so inactive accounts decide with
//     the same engine (one evaluation point, per-account identity).
//   - Reply-thread mute verdict: the typed poll envelope carries no
//     reply-parent (realtime.rs RealtimeMessage: chat_id/id/sender/...,
//     no root id), so a reply-thread gate is unenforceable at notify
//     time — thread mute stays per-chat-thread (chat id), absolute.
import XCTest

@testable import OstMacCore

@MainActor
final class LocalNotifTests: XCTestCase {
    func store() -> (UnreadStore, FakeDockBadge) {
        let dock = FakeDockBadge()
        return (UnreadStore(dock: dock), dock)
    }

    func notify(_ s: UnreadStore, chat: String) {
        s.ingest(decision: .notify(reason: "chat-message"), chatID: chat, openChatID: nil)
    }

    // MARK: mute reclassify (R1a)

    func testMuteMovesPreexistingUnreadOutOfDock() {
        let (s, dock) = store()
        notify(s, chat: "a")
        notify(s, chat: "a")
        XCTAssertEqual(s.total, 2)
        XCTAssertEqual(dock.labels, ["1", "2"])
        s.setMuted(chatID: "a", muted: true)
        XCTAssertEqual(s.total, 0)
        XCTAssertEqual(s.badgeLabel, nil)
        XCTAssertEqual(s.count(for: "a"), 2) // row keeps its badge
        XCTAssertEqual(dock.labels, ["1", "2", nil])
    }

    func testUnmuteRestoresPreexistingUnreadToDock() {
        let (s, dock) = store()
        notify(s, chat: "a")
        s.setMuted(chatID: "a", muted: true)
        XCTAssertEqual(s.total, 0)
        s.setMuted(chatID: "a", muted: false)
        XCTAssertEqual(s.total, 1)
        XCTAssertEqual(s.badgeLabel, "1")
        XCTAssertEqual(dock.labels, ["1", nil, "1"])
    }

    func testSetMutedReadChatRecordsNothing() {
        let (s, dock) = store()
        s.setMuted(chatID: "a", muted: true)
        XCTAssertFalse(s.mutedUnreadIDs.contains("a"))
        XCTAssertTrue(dock.labels.isEmpty)
        s.setMuted(chatID: "a", muted: false)
        XCTAssertTrue(dock.labels.isEmpty)
    }

    func testSetMutedBlankAndNoChangeAreSilent() {
        let (s, dock) = store()
        s.setMuted(chatID: "  ", muted: true)
        s.setMuted(chatID: "", muted: false)
        XCTAssertTrue(dock.labels.isEmpty)
        notify(s, chat: "a")
        s.setMuted(chatID: "a", muted: true)
        let writes = dock.labels.count
        s.setMuted(chatID: "a", muted: true) // already flagged: no-op
        s.setMuted(chatID: "b", muted: false) // never flagged: no-op
        XCTAssertEqual(dock.labels.count, writes)
    }

    func testMuteReclassifyKeepsOtherChatsCounted() {
        let (s, _) = store()
        notify(s, chat: "a")
        notify(s, chat: "b")
        s.setMuted(chatID: "a", muted: true)
        XCTAssertEqual(s.total, 1)
        XCTAssertEqual(s.count(for: "a"), 1)
        XCTAssertEqual(s.count(for: "b"), 1)
    }

    // MARK: background snapshot parity (R1b: one engine)

    func testBackgroundSnapshotPreservesMuteSets() {
        var base = RulesConfig(owner: RulesOwner(displayName: "Me", mri: "8:orgid:me"))
        base.mutedChatIDs = ["19:muted@thread.v2"]
        base.mentionOnlyChatIDs = ["19:mentions@thread.v2"]
        base.priorityChatIDs = ["19:prio@thread.v2"]
        let snap = BackgroundRules.snapshot(
            base: base,
            account: AccountRecord(id: "acct-b", displayName: "Beth", userID: "oid-b"))
        XCTAssertEqual(snap.mutedChatIDs, ["19:muted@thread.v2"])
        XCTAssertEqual(snap.mentionOnlyChatIDs, ["19:mentions@thread.v2"])
        XCTAssertEqual(snap.priorityChatIDs, ["19:prio@thread.v2"])
        XCTAssertEqual(snap.owner.displayName, "Beth")
        XCTAssertEqual(snap.owner.mri, "8:orgid:oid-b")
    }

    func testMutedChatSkipsIdenticallyOnSnapshot() {
        var base = RulesConfig(owner: RulesOwner(displayName: "Me", mri: "8:orgid:me"))
        base.mutedChatIDs = ["19:muted@thread.v2"]
        base.applyRules()
        let snap = BackgroundRules.snapshot(
            base: base,
            account: AccountRecord(id: "acct-b", displayName: "Beth", userID: "oid-b"))
        let msg = RealtimeMessage(
            chatID: "19:muted@thread.v2", msgId: "m1", sender: "Amy",
            senderID: "8:orgid:amy", text: "hi Me",
            time: "2026-11-19T10:00:00Z", isEdit: false,
            raw: #"hi <at id="0">Beth</at>"#, messageType: "Text")
        XCTAssertEqual(
            ChatFilter.decide(message: msg, chatDisplayName: "Team", ownerMRI: "8:orgid:me", rules: base),
            .skip(reason: ChatFilter.chatMutedReason))
        XCTAssertEqual(
            ChatFilter.decide(
                message: msg, chatDisplayName: "Team",
                ownerMRI: BackgroundRules.ownerMRI(
                    account: AccountRecord(id: "acct-b", displayName: "Beth", userID: "oid-b")),
                rules: snap),
            .skip(reason: ChatFilter.chatMutedReason))
    }
}
