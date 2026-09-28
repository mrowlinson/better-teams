// StableReloadTests.swift — STABLEUI pins: a background refresh never
// clears rows already on screen (conversation resync merge, unified
// Files failed refresh).
import XCTest

@testable import OstMacCore

@MainActor
final class StableReloadTests: XCTestCase {
    private func msg(_ id: String) -> ChatMessage {
        ChatMessage(id: id, sender: "Tom Becker", timestamp: "t", content: id)
    }

    /// Resync merge: older pages stay, the newest window is replaced
    /// (a deleted row inside it goes, an edit lands), pending sends stay.
    func testMergedNewestKeepsOlderRowsAndPendingSends() {
        let list = ["m1", "m2", "m3", "m4", "pending-a"].map(msg)
        var edited = msg("m3")
        edited.content = "edited"
        let page = [edited, msg("m5")] // m4 deleted server-side
        let merged = ConversationStore.mergedNewest(page, into: list)
        XCTAssertEqual(merged.map(\.id), ["m1", "m2", "m3", "m5", "pending-a"])
        XCTAssertEqual(merged[2].content, "edited")
        // No overlap (gap wider than a page): loaded rows stay ahead.
        XCTAssertEqual(ConversationStore.mergedNewest([msg("m9")], into: list).map(\.id),
                       ["m1", "m2", "m3", "m4", "pending-a", "m9"])
        // Empty page never clears.
        XCTAssertEqual(ConversationStore.mergedNewest([], into: list), list)
    }

    /// A Files refresh where every source fails keeps the rows on screen.
    func testUnifiedFilesFailedRefreshKeepsRows() async {
        final class Flag: @unchecked Sendable { var fail = false }
        let flag = Flag()
        let file = SharedFile(id: "c1", name: "chat-deck.pdf", size: 100, mime: "application/pdf",
                              web_url: "https://w/chat-deck", drive_id: "D1",
                              modified: "2026-09-22T10:00:00Z", sender: "Tom Becker")
        let store = UnifiedFilesStore(
            list: { id, _ in
                if flag.fail { throw CoreCallError.failed("files: boom") }
                return SharedFilesResponse(ok: true, chat_id: id, files: [file])
            },
            recents: { _ in
                if flag.fail { throw CoreCallError.failed("recents: boom") }
                return DriveRecentsResponse(ok: true, files: [])
            })
        func settle() async {
            for _ in 0 ..< 100 where store.state == .loading {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        store.load(chats: [("chat-1", "Design Sync")], channels: [])
        await settle()
        XCTAssertEqual(store.rows.map(\.file.name), ["chat-deck.pdf"])
        flag.fail = true
        store.load(chats: [("chat-1", "Design Sync")], channels: [])
        await settle()
        XCTAssertEqual(store.rows.map(\.file.name), ["chat-deck.pdf"])
        if case .error = store.state {} else { XCTFail("failed refresh should surface its error") }
    }
}
