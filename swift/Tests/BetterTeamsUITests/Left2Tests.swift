// Left2Tests.swift — LEFT2 pins: Calls Remove from Recents and Speed
// Dial edits, To Do reopen, the Recaps turn under the playhead, file
// chips looked up by message, Files multi-select Copy Link. (Shifts week
// cache: P4bNativeAppsTests.testShiftsWeekNavigation; the Graph filter
// shape: ost `range_path_uses_documented_filter_and_keeps_overlaps`.)
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class Left2Tests: XCTestCase {
    private func waitUntil(_ cond: () -> Bool) async {
        for _ in 0 ..< 300 where !cond() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Remove from Recents drops the record (and hides a feed row) for
    /// good; Speed Dial reorders by drag offsets; a recent caller pins by
    /// AAD id, other MRI forms cannot pin.
    func testCallsRecentsAndSpeedDialEdits() {
        let defaults = MemoryDefaults()
        let history = CallHistoryStore(defaults: defaults, key: "left2")
        history.seedDemo()
        history.remove(recordIDs: ["demo-in"], feedIDs: ["missedCall:-:x"])
        XCTAssertEqual(history.records.map(\.id), ["demo-missed", "demo-out"])
        let reloaded = CallHistoryStore(defaults: defaults, key: "left2")
        XCTAssertEqual(reloaded.records.map(\.id), ["demo-missed", "demo-out"])
        XCTAssertEqual(reloaded.hiddenFeedIDs, ["missedCall:-:x"])

        let contacts = ContactsStore(peopleSearcher: { q, _ in DemoData.peopleSearchResponse(for: q) },
                                     defaults: defaults, pinKey: "left2.pins")
        for (name, id) in [("Ava Lindqvist", "u-a"), ("Tom Becker", "u-t"), ("Megan Harper", "u-m")] {
            contacts.pin(TeamMember(id: id, displayName: name, userId: id))
        }
        contacts.movePins(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(contacts.pinnedIDs, ["u-m", "u-a", "u-t"])
        contacts.movePins(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(contacts.pinnedIDs, ["u-a", "u-t", "u-m"])

        let caller = CallsSection.Person(name: "Maria Garcia", personID: "8:orgid:abc-1", personKey: "", thread: "")
        XCTAssertEqual(CallsSection.member(caller)?.userId, "abc-1")
        XCTAssertNil(CallsSection.member(CallsSection.Person(name: "Guest", personID: "8:teamsvisitor:x",
                                                            personKey: "", thread: "")))
    }

    /// A completed task reopens (checkbox or Mark as Incomplete); a
    /// list's rows stay on hand across a reload of that list.
    func testToDoReopen() async {
        let vm = RemindersViewModel(
            listsFetcher: { DemoData.remindersResponse() },
            tasksFetcher: { DemoData.reminderTasksResponse(for: $0) },
            localEdits: true)
        await vm.load()
        guard let open = vm.tasks.first(where: { !$0.completed }) else { return XCTFail("no open demo task") }
        vm.complete(taskID: open.taskId)
        XCTAssertTrue(vm.tasks.first { $0.taskId == open.taskId }?.completed ?? false)
        vm.reopen(taskID: open.taskId)
        let row = vm.tasks.first { $0.taskId == open.taskId }
        XCTAssertEqual(row?.completed, false)
        XCTAssertEqual(row?.status, "notStarted")
        XCTAssertEqual(vm.tasksListID, vm.selectedListID)
    }

    /// The highlighted turn is the one the playhead is inside.
    func testTranscriptTurnUnderPlayhead() {
        let cues = [TranscriptCue(id: 0, speaker: "Ava Lindqvist", startMs: 0, endMs: 4000, text: "Hello"),
                    TranscriptCue(id: 1, speaker: "Tom Becker", startMs: 5000, endMs: 9000, text: "Hi")]
        XCTAssertNil(TranscriptPlayhead.currentCueID(cues, at: nil))
        XCTAssertEqual(TranscriptPlayhead.currentCueID(cues, at: 0), 0)
        XCTAssertNil(TranscriptPlayhead.currentCueID(cues, at: 4500)) // between turns
        XCTAssertEqual(TranscriptPlayhead.currentCueID(cues, at: 8999), 1)
        XCTAssertNil(TranscriptPlayhead.currentCueID(cues, at: 9000))
    }

    /// A ref past the Shared list's first page resolves by message, once
    /// per message; demo never looks up.
    func testFileChipLookupByMessage() async {
        let asked = StringLog()
        let store = SharedFilesStore(messageFiles: { chat, message in
            asked.append(message)
            return SharedFilesResponse(ok: true, chat_id: chat, files: [
                SharedFile(id: "f9", name: "Plan.pdf", drive_id: "d1", attachment_id: "ATT-9"),
            ])
        })
        store.resolveAttachments(chatID: "19:c@thread.v2", messageID: "m1")
        store.resolveAttachments(chatID: "19:c@thread.v2", messageID: "m1")
        await waitUntil { !store.attachmentFiles.isEmpty }
        XCTAssertEqual(asked.all, ["m1"])
        XCTAssertEqual(InlineDocs.resolve(refs: ["ATT-9"], files: store.attachmentFiles).map(\.name), ["Plan.pdf"])
        store.showDemo(chatID: "demo-chat", files: [])
        store.resolveAttachments(chatID: "demo-chat", messageID: "m2")
        XCTAssertEqual(asked.all, ["m1"])
    }

    /// Copy Link on several rows copies every link once, one per line.
    func testFilesCopyLinkJoinsSelection() async {
        let copied = StringLog()
        let store = UnifiedFilesStore(link: { _, item, _ in SharedFileLinkResponse(ok: true, link: "https://x/\(item)") },
                                      copyLink: { copied.append($0) })
        let rows = ["a", "b"].map {
            UnifiedFileRow(file: SharedFile(id: $0, name: "\($0).txt", drive_id: "d1"), source: .drive,
                           sourceName: "OneDrive")
        }
        store.shareLinks(rows)
        await waitUntil { !copied.all.isEmpty }
        XCTAssertEqual(copied.all, ["https://x/a\nhttps://x/b"])
    }

    /// Calls ▸ person Video: offered on a 1:1 thread (known or not yet
    /// listed), refused on a group chat, a meeting thread, or no thread.
    func testPersonVideoOnlyOnOneOnOneThread() {
        let chats = ChatListViewModel(fetcher: { _ in ChatsResponse(ok: true, chats: []) })
        let graph = AccountWindowGraph(account: AccountRecord(id: "left2-video", displayName: "Test"), chats: chats)
        let m = WindowModel(graph: graph, accountKey: "left2-video", options: LaunchOptions(args: ["--evidence"]))
        m.graph.chats.insertLocally(ChatItem(chatId: "19:peer", name: "Ava Lindqvist"))
        m.graph.chats.insertLocally(ChatItem(chatId: "19:group", name: "Standup", is_group: true))
        func person(_ thread: String) -> CallsSection.Person {
            CallsSection.Person(name: "Ava Lindqvist", personID: "8:orgid:ava", personKey: "", thread: thread)
        }
        XCTAssertTrue(CallsSection.canVideo(person("19:peer"), m))
        XCTAssertTrue(CallsSection.canVideo(person("19:unlisted"), m))
        XCTAssertFalse(CallsSection.canVideo(person("19:group"), m))
        XCTAssertFalse(CallsSection.canVideo(person("19:meeting_abc"), m))
        XCTAssertFalse(CallsSection.canVideo(person(""), m))
    }
}

/// Strings a fake recorded (fakes run off-main).
private final class StringLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
