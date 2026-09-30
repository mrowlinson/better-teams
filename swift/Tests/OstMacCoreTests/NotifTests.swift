// NotifTests — om-notif pipeline: gate, post+deliver, click/reply routing.
import UserNotifications
import XCTest

@testable import OstMacCore

final class NotifTests: XCTestCase {
    func realtime(
        chat: String = "19:abc@thread.v2", id: String = "m1",
        sender: String = "Megan Harper", text: String = "hello", edit: Bool = false
    ) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chat, msgId: id, sender: sender,
            text: text, time: "2026-09-23T10:00:00Z",
            isEdit: edit, editedID: edit ? "m0" : nil)
    }

    /// Isolated defaults: the banner toggle persists, so tests must
    /// never read/write the real standard defaults.
    func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-notif-\(UUID().uuidString)") ?? .standard
    }

    func testPostsAndDelivers() async {
        let fake = FakeNotificationCenter()
        let notifs = await MessageNotifications(backend: fake, defaults: isolatedDefaults())
        await notifs.handle(realtime(), openChatID: "19:other@thread.v2")
        let posted = await fake.posted
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted[0].id, "m1")
        XCTAssertEqual(posted[0].chatID, "19:abc@thread.v2")
        XCTAssertEqual(posted[0].title, "Megan Harper")
        XCTAssertEqual(posted[0].body, "hello")
        // Delivered log replays the post (banner proof surface).
        let delivered = await notifs.delivered()
        XCTAssertEqual(delivered, posted)
    }

    func testGroupTitleNamesChat() {
        let note = MessageNotifications.makeNotification(
            for: realtime(), chatName: "Design Sync")
        XCTAssertEqual(note?.title, "Megan Harper in Design Sync")
    }

    func testSkipsOwnMessage() {
        let m = realtime(sender: "Me")
        XCTAssertNil(MessageNotifications.makeNotification(for: m, ownDisplayName: "Me"))
    }

    func testSkipsEdit() {
        XCTAssertNil(MessageNotifications.makeNotification(for: realtime(edit: true)))
    }

    func testSkipsOpenChat() {
        let m = realtime()
        XCTAssertNil(MessageNotifications.makeNotification(for: m, openChatID: m.chatID))
    }

    func testDisabledPostsNothing() async {
        let fake = FakeNotificationCenter()
        let notifs = await MessageNotifications(backend: fake, defaults: isolatedDefaults())
        await MainActor.run { notifs.enabled = false }
        await notifs.handle(realtime())
        let posted = await fake.posted
        XCTAssertEqual(posted.count, 0)
    }

    func testRequestAuthorization() async {
        let fake = FakeNotificationCenter()
        let notifs = await MessageNotifications(backend: fake, defaults: isolatedDefaults())
        await notifs.requestAuthorization()
        let authRequests = await fake.authRequests
        XCTAssertEqual(authRequests, 1)
        let authorized = await notifs.authorized
        XCTAssertEqual(authorized, true)
    }

    func testClickRoutesOpen() {
        let r = MessageNotifications.dispatch(
            actionID: UNNotificationDefaultActionIdentifier,
            userInfo: ["chatID": "19:abc@thread.v2"])
        XCTAssertEqual(r, .open(chatID: "19:abc@thread.v2"))
    }

    func testClickBroadcastsFoundationNote() {
        let exp = expectation(forNotification: .omNotifOpenChat, object: nil) {
            $0.userInfo?["chatID"] as? String == "19:abc@thread.v2"
        }
        MessageNotifications.dispatch(
            actionID: UNNotificationDefaultActionIdentifier,
            userInfo: ["chatID": "19:abc@thread.v2"])
        wait(for: [exp], timeout: TestWait.hangCeiling)
    }

    func testReplyRoutes() {
        let exp = expectation(forNotification: .omNotifReply, object: nil) {
            $0.userInfo?["chatID"] as? String == "19:x"
                && $0.userInfo?["text"] as? String == "yo"
        }
        let r = MessageNotifications.dispatch(
            actionID: SystemNotificationCenter.replyActionID,
            userInfo: ["chatID": "19:x"], replyText: "yo")
        XCTAssertEqual(r, .reply(chatID: "19:x", text: "yo"))
        wait(for: [exp], timeout: TestWait.hangCeiling)
    }

    func testEmptyReplyIsNone() {
        XCTAssertEqual(
            MessageNotifications.dispatch(
                actionID: SystemNotificationCenter.replyActionID,
                userInfo: ["chatID": "19:x"], replyText: ""),
            .none)
    }

    func testDismissAndUnknownAreNone() {
        XCTAssertEqual(
            MessageNotifications.dispatch(
                actionID: UNNotificationDismissActionIdentifier,
                userInfo: ["chatID": "19:x"]),
            .none)
        XCTAssertEqual(
            MessageNotifications.dispatch(
                actionID: UNNotificationDefaultActionIdentifier, userInfo: [:]),
            .none)
    }

    func testRulesBannerClickRoutesOpen() {
        // Rules-posted banners carry OMChatID (Notifier schema); the
        // shared delegate must still open the chat.
        let r = MessageNotifications.dispatch(
            actionID: UNNotificationDefaultActionIdentifier,
            userInfo: [OmReplyInfo.chatIDKey: "19:abc@thread.v2"])
        XCTAssertEqual(r, .open(chatID: "19:abc@thread.v2"))
    }

    func testRulesBannerOpenActionRoutesOpen() {
        let exp = expectation(forNotification: .omNotifOpenChat, object: nil) {
            $0.userInfo?["chatID"] as? String == "19:abc@thread.v2"
        }
        let r = MessageNotifications.dispatch(
            actionID: OmReplyInfo.openActionID,
            userInfo: [OmReplyInfo.chatIDKey: "19:abc@thread.v2"])
        XCTAssertEqual(r, .open(chatID: "19:abc@thread.v2"))
        wait(for: [exp], timeout: TestWait.hangCeiling)
    }

    func testRulesBannerReplyRoutes() {
        let exp = expectation(forNotification: .omNotifReply, object: nil) {
            $0.userInfo?["chatID"] as? String == "19:x"
                && $0.userInfo?["text"] as? String == "yo"
        }
        let r = MessageNotifications.dispatch(
            actionID: OmReplyInfo.replyActionID,
            userInfo: [OmReplyInfo.chatIDKey: "19:x"], replyText: "yo")
        XCTAssertEqual(r, .reply(chatID: "19:x", text: "yo"))
        wait(for: [exp], timeout: TestWait.hangCeiling)
    }

    func testEmptyOMChatIDIsNone() {
        XCTAssertEqual(
            MessageNotifications.dispatch(
                actionID: UNNotificationDefaultActionIdentifier,
                userInfo: [OmReplyInfo.chatIDKey: ""]),
            .none)
    }

    func testMakeRulesNoteGroup() {
        let note = MessageNotifications.makeRulesNote(
            for: realtime(), chatName: "Design Sync", reason: "chat-message")
        XCTAssertEqual(note.id, "m1")
        XCTAssertEqual(note.chatID, "19:abc@thread.v2")
        XCTAssertEqual(note.title, "Megan Harper in Design Sync")
        XCTAssertEqual(note.body, "hello")
    }

    func testMakeRulesNoteBareChat() {
        let note = MessageNotifications.makeRulesNote(
            for: realtime(), chatName: "", reason: "chat-message")
        XCTAssertEqual(note.title, "Megan Harper")
        XCTAssertEqual(note.body, "hello")
    }

    func testMakeRulesNoteDirectChatCollapses() {
        // 1:1 chat: chat name is the sender — never "X in X".
        let note = MessageNotifications.makeRulesNote(
            for: realtime(), chatName: "Megan Harper", reason: "chat-message")
        XCTAssertEqual(note.title, "Megan Harper")
        XCTAssertEqual(note.body, "hello")
    }

    func testMakeRulesNoteMeetingStart() {
        let note = MessageNotifications.makeRulesNote(
            for: realtime(text: "Design SyncPlay"),
            chatName: "Design Sync", reason: ChatFilter.meetingStartingReason)
        XCTAssertEqual(note.title, "Design Sync")
        XCTAssertEqual(note.body, "Meeting starting: Design Sync")
    }

    func testMakeRulesNoteMeetingStartUnknownChat() {
        let note = MessageNotifications.makeRulesNote(
            for: realtime(), chatName: "",
            reason: ChatFilter.meetingStartingReason)
        XCTAssertEqual(note.title, "Teams meeting")
        XCTAssertEqual(note.body, "Meeting starting")
    }
}
