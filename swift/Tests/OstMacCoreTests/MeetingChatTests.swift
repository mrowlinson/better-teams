// MeetingChatTests.swift — om-meet-chat lane: roster ingest,
// speaking/mute states, chat persist, envelope decode, feed dispatch.
import XCTest

@testable import OstMacCore

/// In-memory persistence box (the store's seam, no disk).
final class MemoryMeetingStore: @unchecked Sendable {
    var snapshots: [String: [ChatMessage]] = [:]
}

@MainActor
final class MeetingChatTests: XCTestCase {
    private let meetA = "19:meeting_aaa@thread.v2"
    private let meetB = "19:meeting_bbb@thread.v2"
    private let plain = "19:plain@thread.v2"

    private func memory() -> (MemoryMeetingStore, MeetingChatStore) {
        let box = MemoryMeetingStore()
        let store = MeetingChatStore(
            load: { box.snapshots[$0] ?? [] },
            save: { box.snapshots[$0] = $1 },
            delete: { box.snapshots.removeValue(forKey: $0) })
        return (box, store)
    }

    private func pollWithRoster() throws -> RealtimePoll {
        let json = """
        {"ok":true,"resync":false,"skipped":0,"messages":[],
        "roster":[
        {"meeting_id":"\(meetA)","id":"8:orgid:aaa","name":"Doe, Jane",
         "speaking":true,"muted":false,"present":true},
        {"meeting_id":"\(meetA)","id":"8:orgid:bbb","name":"Smith, Bob",
         "muted":true}]}
        """
        return try decodeOrThrow(RealtimePoll.self, from: Data(json.utf8))
    }

    // MARK: - Envelope + feed

    func testRosterEnvelopeDecode() throws {
        let p = try pollWithRoster()
        let roster = try XCTUnwrap(p.roster)
        XCTAssertEqual(roster.count, 2)
        XCTAssertEqual(roster[0].meetingID, meetA)
        XCTAssertEqual(roster[0].id, "8:orgid:aaa")
        XCTAssertEqual(roster[0].speaking, true)
        XCTAssertEqual(roster[0].muted, false)
        XCTAssertEqual(roster[0].present, true)
        XCTAssertNil(roster[1].speaking) // frame silent: host keeps
        XCTAssertTrue(roster[0].isFor(meetingID: meetA))
        XCTAssertFalse(roster[0].isFor(meetingID: meetB))
        XCTAssertFalse(roster[0].isFor(meetingID: nil))
        let bare = MeetingRosterEvent(id: "8:x", name: "X")
        XCTAssertFalse(bare.isFor(meetingID: meetA)) // empty never matches
    }

    func testOldCoreWithoutRosterDecodesAsNil() throws {
        let json = #"{"ok":true,"resync":false,"skipped":0,"messages":[]}"#
        let p = try decodeOrThrow(RealtimePoll.self, from: Data(json.utf8))
        XCTAssertNil(p.roster)
        let feed = RealtimeFeed(poll: { p })
        let n = LockedBox(0)
        feed.onRoster { _ in n.mutate { $0 += 1 } }
        _ = try feed.pollOnce()
        XCTAssertEqual(n.value, 0)
    }

    func testFeedDispatchesRosterWithoutDedupe() throws {
        let p = try pollWithRoster()
        let feed = RealtimeFeed(poll: { p })
        let got = LockedBox<[String]>([])
        feed.onRoster { r in got.mutate { $0.append(r.id) } }
        _ = try feed.pollOnce()
        XCTAssertEqual(got.value, ["8:orgid:aaa", "8:orgid:bbb"])
        // Repeats are state refreshes: redelivery dispatches again.
        _ = try feed.pollOnce()
        XCTAssertEqual(got.value, ["8:orgid:aaa", "8:orgid:bbb", "8:orgid:aaa", "8:orgid:bbb"])
    }

    // MARK: - Roster ingest

