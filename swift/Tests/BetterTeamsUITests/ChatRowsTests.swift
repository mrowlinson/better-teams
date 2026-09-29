// ChatRowsTests.swift — CHATROWS: row state → style (unread bold, mute
// badge beside presence), unread clearing when read elsewhere, the
// meeting chat Recap match, bot 1:1 rows, and the demo seed rows.
import Foundation
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

@MainActor
final class ChatRowsTests: XCTestCase {
    func testReadRowIsRegularWithNoBadge() {
        let s = ChatRowStyle(unread: false, muted: false, hasPresence: true)
        XCTAssertEqual(s.nameWeight, .regular)
        XCTAssertEqual(s.previewWeight, .regular)
        XCTAssertEqual(s.timeWeight, .regular)
        XCTAssertFalse(s.previewPrimary)
        XCTAssertFalse(s.showsUnreadDot)
        XCTAssertNil(s.muteCorner)
    }

    func testUnreadRowBoldsNamePreviewAndTime() {
        let s = ChatRowStyle(unread: true, muted: false, hasPresence: false)
        XCTAssertEqual(s.nameWeight, .bold)
        XCTAssertEqual(s.previewWeight, .semibold)
        XCTAssertEqual(s.timeWeight, .semibold)
        XCTAssertTrue(s.previewPrimary)
        XCTAssertTrue(s.showsUnreadDot)
    }

    func testMuteBadgeTakesFreeCornerBesidePresence() {
        XCTAssertEqual(ChatRowStyle(unread: false, muted: true, hasPresence: false).muteCorner, .bottomTrailing)
        XCTAssertEqual(ChatRowStyle(unread: false, muted: true, hasPresence: true).muteCorner, .topTrailing)
        // Muted + unread: both treatments at once.
        let both = ChatRowStyle(unread: true, muted: true, hasPresence: true)
        XCTAssertEqual(both.nameWeight, .bold)
        XCTAssertEqual(both.muteCorner, .topTrailing)
    }

    func testLiveUnreadClearsWhenReadElsewhere() {
        let store = UnreadStore(dock: FakeDockBadge())
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        store.ingest(decision: .notify(reason: "x"), chatID: "c1", openChatID: nil, messageAt: at)
        XCTAssertTrue(store.isUnread(chatID: "c1"))
        // A list fetch still behind the live message leaves it unread.
        store.seed([UnreadSeed(chatID: "c1", unread: false, lastMessageAt: at.addingTimeInterval(-60))])
        XCTAssertTrue(store.isUnread(chatID: "c1"))
        // Teams says read through that message: read on another client.
        store.seed([UnreadSeed(chatID: "c1", unread: false, lastMessageAt: at)])
        XCTAssertFalse(store.isUnread(chatID: "c1"))
        XCTAssertEqual(store.total, 0)
        // A manual Mark as Unread is never cleared by a seed.
        store.ingest(decision: .notify(reason: "x"), chatID: "c2", openChatID: nil, messageAt: at)
        store.markUnread(chatID: "c2")
        store.seed([UnreadSeed(chatID: "c2", unread: false, lastMessageAt: at)])
        XCTAssertTrue(store.isUnread(chatID: "c2"))
    }

    func testMeetingChatRecapMatchesByMeetingTitle() {
        let rec = RecordingItem(id: "r1", name: "Platform Standup-20260912_093000-Meeting Recording.mp4",
                                created: "2026-09-12T09:30:00Z")
        let tr = TranscriptItem(id: "t1", name: "Platform Standup-20260912_093000-Meeting Recording.vtt",
                                created: "2026-09-12T09:30:00Z")
        let other = RecordingItem(id: "r2", name: "Design Crit with Megan Harper.mp4")
        let recaps = Recap.merge(recordings: [other, rec], transcripts: [tr])
        let hit = ChatRecapMatch.recap(forChatNamed: "Platform Standup", in: recaps)
        XCTAssertEqual(hit?.recording?.id, "r1")
        XCTAssertEqual(hit?.transcript?.id, "t1")
        XCTAssertNil(ChatRecapMatch.recap(forChatNamed: "Platform", in: recaps))
        XCTAssertNil(ChatRecapMatch.recap(forChatNamed: "  ", in: recaps))
        XCTAssertEqual(ChatRecapMatch.meetingKey("Design Crit with Megan Harper.mp4"), "designcritwithmeganharper")
        // Demo meeting chat has its recap.
        let demo = Recap.merge(recordings: RecordingsDemo.response().recordings,
                               transcripts: TranscriptsDemo.response().transcripts)
        XCTAssertNotNil(ChatRecapMatch.recap(forChatNamed: "Platform Standup", in: demo)?.recording)
    }

    func testBotOneToOneChatListsLikeTeams() {
        // Live-shaped bot 1:1 (mychats): pair id, bot MRI sender.
        let id = "19:6b1f2c3d-aaaa-4bbb-8ccc-0d1e2f3a4b5c_7c8d9e0f-1111-4222-8333-444455556666@unq.gbl.spaces"
        let bot = "28:7c8d9e0f-1111-4222-8333-444455556666"
        XCTAssertEqual(ChatKind.of(chatID: id, isGroup: false), .oneOnOne)
        XCTAssertEqual(ChatKind.of(chatID: bot, isGroup: false), .oneOnOne)
        let post = RealtimeMessage(chatID: id, msgId: "1", sender: "Workflows", senderID: bot,
                                   text: "Your approval is ready", time: "2026-09-28T10:00:00Z",
                                   isEdit: false, messageType: "RichText/Html")
        XCTAssertEqual(SidebarIngest.decide(message: post, chatName: "Workflows"), .bubble)
        let legacy = RealtimeMessage(chatID: bot, msgId: "2", sender: "Polly", senderID: bot,
                                     text: "Poll closed", time: "2026-09-28T10:01:00Z",
                                     isEdit: false, messageType: "Text")
        XCTAssertEqual(SidebarIngest.decide(message: legacy, chatName: "Polly"), .bubble)
        // A bot posting into a group thread still refreshes in place.
        let group = RealtimeMessage(chatID: "19:g@thread.v2", msgId: "3", sender: "Polly", senderID: bot,
                                    text: "Poll closed", time: "2026-09-28T10:02:00Z",
                                    isEdit: false, messageType: "Text")
        XCTAssertEqual(SidebarIngest.decide(message: group, chatName: "Team"), .refresh)
        let rows = ChatListViewModel.ingested(post, into: [
            ChatItem(chatId: "19:x@thread.v2", name: "Design Sync", is_group: true),
            ChatItem(chatId: id, name: "Workflows"),
        ])
        XCTAssertEqual(rows.first?.id, id)
        XCTAssertFalse(rows.first!.is_group)
    }

    func testDemoSeedsUnreadMutedRows() {
        let byID = Dictionary(uniqueKeysWithValues: DemoData.chats.map { ($0.id, $0) })
        XCTAssertEqual(byID["demo-2"]?.unread, true)
        XCTAssertEqual(byID["demo-3"]?.muted, true)
        XCTAssertEqual(byID[DemoData.tomID]?.muted, true)
        XCTAssertEqual(byID[DemoData.tomID]?.unread, true)
    }
}
