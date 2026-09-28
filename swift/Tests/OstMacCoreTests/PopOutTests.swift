// PopOutTests — e1-popout: pop-out registry, draft cache, visible-set
// gating, feed fan-out, and send mirroring.
import XCTest

@testable import OstMacCore

@MainActor
final class PopOutTests: XCTestCase {
    // MARK: visible-set helper (pure)

    func testVisibleUnion() {
        XCTAssertEqual(
            PopOutStore.visibleChatIDs(open: "a", popped: ["b", "c"]),
            ["a", "b", "c"])
    }

    func testVisibleDupCollapses() {
        XCTAssertEqual(
            PopOutStore.visibleChatIDs(open: "a", popped: ["a", "b"]),
            ["a", "b"])
    }

    func testVisibleEmpty() {
        XCTAssertEqual(
            PopOutStore.visibleChatIDs(open: nil, popped: []), [])
        XCTAssertEqual(
            PopOutStore.visibleChatIDs(open: "a", popped: []), ["a"])
        XCTAssertEqual(
            PopOutStore.visibleChatIDs(open: nil, popped: ["b"]), ["b"])
    }

    // MARK: registry (single-window-per-chat)

    func testPopAndRepop() {
        let pops = PopOutStore()
        XCTAssertTrue(pops.pop(chatID: "a"))
        XCTAssertTrue(pops.isPopped(chatID: "a"))
        // Second pop of the same id refuses (focus instead — no dup).
        XCTAssertFalse(pops.pop(chatID: "a"))
        XCTAssertEqual(pops.poppedIDs, ["a"])
    }

    func testPopBlankRefuses() {
        let pops = PopOutStore()
        XCTAssertFalse(pops.pop(chatID: "  "))
        XCTAssertTrue(pops.poppedIDs.isEmpty)
    }

    func testCloseKeepsStoreAndDraft() {
        let pops = PopOutStore()
        XCTAssertTrue(pops.pop(chatID: "a"))
        let before = pops.store(for: "a")
        pops.saveDraft("hello", for: "a")
        pops.close(chatID: "a")
        XCTAssertFalse(pops.isPopped(chatID: "a"))
        // Store + draft survive the close (re-pop restores, no reload).
        XCTAssertTrue(pops.store(for: "a") === before)
        XCTAssertEqual(pops.draft(for: "a"), "hello")
    }

    // MARK: draft cache

    func testDraftSaveRestorePurge() {
        let pops = PopOutStore()
        XCTAssertEqual(pops.draft(for: "a"), "")
        pops.saveDraft("typed text", for: "a")
        XCTAssertEqual(pops.draft(for: "a"), "typed text")
        pops.purgeDraft(for: "a")
        XCTAssertEqual(pops.draft(for: "a"), "")
    }

    func testDraftBlankIDNoOp() {
        let pops = PopOutStore()
        pops.saveDraft("x", for: "  ")
        XCTAssertEqual(pops.draft(for: "  "), "")
    }

    // MARK: visible-set gating (open-chat parity)

    func testUnreadNoAccrueWhilePopped() {
        let dock = FakeDockBadge()
        let unread = UnreadStore(dock: dock)
        let visible: Set<String> = ["a"]
        unread.ingest(
            decision: .notify(reason: "chat-message"), chatID: "a",
            openChatID: nil, visibleChatIDs: visible)
        XCTAssertEqual(unread.count(for: "a"), 0)
        XCTAssertTrue(dock.labels.isEmpty)
    }

    func testUnreadAccrueResumesAfterClose() {
        let dock = FakeDockBadge()
        let unread = UnreadStore(dock: dock)
        unread.ingest(
            decision: .notify(reason: "chat-message"), chatID: "a",
            openChatID: nil, visibleChatIDs: [])
        XCTAssertEqual(unread.count(for: "a"), 1)
    }

    func testUnreadShouldCountVisibleSet() {
        XCTAssertFalse(UnreadStore.shouldCount(
            decision: .notify(reason: "chat-message"), chatID: "a",
            openChatID: nil, visibleChatIDs: ["a"]))
        XCTAssertTrue(UnreadStore.shouldCount(
            decision: .notify(reason: "chat-message"), chatID: "a",
            openChatID: nil, visibleChatIDs: ["b"]))
    }