    func testRosterIngestUpsertsInPlace() {
        let store = MeetingRosterStore()
        store.ingest(MeetingRosterEvent(meetingID: meetA, id: "8:a", name: "A"))
        store.ingest(MeetingRosterEvent(meetingID: meetA, id: "8:b", name: "B", muted: true))
        XCTAssertEqual(store.participants.map(\.id), ["8:a", "8:b"])
        XCTAssertEqual(store.meetingID, meetA)
        // Update merges in place: order kept, axes merged.
        store.ingest(MeetingRosterEvent(meetingID: meetA, id: "8:a", name: "A New", muted: true))
        XCTAssertEqual(store.participants.map(\.id), ["8:a", "8:b"])
        XCTAssertEqual(store.participants[0].name, "A New")
        XCTAssertTrue(store.participants[0].muted)
        XCTAssertFalse(store.participants[0].speaking)
    }

    func testRosterIgnoresEmptyIDs() {
        let store = MeetingRosterStore()
        store.ingest(MeetingRosterEvent(meetingID: meetA, id: "  ", name: "Ghost"))
        XCTAssertTrue(store.participants.isEmpty)
        XCTAssertNil(store.meetingID)
    }

    func testRosterEmptyNameKeepsLastKnown() {
        let store = MeetingRosterStore()
        store.ingest(MeetingRosterEvent(meetingID: meetA, id: "8:a", name: "A"))
        // Speaker-only marker (empty name) must never blank the row.
        store.ingest(MeetingRosterEvent(meetingID: meetA, id: "8:a", name: "", speaking: true))
        XCTAssertEqual(store.participants[0].name, "A")
        XCTAssertTrue(store.participants[0].speaking)
        // A brand-new id with no name still gets the missing marker.
        store.ingest(MeetingRosterEvent(meetingID: meetA, id: "8:b", name: ""))
        XCTAssertEqual(store.participants[1].name, "?")
    }

    func testSpeakingSolosAcrossRows() {
        let store = MeetingRosterStore()
        store.ingest([
            MeetingRosterEvent(meetingID: meetA, id: "8:a", name: "A", speaking: true),
            MeetingRosterEvent(meetingID: meetA, id: "8:b", name: "B"),
        ])
        XCTAssertEqual(store.speaking.map(\.id), ["8:a"])
        XCTAssertEqual(store.speakingCount, 1)
        // New speaker steals the light; the old row clears.
        store.ingest(MeetingRosterEvent(meetingID: meetA, id: "8:b", name: "B", speaking: true))
        XCTAssertEqual(store.speaking.map(\.id), ["8:b"])
        // Speaking=false clears that row only.
        store.ingest(MeetingRosterEvent(meetingID: meetA, id: "8:b", name: "B", speaking: false))
        XCTAssertTrue(store.speaking.isEmpty)
        XCTAssertEqual(store.activeCount, 2)
    }

    func testMuteStatesMergeAndPreserve() {
        let store = MeetingRosterStore()
        store.ingest(MeetingRosterEvent(meetingID: meetA, id: "8:a", name: "A", muted: false))
        XCTAssertFalse(store.participants[0].muted)
        XCTAssertEqual(store.mutedCount, 0)
        store.ingest(MeetingRosterEvent(meetingID: meetA, id: "8:a", name: "A", muted: true))
        XCTAssertTrue(store.participants[0].muted)
        XCTAssertEqual(store.mutedCount, 1)
        // Nil mute (speaker marker) preserves the last-known state.
        store.ingest(MeetingRosterEvent(meetingID: meetA, id: "8:a", name: "A", speaking: true))
        XCTAssertTrue(store.participants[0].muted)
        store.ingest(MeetingRosterEvent(meetingID: meetA, id: "8:a", name: "A", muted: false))
        XCTAssertFalse(store.participants[0].muted)
    }

