// JumpSeekTests.swift — gap-g9: seek verdicts (land/miss), session
// counters, and armed-miss clearing. Sync paths only (in-memory demo
// threads); paging verdicts need core and are covered by code review.
import XCTest

@testable import OstMacCore

@MainActor
final class JumpSeekTests: XCTestCase {
    private func demoStore() -> ConversationStore {
        let store = ConversationStore()
        store.showDemo(
            chatID: DemoData.repliesID, chatName: "Replies",
            messages: DemoData.messages(for: DemoData.repliesID))
        return store
    }

    func testSeekMissingWithoutCursorArmsMiss() {
        let store = demoStore()
        store.seek(messageID: "no-such-bubble")
        XCTAssertNil(store.jumpTargetID)
        XCTAssertEqual(store.jumpMissedID, "no-such-bubble")
        XCTAssertEqual(store.lastMissedID, "no-such-bubble")
        XCTAssertEqual(store.seekAttempts, 1)
        XCTAssertEqual(store.seekMissed, 1)
        XCTAssertEqual(store.seekLanded, 0)
    }

    func testSeekBlankCountsNothing() {
        let store = demoStore()
        store.seek(messageID: "no-such-bubble")
        XCTAssertNotNil(store.jumpMissedID)
        store.seek(messageID: "   ")
        XCTAssertNil(store.jumpTargetID)
        // Blank still supersedes the banner, but counts nothing.
        XCTAssertNil(store.jumpMissedID)
        XCTAssertEqual(store.seekAttempts, 1)
        XCTAssertEqual(store.seekLanded, 0)
        XCTAssertEqual(store.seekMissed, 1)
    }

    func testSeekFoundLandsAndClearsMiss() {
        let store = demoStore()
        store.seek(messageID: "no-such-bubble")
        XCTAssertNotNil(store.jumpMissedID)
        store.seek(messageID: "rep-2")
        XCTAssertEqual(store.jumpTargetID, "rep-2")
        XCTAssertNil(store.jumpMissedID)
        XCTAssertEqual(store.seekAttempts, 2)
        XCTAssertEqual(store.seekLanded, 1)
        XCTAssertEqual(store.seekMissed, 1)
        // The session record survives the later land.
        XCTAssertEqual(store.lastMissedID, "no-such-bubble")
    }

    func testClearJumpMissedKeepsCounters() {
        let store = demoStore()
        store.seek(messageID: "no-such-bubble")
        store.clearJumpMissed()
        XCTAssertNil(store.jumpMissedID)
        XCTAssertEqual(store.seekAttempts, 1)
        XCTAssertEqual(store.seekMissed, 1)
        XCTAssertEqual(store.lastMissedID, "no-such-bubble")
    }

    func testCloseAndShowDemoClearArmedMiss() {
        let store = demoStore()
        store.seek(messageID: "no-such-bubble")
        store.close()
        XCTAssertNil(store.jumpMissedID)
        store.showDemo(
            chatID: DemoData.repliesID, chatName: "Replies",
            messages: DemoData.messages(for: DemoData.repliesID))
        XCTAssertNil(store.jumpMissedID)
        XCTAssertNil(store.jumpTargetID)
    }

    func testResetForAccountClearsMissRecord() {
        let store = demoStore()
        store.seek(messageID: "no-such-bubble")
        store.resetForAccount(displayName: "Me")
        XCTAssertNil(store.jumpMissedID)
        XCTAssertNil(store.lastMissedID)
    }
}