    func testMentionNoFlagWhilePopped() {
        let dock = FakeDockBadge()
        let mentions = MentionStore(dock: dock)
        let msg = RealtimeMessage(
            chatID: "a", msgId: "m1", sender: "Megan Harper",
            senderID: "8:orgid:megan", text: "hey <at>Me</at>",
            time: "2026-09-23T10:00:00Z", isEdit: false,
            raw: #"<at id="8:orgid:me">Me</at>"#, messageType: "Text")
        // Sanity: flags without the visible set…
        XCTAssertTrue(MentionStore.shouldFlag(
            message: msg, ownName: "Me", ownerMRI: "8:orgid:me",
            openChatID: nil, visibleChatIDs: []))
        mentions.ingest(
            realtime: msg, ownName: "Me", ownerMRI: "8:orgid:me",
            openChatID: nil, visibleChatIDs: ["a"])
        XCTAssertFalse(mentions.contains(chatID: "a"))
        XCTAssertTrue(dock.labels.isEmpty)
        // …and accrues once the pop-out closes.
        mentions.ingest(
            realtime: msg, ownName: "Me", ownerMRI: "8:orgid:me",
            openChatID: nil, visibleChatIDs: [])
        XCTAssertTrue(mentions.contains(chatID: "a"))
    }

    // MARK: feed fan-out

    func realtime(
        chatID: String, msgId: String = "m1", sender: String = "Megan Harper",
        text: String = "hello"
    ) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chatID, msgId: msgId, sender: sender,
            senderID: "8:orgid:megan", text: text,
            time: "2026-09-23T10:00:00Z", isEdit: false,
            messageType: "Text")
    }

    func testFanOutToPoppedOnly() {
        let pops = PopOutStore()
        let main = ConversationStore()
        pops.bind(main: main)
        XCTAssertTrue(pops.pop(chatID: "a"))
        let popped = pops.store(for: "a")
        // Event for the popped (not main-open) chat reaches the pop-out
        // store and NOT the main store (no cross-talk).
        XCTAssertTrue(pops.ingest(realtime: realtime(chatID: "a")))
        XCTAssertEqual(popped.messages.count, 1)
        XCTAssertTrue(main.messages.isEmpty)
    }

    func testFanOutIgnoresUnpopped() {
        let pops = PopOutStore()
        let main = ConversationStore()
        pops.bind(main: main)
        XCTAssertTrue(pops.pop(chatID: "a"))
        // Other chats never land in any pop-out store.
        XCTAssertFalse(pops.ingest(realtime: realtime(chatID: "zzz")))
        XCTAssertTrue(pops.store(for: "a").messages.isEmpty)
    }

    func testFanOutStopsAfterClose() {
        let pops = PopOutStore()
        pops.bind(main: ConversationStore())
        XCTAssertTrue(pops.pop(chatID: "a"))
        let popped = pops.store(for: "a")
        pops.close(chatID: "a")
        XCTAssertFalse(pops.ingest(realtime: realtime(chatID: "a")))
        XCTAssertTrue(popped.messages.isEmpty)
    }

    // MARK: send mirroring (own-bubble in both windows)

    func demoStore(chatID: String, name: String = "Chat") -> ConversationStore {
        let s = ConversationStore()
        s.showDemo(chatID: chatID, chatName: name, messages: [])
        return s
    }

    func testPopoutSendMirrorsToMain() {
        let pops = PopOutStore()
        let main = demoStore(chatID: "a")
        pops.bind(main: main)
        XCTAssertTrue(pops.pop(chatID: "a"))
        let popped = pops.store(for: "a")
        popped.showDemo(chatID: "a", chatName: "Chat", messages: [])
        popped.send(text: "from pop-out")
        XCTAssertEqual(popped.messages.count, 1)
        XCTAssertEqual(main.messages.count, 1)
        XCTAssertEqual(main.messages.first?.content, "from pop-out")
        XCTAssertEqual(main.messages.first?.isOwn, true)
        XCTAssertEqual(main.messages.first?.id, popped.messages.first?.id)
    }

    func testMainSendMirrorsToPopout() {
        let pops = PopOutStore()
        let main = demoStore(chatID: "a")
        pops.bind(main: main)
        XCTAssertTrue(pops.pop(chatID: "a"))
        let popped = pops.store(for: "a")
        popped.showDemo(chatID: "a", chatName: "Chat", messages: [])
        main.send(text: "from main")
        XCTAssertEqual(main.messages.count, 1)
        XCTAssertEqual(popped.messages.count, 1)
        XCTAssertEqual(popped.messages.first?.content, "from main")
    }

    func testMirrorSkipsOtherChats() {
        let pops = PopOutStore()
        let main = demoStore(chatID: "b")
        pops.bind(main: main)
        XCTAssertTrue(pops.pop(chatID: "a"))
        let popped = pops.store(for: "a")
        popped.showDemo(chatID: "a", chatName: "Chat", messages: [])
        // Main is on another chat: neither direction mirrors.
        main.send(text: "elsewhere")
        XCTAssertTrue(popped.messages.isEmpty)
        popped.send(text: "from pop-out")
        XCTAssertEqual(main.messages.count, 1) // only its own send
    }

    func testMirrorNoEchoLoop() {
        let pops = PopOutStore()
        let main = demoStore(chatID: "a")
        pops.bind(main: main)
        XCTAssertTrue(pops.pop(chatID: "a"))
        let popped = pops.store(for: "a")
        popped.showDemo(chatID: "a", chatName: "Chat", messages: [])
        main.send(text: "once")
        // Exactly one bubble per store (mirror is not re-mirrored).
        XCTAssertEqual(main.messages.count, 1)
        XCTAssertEqual(popped.messages.count, 1)
    }
}