    func testLeaveRemovesUnknownLeaveNoops() {
        let store = MeetingRosterStore()
        store.ingest([
            MeetingRosterEvent(meetingID: meetA, id: "8:a", name: "A"),
            MeetingRosterEvent(meetingID: meetA, id: "8:b", name: "B"),
        ])
        store.ingest(MeetingRosterEvent(meetingID: meetA, id: "8:a", name: "A", present: false))
        XCTAssertEqual(store.participants.map(\.id), ["8:b"])
        store.ingest(MeetingRosterEvent(meetingID: meetA, id: "8:zzz", name: "?", present: false))
        XCTAssertEqual(store.participants.map(\.id), ["8:b"])
    }

    func testMeetingSwitchResetsUnattributedApplies() {
        let store = MeetingRosterStore()
        store.ingest(MeetingRosterEvent(meetingID: meetA, id: "8:a", name: "A"))
        // Another meeting id resets the roster first (single meeting).
        store.ingest(MeetingRosterEvent(meetingID: meetB, id: "8:b", name: "B"))
        XCTAssertEqual(store.participants.map(\.id), ["8:b"])
        XCTAssertEqual(store.meetingID, meetB)
        // Unattributed frames apply to the open roster.
        store.ingest(MeetingRosterEvent(id: "8:c", name: "C"))
        XCTAssertEqual(store.participants.map(\.id), ["8:b", "8:c"])
        XCTAssertEqual(store.meetingID, meetB)
    }

    func testNoteMeetingEndedClearsSpeaking() {
        let store = MeetingRosterStore()
        store.ingest(MeetingRosterEvent(meetingID: meetA, id: "8:a", name: "A", speaking: true))
        store.noteMeetingEnded()
        XCTAssertFalse(store.participants[0].speaking)
        XCTAssertEqual(store.activeCount, 1) // rows stay (last known)
    }

    func testRosterClear() {
        let store = MeetingRosterStore()
        store.ingest(MeetingRosterEvent(meetingID: meetA, id: "8:a", name: "A"))
        store.clear()
        XCTAssertTrue(store.participants.isEmpty)
        XCTAssertNil(store.meetingID)
    }

    func testRosterRowFormat() {
        XCTAssertEqual(MeetingRosterFormat.micIcon(muted: true), "mic.slash.fill")
        XCTAssertEqual(MeetingRosterFormat.micIcon(muted: false), "mic.fill")
        let p = MeetingParticipant(id: "8:a", name: "A", speaking: true, muted: true)
        XCTAssertEqual(MeetingRosterFormat.accessibilityLabel(for: p), "A, muted, speaking")
        let q = MeetingParticipant(id: "8:b", name: "B")
        XCTAssertEqual(MeetingRosterFormat.accessibilityLabel(for: q), "B, unmuted")
    }

    // MARK: - Meeting chat persist

    func testChatMessageCodableRoundTrip() throws {
        let m = ChatMessage(
            id: "m1", sender: "Doe, Jane", timestamp: "2026-09-22T14:25:45Z",
            content: "hi", isOwn: true, raw: "<p>hi</p>",
            reactions: [ReactionCount(emoji: "👍", count: 2)], reply_to: "m0")
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(back.id, "m1")
        XCTAssertEqual(back.content, "hi")
        XCTAssertEqual(back.raw, "<p>hi</p>")
        XCTAssertEqual(back.reactions, [ReactionCount(emoji: "👍", count: 2)])
        XCTAssertEqual(back.reply_to, "m0")
        XCTAssertFalse(back.isOwn) // host-side: re-stamped on load
    }

    func testDemoSendPersistsAndReloads() {
        let (box, store) = memory()
        store.showDemo(threadID: meetA, chatName: "Standup", messages: MeetingDemo.messages)
        store.send(text: "noted")
        XCTAssertEqual(box.snapshots[meetA]?.count, MeetingDemo.messages.count + 1)
        // A fresh store over the same persistence restores the thread.
        let box2 = MemoryMeetingStore()
        box2.snapshots = box.snapshots
        let store2 = MeetingChatStore(
            load: { box2.snapshots[$0] ?? [] },
            save: { box2.snapshots[$0] = $1 },
            delete: { box2.snapshots.removeValue(forKey: $0) })
        store2.open(threadID: meetA) // snapshot shows synchronously
        XCTAssertEqual(store2.messages.count, MeetingDemo.messages.count + 1)
        XCTAssertEqual(store2.messages.last?.content, "noted")
        XCTAssertTrue(store2.meetingActive)
    }

