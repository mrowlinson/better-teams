// NcDeliveryTests — om-nc-delivery: decision-to-banner mapping, click
// routing, thread grouping, lock-screen redaction.
import UserNotifications
import XCTest

@testable import OstMacCore

final class NcDeliveryTests: XCTestCase {
    func msg(
        chatID: String = "19:abc@thread.v2",
        msgId: String = "m1",
        sender: String = "Megan Harper",
        text: String = "hello there",
        isEdit: Bool = false,
        messageType: String? = nil
    ) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chatID, msgId: msgId, sender: sender,
            text: text, time: "2026-09-23T10:00:00Z",
            isEdit: isEdit, editedID: isEdit ? "m0" : nil,
            messageType: messageType)
    }

    func cfg(_ rules: [NotifyRule] = []) -> RulesConfig {
        var c = RulesConfig(owner: RulesOwner(displayName: "Me", mri: "8:orgid:me"))
        c.notifyRules = rules
        c.applyRules()
        return c
    }

    // MARK: decision-to-banner mapping

    func testNotifyMapsToBanner() {
        let b = NcDelivery.makeBanner(
            for: msg(), chatName: "Design Sync",
            decision: .notify(reason: "chat-message"), screenLocked: false)
        XCTAssertEqual(b?.id, "m1")
        XCTAssertEqual(b?.chatID, "19:abc@thread.v2")
        XCTAssertEqual(b?.title, "Megan Harper in Design Sync")
        XCTAssertEqual(b?.body, "hello there")
    }

    func testEverySkipSuppresses() {
        for reason in [
            "muted", "teams-muted", "keyword-block", "empty-text", "json-blob",
            "code-blob", "facilitator-close", "meeting-start-suppressed",
            "own-message", "type:Control", "edit", "loud-no-mention",
        ] {
            XCTAssertNil(
                NcDelivery.makeBanner(
                    for: msg(), chatName: "Design Sync",
                    decision: .skip(reason: reason), screenLocked: false),
                "skip \(reason) must suppress the banner")
        }
    }

    func testMeetingStartingSynthesizesBody() {
        let beacon = msg(sender: "?", text: "StandupPlay")
        let b = NcDelivery.makeBanner(
            for: beacon, chatName: "Standup",
            decision: .notify(reason: ChatFilter.meetingStartingReason),
            screenLocked: false)
        XCTAssertEqual(b?.title, "Standup")
        XCTAssertEqual(b?.body, "Meeting starting: Standup")
        XCTAssertFalse(b?.body.contains("StandupPlay") ?? true)
    }

    func testMeetingStartingWithoutChatName() {
        let b = NcDelivery.makeBanner(
            for: msg(), chatName: "",
            decision: .notify(reason: ChatFilter.meetingStartingReason),
            screenLocked: false)
        XCTAssertEqual(b?.title, "Teams meeting")
        XCTAssertEqual(b?.body, "Meeting starting")
    }

    func testTitleFallbacks() {
        // Unknown chat: sender carries the title.
        let solo = NcDelivery.makeBanner(
            for: msg(), chatName: "",
            decision: .notify(reason: "chat-message"), screenLocked: false)
        XCTAssertEqual(solo?.title, "Megan Harper")
        // Blank sender: the chat name carries the title.
        let anon = NcDelivery.makeBanner(
            for: msg(sender: ""), chatName: "Design Sync",
            decision: .notify(reason: "chat-message"), screenLocked: false)
        XCTAssertEqual(anon?.title, "Design Sync")
        // Neither: generic product title.
        let bare = NcDelivery.makeBanner(
            for: msg(sender: ""), chatName: "",
            decision: .notify(reason: "chat-message"), screenLocked: false)
        XCTAssertEqual(bare?.title, "Teams message")
    }

    func testEmptyTextFallsBack() {
        let b = NcDelivery.makeBanner(
            for: msg(text: ""), chatName: "Design Sync",
            decision: .notify(reason: "chat-message"), screenLocked: false)
        XCTAssertEqual(b?.body, NcDelivery.emptyBody)
    }

    func testDirectChatCollapseAgreesWithOracle() {
        // 1:1 chat: chat name is the sender — banner reads "X", never "X in X".
        let direct = msg()
        let banner = NcDelivery.makeBanner(
            for: direct, chatName: "Megan Harper",
            decision: .notify(reason: "chat-message"), screenLocked: false)
        XCTAssertEqual(banner?.title, "Megan Harper")
        let oracle = MessageNotifications.makeRulesNote(
            for: direct, chatName: "Megan Harper", reason: "chat-message")
        XCTAssertEqual(banner?.title, oracle.title)
        XCTAssertEqual(banner?.body, oracle.body)
        // Group chat: "sender in chat" on both paths.
        let group = NcDelivery.makeBanner(
            for: direct, chatName: "Design Sync",
            decision: .notify(reason: "chat-message"), screenLocked: false)
        let groupOracle = MessageNotifications.makeRulesNote(
            for: direct, chatName: "Design Sync", reason: "chat-message")
        XCTAssertEqual(group?.title, "Megan Harper in Design Sync")
        XCTAssertEqual(group?.title, groupOracle.title)
        XCTAssertEqual(group?.body, groupOracle.body)
    }

    func testPerChatDecisionsDriveBanners() {
        // Same event, two threads: noisy chat without a mention stays
        // silent, the normal chat banners (real rules engine, per chat).
        let rules = cfg([NotifyRule(kind: NotifyRule.noisyChats, value: "Watercooler")])
        let m = msg(text: "lunch plans?")
        let loud = ChatFilter.decide(
            message: m, chatDisplayName: "Watercooler Chat",
            ownerMRI: "8:orgid:me", rules: rules)
        XCTAssertEqual(loud, .skip(reason: "loud-no-mention"))
        XCTAssertNil(NcDelivery.makeBanner(
            for: m, chatName: "Watercooler Chat", decision: loud, screenLocked: false))
        let normal = ChatFilter.decide(
            message: m, chatDisplayName: "Team Chat",
            ownerMRI: "8:orgid:me", rules: rules)
        XCTAssertEqual(normal, .notify(reason: "chat-message"))
        XCTAssertNotNil(NcDelivery.makeBanner(
            for: m, chatName: "Team Chat", decision: normal, screenLocked: false))
    }

    func testMentionInNoisyChatBanners() {
        let rules = cfg([NotifyRule(kind: NotifyRule.noisyChats, value: "Watercooler")])
        let m = RealtimeMessage(
            chatID: "19:abc@thread.v2", msgId: "m9", sender: "Megan Harper",
            text: "hi Me", time: "2026-09-23T10:00:00Z",
            isEdit: false, raw: #"hi <at id="0">Me</at>"#)
        let d = ChatFilter.decide(
            message: m, chatDisplayName: "Watercooler Chat",
            ownerMRI: "8:orgid:me", rules: rules)
        XCTAssertEqual(d, .notify(reason: "loud-owner-mention"))
        let b = NcDelivery.makeBanner(
            for: m, chatName: "Watercooler Chat", decision: d, screenLocked: false)
        XCTAssertEqual(b?.title, "Megan Harper in Watercooler Chat")
    }

    // MARK: click routing

    func testClickOpensChatBothKeys() {
        XCTAssertEqual(
            NcDelivery.route(
                actionID: UNNotificationDefaultActionIdentifier,
                userInfo: ["chatID": "19:a"]),
            .open(chatID: "19:a"))
        XCTAssertEqual(
            NcDelivery.route(
                actionID: UNNotificationDefaultActionIdentifier,
                userInfo: [OmReplyInfo.chatIDKey: "19:b"]),
            .open(chatID: "19:b"))
    }

    func testOpenChatActionOpens() {
        XCTAssertEqual(
            NcDelivery.route(
                actionID: OmReplyInfo.openActionID,
                userInfo: ["chatID": "19:a"]),
            .open(chatID: "19:a"))
    }

    func testReplyRoutesWithText() {
        XCTAssertEqual(
            NcDelivery.route(
                actionID: SystemNotificationCenter.replyActionID,
                userInfo: ["chatID": "19:x"], replyText: "yo"),
            .reply(chatID: "19:x", text: "yo"))
    }

    func testEmptyReplyDismissUnknownAreNone() {
        XCTAssertEqual(
            NcDelivery.route(
                actionID: SystemNotificationCenter.replyActionID,
                userInfo: ["chatID": "19:x"], replyText: ""),
            .none)
        XCTAssertEqual(
            NcDelivery.route(
                actionID: SystemNotificationCenter.replyActionID,
                userInfo: ["chatID": "19:x"]),
            .none)
        XCTAssertEqual(
            NcDelivery.route(
                actionID: UNNotificationDismissActionIdentifier,
                userInfo: ["chatID": "19:x"]),
            .none)
        XCTAssertEqual(
            NcDelivery.route(
                actionID: UNNotificationDefaultActionIdentifier, userInfo: [:]),
            .none)
        XCTAssertEqual(
            NcDelivery.route(
                actionID: UNNotificationDefaultActionIdentifier,
                userInfo: ["chatID": ""]),
            .none)
    }

    func testChatIDReadsBothKeys() {
        XCTAssertEqual(NcDelivery.chatID(from: ["chatID": "19:a"]), "19:a")
        XCTAssertEqual(NcDelivery.chatID(from: [OmReplyInfo.chatIDKey: "19:b"]), "19:b")
        XCTAssertNil(NcDelivery.chatID(from: [:]))
        XCTAssertNil(NcDelivery.chatID(from: ["chatID": ""]))
    }

    func testDispatchToleratesRulesKey() {
        let exp = expectation(forNotification: .omNotifOpenChat, object: nil) {
            $0.userInfo?["chatID"] as? String == "19:rules-posted"
        }
        let r = MessageNotifications.dispatch(
            actionID: UNNotificationDefaultActionIdentifier,
            userInfo: [OmReplyInfo.chatIDKey: "19:rules-posted"])
        XCTAssertEqual(r, .open(chatID: "19:rules-posted"))
        wait(for: [exp], timeout: 1)
    }

    // MARK: grouping

    func testBannerGroupsByThread() {
        let a = NcDelivery.makeBanner(
            for: msg(chatID: "19:a", msgId: "m1"), chatName: "A",
            decision: .notify(reason: "chat-message"), screenLocked: false)
        let b = NcDelivery.makeBanner(
            for: msg(chatID: "19:a", msgId: "m2"), chatName: "A",
            decision: .notify(reason: "chat-message"), screenLocked: false)
        let c = NcDelivery.makeBanner(
            for: msg(chatID: "19:c", msgId: "m3"), chatName: "C",
            decision: .notify(reason: "chat-message"), screenLocked: false)
        XCTAssertEqual(a?.threadIdentifier, "19:a")
        XCTAssertEqual(a?.threadIdentifier, b?.threadIdentifier)
        XCTAssertNotEqual(a?.threadIdentifier, c?.threadIdentifier)
    }

    func testPostedNotificationDefaultsThreadToChat() {
        let note = PostedNotification(id: "m1", chatID: "19:a", title: "t", body: "b")
        XCTAssertEqual(note.threadIdentifier, "19:a")
    }

    // MARK: redact

    func testLockedBannerRedacts() {
        let b = NcDelivery.makeBanner(
            for: msg(), chatName: "Design Sync",
            decision: .notify(reason: "chat-message"), screenLocked: true)
        XCTAssertEqual(b?.title, NcDelivery.redactedTitle)
        XCTAssertEqual(b?.body, NcDelivery.redactedBody)
        XCTAssertFalse(b?.title.contains("Megan") ?? true)
        XCTAssertFalse(b?.body.contains("hello") ?? true)
        // Grouping survives redaction.
        XCTAssertEqual(b?.threadIdentifier, "19:abc@thread.v2")
    }

    func testLockedMeetingRedactsChatName() {
        let b = NcDelivery.makeBanner(
            for: msg(), chatName: "Secret Standup",
            decision: .notify(reason: ChatFilter.meetingStartingReason),
            screenLocked: true)
        XCTAssertEqual(b?.title, NcDelivery.redactedTitle)
        XCTAssertFalse(b?.body.contains("Secret") ?? true)
    }

    func testUnlockedBannerShowsContent() {
        let b = NcDelivery.makeBanner(
            for: msg(), chatName: "Design Sync",
            decision: .notify(reason: "chat-message"), screenLocked: false)
        XCTAssertTrue(b?.title.contains("Megan") ?? false)
        XCTAssertTrue(b?.body.contains("hello") ?? false)
    }

    func testLegacyGateRedactsToo() {
        let note = MessageNotifications.makeNotification(for: msg(), screenLocked: true)
        XCTAssertEqual(note?.title, NcDelivery.redactedTitle)
        XCTAssertEqual(note?.body, NcDelivery.redactedBody)
    }
}
