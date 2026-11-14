// ListRowActionsTests.swift — P2#10: Chat/Activity/Calls/Teams list rows
// expose their row-menu items as VoiceOver actions (message rows
// already expose 7; these seams pin the list-row names).
import XCTest

@testable import BetterTeamsUI

@MainActor
final class ListRowActionsTests: XCTestCase {
    func testChatRowActionNames() {
        XCTAssertEqual(ChatRowActions.rowActionNames(unread: true, pinned: false, muted: false),
                       ["Mark as Read", "Pin", "Mute"])
        XCTAssertEqual(ChatRowActions.rowActionNames(unread: false, pinned: true, muted: true),
                       ["Mark as Unread", "Unpin", "Unmute"])
    }

    func testActivityRowActionNames() {
        XCTAssertEqual(ActivitySection.rowActionNames(reviewed: false), ["Open", "Mark as Read"])
        XCTAssertEqual(ActivitySection.rowActionNames(reviewed: true), ["Open", "Mark as Unread"])
    }

    func testCallsRowActionNames() {
        XCTAssertEqual(CallsListPane.rowActionNames(canCall: true, canMessage: true,
                                                    speedDialTitle: "Add to Speed Dial", isRecent: true),
                       ["Call Back", "Message", "Add to Speed Dial", "Remove from Recents"])
        // Only the enabled items appear (mirrors the row menu gating).
        XCTAssertEqual(CallsListPane.rowActionNames(canCall: false, canMessage: false,
                                                    speedDialTitle: nil, isRecent: false), [])
        XCTAssertEqual(CallsListPane.rowActionNames(canCall: false, canMessage: true,
                                                    speedDialTitle: "Remove from Speed Dial",
                                                    isRecent: false),
                       ["Message", "Remove from Speed Dial"])
    }

    func testTeamsRowActionNames() {
        XCTAssertEqual(TeamsListPane.channelRowActionNames(hidden: false),
                       ["Open in New Window", "Mark Channel as Read", "Hide"])
        XCTAssertEqual(TeamsListPane.channelRowActionNames(hidden: true),
                       ["Open in New Window", "Mark Channel as Read", "Show"])
        XCTAssertEqual(TeamsListPane.teamRowActionNames(hidden: false),
                       ["Mark Team as Read", "Hide", "Manage Team…"])
        XCTAssertEqual(TeamsListPane.teamRowActionNames(hidden: true),
                       ["Mark Team as Read", "Show", "Manage Team…"])
    }
}
