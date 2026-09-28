// DemoSelectTests.swift — om-demo-select: launch selection policy.
//
// Regression: the installed (live) build restored a stale `demo-react`
// default from shared defaults and 404d against the live service.
// Restored ids validate against the loaded list (first-chat fallback,
// never a direct open); demo ids never load live and never persist.
import XCTest

@testable import OstMacCore

final class DemoSelectTests: XCTestCase {
    static func chat(_ id: String, name: String = "C") -> ChatItem {
        ChatItem(chatId: id, name: name)
    }

    static let liveID = "19:aaa@thread.v2"
    static let liveID2 = "8:bbb"
    static let live = [chat(liveID, name: "Live A"), chat(liveID2, name: "Live B")]

    // MARK: - Demo namespace

    func testIsDemoID() {
        for id in [
            DemoData.demoID, DemoData.avaID, DemoData.standupID,
            DemoData.richID, DemoData.mediaID, DemoData.reactionsID,
            DemoData.repliesID, DemoData.historyID, DemoData.botpostsID,
            "demo-chan-general", DemoData.longChannelID,
            DemoData.churnMeetingID, DemoData.churnSyncID,
            DemoData.churnPollyID, DemoData.churnStandupID,
        ] {
            XCTAssertTrue(DemoData.isDemoID(id), id)
        }
        for id in [Self.liveID, Self.liveID2, "19:meeting_real999@thread.v2", "Conversation", ""] {
            XCTAssertFalse(DemoData.isDemoID(id), id)
        }
    }

    /// Every canned row id is fenced, so namespace drift can't leak a
    /// demo thread into live (or into shared defaults).
    func testEveryCannedRowIDIsDemo() {
        let ids = DemoData.chats.map(\.id)
            + DemoData.churnChatsResponse().chats.map(\.id)
        XCTAssertFalse(ids.isEmpty)
        for id in ids {
            XCTAssertTrue(DemoData.isDemoID(id), id)
            XCTAssertFalse(SelectionRestore.shouldPersist(chatID: id), id)
        }
    }

    // MARK: - Live restore (the 404 regression)

    /// Stale demo-react default + live list: the first live chat wins,
    /// never a direct open of the demo id.
    func testLiveRestoreDemoReactFallsBackToFirst() {
        XCTAssertEqual(
            SelectionRestore.resolve(
                explicit: nil, restored: DemoData.reactionsID,
                chats: Self.live, isDemo: false),
            .select(Self.liveID))
    }

    func testLiveRestoreUnknownFallsBackToFirst() {
        XCTAssertEqual(
            SelectionRestore.resolve(
                explicit: nil, restored: "19:ghost@thread.v2",
                chats: Self.live, isDemo: false),
            .select(Self.liveID))
    }

    func testLiveRestoreMemberHonored() {
        XCTAssertEqual(
            SelectionRestore.resolve(
                explicit: nil, restored: Self.liveID2,
                chats: Self.live, isDemo: false),
            .select(Self.liveID2))
    }

    func testLiveRestoreEmptyListOpensNothing() {
        XCTAssertEqual(
            SelectionRestore.resolve(
                explicit: nil, restored: DemoData.reactionsID,
                chats: [], isDemo: false),
            .none)
    }

    func testLiveFirstLaunchOpensNothing() {
        XCTAssertEqual(
            SelectionRestore.resolve(
                explicit: nil, restored: nil,
                chats: Self.live, isDemo: false),
            .none)
    }

    /// A restored id never direct-opens, whatever it is.
    func testRestoredNeverDirectOpens() {
        for restored in [DemoData.reactionsID, "19:ghost@thread.v2", Self.liveID2] {
            for isDemo in [false, true] {
                let chats = isDemo ? DemoData.chats : Self.live
                let got = SelectionRestore.resolve(
                    explicit: nil, restored: restored, chats: chats, isDemo: isDemo)
                if case .openDirect = got {
                    XCTFail("restored direct-opened: \(restored) demo=\(isDemo)")
                }
            }
        }
    }

    // MARK: - Live explicit --chat

    func testLiveExplicitMemberSelects() {
        XCTAssertEqual(
            SelectionRestore.resolve(
                explicit: Self.liveID2, restored: Self.liveID,
                chats: Self.live, isDemo: false),
            .select(Self.liveID2))
    }

    func testLiveExplicitUnknownDirectOpens() {
        XCTAssertEqual(
            SelectionRestore.resolve(
                explicit: "19:new@thread.v2", restored: Self.liveID,
                chats: Self.live, isDemo: false),
            .openDirect("19:new@thread.v2"))
    }

    /// Even an explicit demo id never loads live.
    func testLiveExplicitDemoFallsBackToFirst() {
        XCTAssertEqual(
            SelectionRestore.resolve(
                explicit: DemoData.reactionsID, restored: nil,
                chats: Self.live, isDemo: false),
            .select(Self.liveID))
        XCTAssertEqual(
            SelectionRestore.resolve(
                explicit: DemoData.reactionsID, restored: nil,
                chats: [], isDemo: false),
            .none)
    }

    // MARK: - Demo restore

    func testDemoRestoreDemoMemberHonored() {
        XCTAssertEqual(
            SelectionRestore.resolve(
                explicit: nil, restored: DemoData.reactionsID,
                chats: DemoData.chats, isDemo: true),
            .select(DemoData.reactionsID))
    }

    /// A stale live id in demo falls back to the first demo row instead
    /// of direct-opening an empty thread.
    func testDemoRestoreLiveIDFallsBackToFirst() {
        XCTAssertEqual(
            SelectionRestore.resolve(
                explicit: nil, restored: Self.liveID,
                chats: DemoData.chats, isDemo: true),
            .select(DemoData.demoID))
    }

    func testDemoExplicitDemoChannelDirectOpens() {
        // Absent from the chat rows but valid in demo (channel thread).
        XCTAssertEqual(
            SelectionRestore.resolve(
                explicit: "demo-chan-general", restored: nil,
                chats: DemoData.chats, isDemo: true),
            .openDirect("demo-chan-general"))
    }

    // MARK: - Persist rule

    func testShouldPersist() {
        XCTAssertTrue(SelectionRestore.shouldPersist(chatID: Self.liveID))
        XCTAssertTrue(SelectionRestore.shouldPersist(chatID: Self.liveID2))
        XCTAssertFalse(SelectionRestore.shouldPersist(chatID: DemoData.reactionsID))
        XCTAssertFalse(SelectionRestore.shouldPersist(chatID: DemoData.demoID))
        XCTAssertFalse(SelectionRestore.shouldPersist(chatID: DemoData.churnMeetingID))
    }
}
