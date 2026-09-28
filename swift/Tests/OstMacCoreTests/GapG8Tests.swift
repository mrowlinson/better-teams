// GapG8Tests — gap-g8: channel/meeting/file pop-out registries.
//
// Channels reuse the chat PopOutStore (channel ids are conversation
// ids); meetings + files get their own registries mirroring the
// E1-POPOUT contract: one window per key, re-pop refuses (focus),
// live fan-out to popped only, close keeps stores/snapshots/drafts.
import XCTest

@testable import OstMacCore

@MainActor
final class GapG8Tests: XCTestCase {
    // MARK: channels (chat-registry reuse)

    func testChannelPopThroughChatRegistry() {
        let pops = PopOutStore()
        let channel = "19:abc123@thread.tacv2"
        XCTAssertTrue(ChannelTabsStore.isChannelID(channel))
        XCTAssertTrue(pops.pop(chatID: channel))
        XCTAssertTrue(pops.isPopped(chatID: channel))
        XCTAssertFalse(pops.pop(chatID: channel))
        pops.close(chatID: channel)
        XCTAssertFalse(pops.isPopped(chatID: channel))
    }

    func testChannelFanOutToPoppedOnly() {
        let pops = PopOutStore()
        pops.bind(main: ConversationStore())
        let channel = "19:abc123@thread.tacv2"
        XCTAssertTrue(pops.pop(chatID: channel))
        let popped = pops.store(for: channel)
        XCTAssertTrue(pops.ingest(realtime: realtime(chatID: channel)))
        XCTAssertEqual(popped.messages.count, 1)
        XCTAssertFalse(pops.ingest(realtime: realtime(chatID: "other")))
    }

    // MARK: meeting registry (single-window-per-key)

    func testMeetingPopAndRepop() {
        let pops = meetingPops()
        XCTAssertTrue(pops.pop(key: "m1", subject: "Standup"))
        XCTAssertTrue(pops.isPopped(key: "m1"))
        // Second pop refuses (focus instead — no dup).
        XCTAssertFalse(pops.pop(key: "m1", subject: "Standup"))
        XCTAssertEqual(pops.poppedKeys, ["m1"])
    }

    func testMeetingPopBlankRefuses() {
        let pops = meetingPops()
        XCTAssertFalse(pops.pop(key: "  "))
        XCTAssertTrue(pops.poppedKeys.isEmpty)
    }

    func testMeetingCloseKeepsStoresDraftName() {
        let pops = meetingPops()
        XCTAssertTrue(pops.pop(key: "m1", subject: "Standup"))
        let chat = pops.chatStore(for: "m1")
        let roster = pops.rosterStore(for: "m1")
        pops.saveDraft("hello", for: "m1")
        pops.close(key: "m1")
        XCTAssertFalse(pops.isPopped(key: "m1"))
        // Stores + draft + name survive (re-pop restores, no reload).
        XCTAssertTrue(pops.chatStore(for: "m1") === chat)
        XCTAssertTrue(pops.rosterStore(for: "m1") === roster)
        XCTAssertEqual(pops.draft(for: "m1"), "hello")
        XCTAssertEqual(pops.name(for: "m1"), "Standup")
    }

    func testMeetingDraftSaveRestorePurge() {
        let pops = meetingPops()
        XCTAssertEqual(pops.draft(for: "m1"), "")
        pops.saveDraft("hi", for: "m1")
        XCTAssertEqual(pops.draft(for: "m1"), "hi")
        pops.saveDraft("  ", for: "  ") // blank key: no-op
        pops.purgeDraft(for: "m1")
        XCTAssertEqual(pops.draft(for: "m1"), "")
        pops.purgeDraft(for: "nope") // unknown: no-op
    }

    func testMeetingNameFallbacks() {
        let pops = meetingPops()
        // No subject, unopened: the key itself (list-miss precedent).
        XCTAssertTrue(pops.pop(key: "m9"))
        XCTAssertEqual(pops.name(for: "m9"), "m9")
        // Blank subjects never overwrite a cached name.
        XCTAssertTrue(pops.pop(key: "m10", subject: "Crit"))
        XCTAssertFalse(pops.pop(key: "m10", subject: "  "))
        XCTAssertEqual(pops.name(for: "m10"), "Crit")
    }