    func testIngestAdoptsMeetingThreadOnly() {
        let (_, store) = memory()
        let live = RealtimeMessage(
            chatID: meetA, msgId: "m9", sender: "Doe, Jane",
            text: "hello", time: "2026-09-22T14:25:45Z", isEdit: false)
        store.ingestIfMeeting(realtime: live)
        XCTAssertEqual(store.threadID, meetA) // adopted on first sight
        XCTAssertTrue(store.messages.contains(where: { $0.id == "m9" }))
        XCTAssertTrue(store.meetingActive)
        // Plain threads never adopt.
        let (_, store2) = memory()
        let other = RealtimeMessage(
            chatID: plain, msgId: "m1", sender: "X",
            text: "hi", time: "", isEdit: false)
        store2.ingestIfMeeting(realtime: other)
        XCTAssertNil(store2.threadID)
        XCTAssertTrue(store2.messages.isEmpty)
    }

    func testIngestRoutesOnlyToOpenThread() {
        let (_, store) = memory()
        store.showDemo(threadID: meetA, chatName: "Standup", messages: [])
        let match = RealtimeMessage(
            chatID: meetA, msgId: "m1", sender: "A",
            text: "hi", time: "", isEdit: false)
        let miss = RealtimeMessage(
            chatID: meetB, msgId: "m2", sender: "B",
            text: "other", time: "", isEdit: false)
        store.ingestIfMeeting(realtime: match)
        store.ingestIfMeeting(realtime: miss)
        XCTAssertEqual(store.messages.map(\.id), ["m1"])
    }

    func testIngestPersistsAndEditsInPlace() {
        let (box, store) = memory()
        store.showDemo(threadID: meetA, chatName: "Standup", messages: [])
        store.ingestIfMeeting(realtime: RealtimeMessage(
            chatID: meetA, msgId: "m1", sender: "A",
            text: "v1", time: "", isEdit: false))
        XCTAssertEqual(box.snapshots[meetA]?.count, 1)
        store.ingestIfMeeting(realtime: RealtimeMessage(
            chatID: meetA, msgId: "m2", sender: "A",
            text: "v2", time: "", isEdit: true, editedID: "m1"))
        XCTAssertEqual(store.messages.count, 1) // edit collapses in place
        XCTAssertEqual(store.messages.first?.content, "v2")
        XCTAssertEqual(box.snapshots[meetA]?.first?.content, "v2")
    }

    func testEndMeetingKeepsPersistedThread() {
        let (box, store) = memory()
        store.showDemo(threadID: meetA, chatName: "Standup", messages: MeetingDemo.messages)
        store.endMeeting()
        XCTAssertFalse(store.meetingActive)
        XCTAssertEqual(store.messages.count, MeetingDemo.messages.count)
        XCTAssertEqual(box.snapshots[meetA]?.count, MeetingDemo.messages.count)
        XCTAssertEqual(store.headerTitle, "Standup")
    }

    func testClearDropsMemoryAndDisk() {
        let (box, store) = memory()
        store.showDemo(threadID: meetA, chatName: "Standup", messages: MeetingDemo.messages)
        store.send(text: "x") // demo send persists
        XCTAssertNotNil(box.snapshots[meetA])
        store.clear()
        XCTAssertNil(store.threadID)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertNil(box.snapshots[meetA])
    }

    func testMergeKeepsLiveOnly() {
        let history = [ChatMessage(id: "h1", sender: "A", timestamp: "", content: "old")]
        let live = [
            ChatMessage(id: "h1", sender: "A", timestamp: "", content: "old"),
            ChatMessage(id: "pending-1", sender: "Me", timestamp: "", content: "fresh", isOwn: true),
        ]
        let merged = MeetingChatStore.merge(history: history, keeping: live)
        XCTAssertEqual(merged.map(\.id), ["h1", "pending-1"])
    }

