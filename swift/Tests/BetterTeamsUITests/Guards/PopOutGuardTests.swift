// PopOutGuardTests — R1 (REGFIX-B): double-click a chat row pops the chat
// out into its own window (81b718a); channels too; a meeting and a file
// can pop out in a native window each. The presenter is replaced so no
// window is ever ordered in; the controllers and their windows are real.
import AppKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class PopOutGuardTests: XCTestCase {
    private var presented: [NSWindowController] = []
    private var savedPresenter: ((NSWindowController) -> Void)!
    private var closers: [() -> Void] = []

    override func setUp() {
        super.setUp()
        savedPresenter = PopOutPresenter.present
        PopOutPresenter.present = { [unowned self] c in presented.append(c) }
    }

    override func tearDown() {
        closers.forEach { $0() }
        PopOutPresenter.present = savedPresenter
        super.tearDown()
    }

    func testDoubleClickOnChatRowPopsTheChatOut() throws {
        let (_, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        XCTAssertNil(ChatWindowController.window(for: DemoData.demoID))
        ChatListPane.doubleClick([DemoData.demoID], model)
        let w = try XCTUnwrap(ChatWindowController.window(for: DemoData.demoID), "double-click must open the chat's own window")
        closers.append { w.close() }
        XCTAssertEqual(presented.count, 1)
        XCTAssertFalse(w.isVisible, "the test never orders a window in")
        // Second double-click focuses the same window, never a second one.
        ChatListPane.doubleClick([DemoData.demoID], model)
        XCTAssertTrue(ChatWindowController.window(for: DemoData.demoID) === w)
        XCTAssertEqual(presented.count, 2)
        XCTAssertTrue(presented[0] === presented[1])
        // Nothing selected: nothing opens.
        ChatListPane.doubleClick([], model)
        XCTAssertEqual(presented.count, 2)
    }

    func testDoubleClickOnChannelRowPopsTheChannelOutButNotATeam() throws {
        XCTAssertEqual(TeamsListPane.doubleClickChannelID("chan:abc"), "abc")
        XCTAssertNil(TeamsListPane.doubleClickChannelID("team:abc"))
        let (app, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        // The Teams list's own data, loaded the way the section does.
        let loaded = expectation(description: "teams")
        Task { await app.teams.load(); loaded.fulfill() }
        wait(for: [loaded], timeout: 20)
        let team = try XCTUnwrap(app.teams.teams.first)
        let channel = try XCTUnwrap(team.channels.first)
        // The list's own double-click handler (TeamsListPane's primaryAction),
        // fed the row tags the list would.
        var selected: [String] = []
        TeamsListPane.primaryAction(["team:\(team.teamId)"], model) { selected.append($0) }
        XCTAssertEqual(selected, ["team:\(team.teamId)"], "a team row just selects")
        XCTAssertEqual(presented.count, 0, "a team row never pops out")
        XCTAssertNil(ChannelWindowController.window(for: channel.channelId))
        TeamsListPane.primaryAction(["chan:\(channel.channelId)"], model) { selected.append($0) }
        let w = try XCTUnwrap(ChannelWindowController.window(for: channel.channelId),
                              "double-clicking a channel row must open its window")
        closers.append { w.close(); _ = app }
        XCTAssertEqual(selected.last, "chan:\(channel.channelId)", "the row is selected too")
        XCTAssertEqual(presented.count, 1)
        XCTAssertFalse(w.isVisible)
        TeamsListPane.primaryAction([], model) { selected.append($0) }
        XCTAssertEqual(presented.count, 1, "nothing selected: nothing opens")
    }

    func testMeetingPopsOutInItsOwnWindow() throws {
        let (_, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        let meeting = try XCTUnwrap(DemoData.meetings.first)
        MeetingWindowController.show(model, meeting: meeting)
        let w = try XCTUnwrap(MeetingWindowController.window(for: meeting.id), "meeting did not pop out")
        closers.append { w.close() }
        XCTAssertEqual(w.title, meeting.subject)
        XCTAssertFalse(w.isVisible)
        MeetingWindowController.show(model, meeting: meeting)
        XCTAssertTrue(MeetingWindowController.window(for: meeting.id) === w, "re-open focuses the same window")
        XCTAssertEqual(presented.count, 2)
        // The command exists for the menu bar and the row menu.
        XCTAssertNotNil(CommandCatalog.command(CalendarCommands.openWindow))
    }

    func testFilePopsOutInItsOwnWindow() throws {
        let (_, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        let file = try XCTUnwrap(DemoData.sharedFiles(for: DemoData.demoID).first { !$0.isFolder })
        FileWindowController.show(model, chatID: DemoData.demoID, file: file)
        let w = try XCTUnwrap(FileWindowController.window(forFile: DemoData.demoID, fileID: file.id), "file did not pop out")
        closers.append { w.close() }
        XCTAssertEqual(w.title, file.name)
        XCTAssertFalse(w.isVisible)
        FileWindowController.show(model, chatID: DemoData.demoID, file: file)
        XCTAssertTrue(FileWindowController.window(forFile: DemoData.demoID, fileID: file.id) === w)
        XCTAssertNotNil(CommandCatalog.command(FilesCommands.openWindow))
    }
}