    // MARK: meeting chat fan-out

    func testMeetingFanOutToPoppedThread() {
        let pops = meetingPops()
        let thread = "19:meeting_aaa@thread.v2"
        XCTAssertTrue(pops.pop(key: thread, subject: "Sync"))
        let store = pops.chatStore(for: thread)
        store.showDemo(threadID: thread, chatName: "Sync", messages: [])
        XCTAssertTrue(pops.ingest(realtime: realtime(chatID: thread)))
        XCTAssertEqual(store.messages.count, 1)
    }

    func testMeetingFanOutIgnoresUnpopped() {
        let pops = meetingPops()
        let thread = "19:meeting_aaa@thread.v2"
        XCTAssertTrue(pops.pop(key: thread))
        pops.chatStore(for: thread).showDemo(
            threadID: thread, chatName: "Sync", messages: [])
        XCTAssertFalse(pops.ingest(
            realtime: realtime(chatID: "19:meeting_bbb@thread.v2")))
        XCTAssertTrue(pops.chatStore(for: thread).messages.isEmpty)
    }

    func testMeetingFanOutStopsAfterClose() {
        let pops = meetingPops()
        let thread = "19:meeting_aaa@thread.v2"
        XCTAssertTrue(pops.pop(key: thread))
        let store = pops.chatStore(for: thread)
        store.showDemo(threadID: thread, chatName: "Sync", messages: [])
        pops.close(key: thread)
        XCTAssertFalse(pops.ingest(realtime: realtime(chatID: thread)))
        XCTAssertTrue(store.messages.isEmpty)
    }

    func testMeetingFanOutNoCrossTalk() {
        let pops = meetingPops()
        let a = "19:meeting_aaa@thread.v2"
        let b = "19:meeting_bbb@thread.v2"
        XCTAssertTrue(pops.pop(key: a))
        XCTAssertTrue(pops.pop(key: b))
        pops.chatStore(for: a).showDemo(
            threadID: a, chatName: "A", messages: [])
        pops.chatStore(for: b).showDemo(
            threadID: b, chatName: "B", messages: [])
        XCTAssertTrue(pops.ingest(realtime: realtime(chatID: a)))
        XCTAssertEqual(pops.chatStore(for: a).messages.count, 1)
        XCTAssertTrue(pops.chatStore(for: b).messages.isEmpty)
    }

    func testMeetingCalendarKeyAdoptsThread() {
        let pops = meetingPops()
        XCTAssertTrue(pops.pop(key: "cal-1", subject: "Planning"))
        let thread = "19:meeting_live@thread.v2"
        XCTAssertTrue(pops.ingest(realtime: realtime(chatID: thread)))
        // Pre-thread key adopts on first sight (main-panel parity).
        let store = pops.chatStore(for: "cal-1")
        XCTAssertEqual(store.threadID, thread)
        XCTAssertEqual(store.messages.count, 1)
    }

    func testMeetingSingleAdopter() {
        let pops = meetingPops()
        XCTAssertTrue(pops.pop(key: "cal-a"))
        XCTAssertTrue(pops.pop(key: "cal-b"))
        let thread = "19:meeting_live@thread.v2"
        XCTAssertTrue(pops.ingest(realtime: realtime(chatID: thread)))
        // Sorted-first adopts; the other stays unclaimed (never the
        // wrong meeting).
        XCTAssertEqual(pops.chatStore(for: "cal-a").threadID, thread)
        XCTAssertNil(pops.chatStore(for: "cal-b").threadID)
        XCTAssertTrue(pops.chatStore(for: "cal-b").messages.isEmpty)
    }