    func testFileNameSanitizes() {
        XCTAssertEqual(MeetingChatStore.fileName(for: "19:meeting_x@thread.v2"), "19_meeting_x_thread_v2.json")
        XCTAssertEqual(MeetingChatStore.fileName(for: ""), "meeting.json")
        XCTAssertTrue(MeetingChatStore.fileName(for: String(repeating: "a", count: 500)).count <= 125)
    }

    func testHeaderTitleFallback() {
        let (_, store) = memory()
        XCTAssertEqual(store.headerTitle, "Meeting chat") // never the raw id
    }

    // MARK: - Diagnostics lines

    func testDiagnosticsLines() {
        XCTAssertEqual(
            DiagnosticsFormat.rosterLine(events: 3, active: 2, speaking: 1, muted: 1),
            "3 events · 2 in roster · 1 speaking · 1 muted")
        XCTAssertEqual(DiagnosticsFormat.meetingThreadLine(messages: 5, live: true), "5 messages · live")
        XCTAssertEqual(DiagnosticsFormat.meetingThreadLine(messages: 5, live: false), "5 messages · ended")
    }

    // MARK: - Meetings dir rename (om-meetings-dirname)

    private func scratchAppSupport() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("om-meetings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func testMeetingsBaseURLUsesAppIdentityName() throws {
        let base = try scratchAppSupport()
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(
            MeetingChatStore.meetingsBaseURL(under: base).path,
            base.appendingPathComponent("Better Teams/meetings").path)
        XCTAssertEqual(
            MeetingChatStore.legacyMeetingsBaseURL(under: base).path,
            base.appendingPathComponent(
                "D" + "iet Teams" + "/meetings").path)
    }

    func testMigrateMovesLegacyDirWithAccountSubdir() throws {
        let base = try scratchAppSupport()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let legacy = MeetingChatStore.legacyMeetingsBaseURL(under: base)
        let acctDir = AccountProfile.dir(legacy, for: "acct-1")
        try fm.createDirectory(at: acctDir, withIntermediateDirectories: true)
        try Data("t".utf8).write(to: legacy.appendingPathComponent("t.json"))
        try Data("a".utf8).write(to: acctDir.appendingPathComponent("a.json"))
        XCTAssertTrue(MeetingChatStore.migrateLegacyDirectory(under: base))
        let fresh = MeetingChatStore.meetingsBaseURL(under: base)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        XCTAssertEqual(try Data(contentsOf: fresh.appendingPathComponent("t.json")), Data("t".utf8))
        XCTAssertEqual(
            try Data(contentsOf: AccountProfile.dir(fresh, for: "acct-1").appendingPathComponent("a.json")),
            Data("a".utf8))
        XCTAssertFalse(MeetingChatStore.migrateLegacyDirectory(under: base)) // idempotent
    }

    func testMigrateNoopWhenLegacyMissing() throws {
        let base = try scratchAppSupport()
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertFalse(MeetingChatStore.migrateLegacyDirectory(under: base))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: MeetingChatStore.meetingsBaseURL(under: base).path))
    }

    func testMigrateNoopWhenNewDirExists() throws {
        let base = try scratchAppSupport()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let legacy = MeetingChatStore.legacyMeetingsBaseURL(under: base)
        let fresh = MeetingChatStore.meetingsBaseURL(under: base)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        try Data("n".utf8).write(to: fresh.appendingPathComponent("n.json"))
        try Data("l".utf8).write(to: legacy.appendingPathComponent("l.json"))
        XCTAssertFalse(MeetingChatStore.migrateLegacyDirectory(under: base))
        XCTAssertEqual(try Data(contentsOf: fresh.appendingPathComponent("n.json")), Data("n".utf8))
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("l.json")), Data("l".utf8))
    }
}