    func testMeetingThreadKeyNeverAdoptsOther() {
        let pops = meetingPops()
        // Claimed thread key ignores other threads.
        let a = "19:meeting_aaa@thread.v2"
        XCTAssertTrue(pops.pop(key: a))
        pops.chatStore(for: a).showDemo(
            threadID: a, chatName: "A", messages: [])
        XCTAssertFalse(pops.ingest(
            realtime: realtime(chatID: "19:meeting_bbb@thread.v2")))
        // Unclaimed thread key ignores other threads too (a popped
        // thread never adopts — only calendar keys do).
        let c = "19:meeting_ccc@thread.v2"
        XCTAssertTrue(pops.pop(key: c))
        XCTAssertFalse(pops.ingest(
            realtime: realtime(chatID: "19:meeting_ddd@thread.v2")))
        XCTAssertNil(pops.chatStore(for: c).threadID)
        XCTAssertTrue(pops.chatStore(for: a).messages.isEmpty)
    }

    // MARK: meeting roster fan-out

    func testRosterFanOut() {
        let pops = meetingPops()
        XCTAssertTrue(pops.pop(key: "m1", subject: "Standup"))
        let roster = pops.rosterStore(for: "m1")
        XCTAssertTrue(pops.ingest(roster: MeetingRosterEvent(
            meetingID: "m1", id: "p1", name: "Megan")))
        XCTAssertEqual(roster.participants.count, 1)
    }

    func testRosterIgnoresUnattributed() {
        let pops = meetingPops()
        XCTAssertTrue(pops.pop(key: "m1"))
        XCTAssertFalse(pops.ingest(roster: MeetingRosterEvent(
            meetingID: "", id: "p1", name: "Megan")))
        XCTAssertTrue(pops.rosterStore(for: "m1").participants.isEmpty)
    }

    func testRosterStopsAfterClose() {
        let pops = meetingPops()
        XCTAssertTrue(pops.pop(key: "m1"))
        let roster = pops.rosterStore(for: "m1")
        pops.close(key: "m1")
        XCTAssertFalse(pops.ingest(roster: MeetingRosterEvent(
            meetingID: "m1", id: "p1", name: "Megan")))
        XCTAssertTrue(roster.participants.isEmpty)
    }

    func testRosterNoCrossTalk() {
        let pops = meetingPops()
        XCTAssertTrue(pops.pop(key: "m1"))
        XCTAssertTrue(pops.pop(key: "m2"))
        XCTAssertTrue(pops.ingest(roster: MeetingRosterEvent(
            meetingID: "m1", id: "p1", name: "Megan")))
        XCTAssertEqual(pops.rosterStore(for: "m1").participants.count, 1)
        XCTAssertTrue(pops.rosterStore(for: "m2").participants.isEmpty)
    }

    func testMeetingValueCodable() throws {
        let v = MeetingPopoutValue(key: "m1")
        let data = try JSONEncoder().encode(v)
        XCTAssertEqual(try JSONDecoder().decode(
            MeetingPopoutValue.self, from: data), v)
    }

    // MARK: file registry (single-window-per-file)

    func testFileKeySplitRoundTrip() {
        let k = FilePopOutStore.key(chatID: "c1", fileID: "f1")
        let (chat, file) = FilePopOutStore.split(k)
        XCTAssertEqual(chat, "c1")
        XCTAssertEqual(file, "f1")
        // Keys without the separator read as ("", key).
        XCTAssertEqual(FilePopOutStore.split("raw").chatID, "")
        XCTAssertEqual(FilePopOutStore.split("raw").fileID, "raw")
    }

    func testFilePopAndRepop() {
        let pops = FilePopOutStore()
        let file = sharedFile(id: "f1", name: "a.pdf")
        let v = pops.pop(chatID: "c1", file: file)
        XCTAssertNotNil(v)
        XCTAssertEqual(
            v?.key, FilePopOutStore.key(chatID: "c1", fileID: "f1"))
        XCTAssertTrue(pops.isPopped(key: v!.key))
        // Second pop refuses (focus instead — no dup).
        XCTAssertNil(pops.pop(chatID: "c1", file: file))
        XCTAssertEqual(pops.poppedKeys, [v!.key])
    }

    func testFilePopBlankRefuses() {
        let pops = FilePopOutStore()
        XCTAssertNil(pops.pop(
            chatID: "c1",
            file: sharedFile(id: "  ", name: "x")))
        XCTAssertTrue(pops.poppedKeys.isEmpty)
    }

    func testFileCloseKeepsSnapshot() {
        let pops = FilePopOutStore()
        let file = sharedFile(id: "f1", name: "a.pdf")
        let v = pops.pop(chatID: "c1", file: file)!
        pops.close(key: v.key)
        XCTAssertFalse(pops.isPopped(key: v.key))
        // Snapshot survives (re-pop restores, no refetch).
        XCTAssertEqual(pops.entry(for: v.key)?.file, file)
        XCTAssertEqual(pops.entry(for: v.key)?.chatID, "c1")
    }

    func testFileRefreshUpdatesSnapshot() {
        let pops = FilePopOutStore()
        let v = pops.pop(
            chatID: "c1", file: sharedFile(id: "f1", name: "a.pdf"))!
        let renamed = sharedFile(id: "f1", name: "b.pdf")
        XCTAssertTrue(pops.refresh(chatID: "c1", files: [renamed]))
        XCTAssertEqual(pops.entry(for: v.key)?.file.name, "b.pdf")
        // No change → false, no revision churn.
        XCTAssertFalse(pops.refresh(chatID: "c1", files: [renamed]))
    }

    func testFileRefreshIgnoresOtherChats() {
        let pops = FilePopOutStore()
        let v = pops.pop(
            chatID: "c1", file: sharedFile(id: "f1", name: "a.pdf"))!
        XCTAssertFalse(pops.refresh(
            chatID: "c2",
            files: [sharedFile(id: "f1", name: "b.pdf")]))
        XCTAssertEqual(pops.entry(for: v.key)?.file.name, "a.pdf")
    }

    func testFileRefreshMissingKeepsSnapshot() {
        let pops = FilePopOutStore()
        let v = pops.pop(
            chatID: "c1", file: sharedFile(id: "f1", name: "a.pdf"))!
        // Dropped from the list: the preview keeps its last snapshot
        // (never blanks under a refresh).
        XCTAssertFalse(pops.refresh(chatID: "c1", files: []))
        XCTAssertEqual(pops.entry(for: v.key)?.file.name, "a.pdf")
    }

    func testFileRefreshAfterCloseUpdatesCache() {
        let pops = FilePopOutStore()
        let v = pops.pop(
            chatID: "c1", file: sharedFile(id: "f1", name: "a.pdf"))!
        pops.close(key: v.key)
        XCTAssertTrue(pops.refresh(
            chatID: "c1",
            files: [sharedFile(id: "f1", name: "b.pdf")]))
        XCTAssertFalse(pops.isPopped(key: v.key))
        XCTAssertEqual(pops.entry(for: v.key)?.file.name, "b.pdf")
    }

    func testFileValueCodable() throws {
        let v = FilePopoutValue(key: "c1\nf1")
        let data = try JSONEncoder().encode(v)
        XCTAssertEqual(try JSONDecoder().decode(
            FilePopoutValue.self, from: data), v)
    }

    // MARK: helpers

    /// Registry with memory-backed chat persistence (never disk/core).
    func meetingPops() -> MeetingPopOutStore {
        MeetingPopOutStore(
            makeChat: {
                MeetingChatStore(
                    load: { _ in [] }, save: { _, _ in },
                    delete: { _ in })
            },
            makeRoster: { MeetingRosterStore() })
    }

    func realtime(
        chatID: String, msgId: String = "m1",
        sender: String = "Megan Harper", text: String = "hello"
    ) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chatID, msgId: msgId, sender: sender,
            senderID: "8:orgid:megan", text: text,
            time: "2026-09-23T10:00:00Z", isEdit: false,
            messageType: "Text")
    }

    func sharedFile(id: String, name: String) -> SharedFile {
        SharedFile(id: id, name: name, size: 100)
    }
}
