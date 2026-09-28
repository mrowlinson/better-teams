// ChatFix2Tests.swift — CHATFIX2 pins: empty/error panes share the
// loading spinner's center, a new chat without messages leads the list,
// and the Manage Folders / Snooze Custom sheet routes present a sheet.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class ChatFix2Tests: XCTestCase {
    /// §6 pane states: `PaneAnchorLayout` centers its content on the
    /// pane's center (where `LoadingPane` puts its spinner), clamped
    /// inside the pane.
    func testPaneAnchorCentersOnLoadingCenter() {
        let bounds = CGRect(x: 0, y: 52, width: 600, height: 700)
        for h in [CGFloat(24), 120, 180, 260] {
            let top = PaneAnchorLayout.top(for: h, in: bounds)
            XCTAssertEqual(top + h / 2, bounds.midY, accuracy: 0.001, "height \(h)")
        }
        XCTAssertEqual(PaneAnchorLayout.top(for: 900, in: bounds), bounds.minY)
    }

    /// §6.2: a chat created just now (no messages, no time) leads the
    /// list instead of sinking below every dated row.
    func testNewChatWithoutMessagesSortsFirst() async {
        let model = ChatListViewModel(fetcher: { _ in DemoData.chatsResponse() })
        await model.load()
        model.insertLocally(ChatItem(chatId: "new-piper", name: "Piper Shaw"))
        XCTAssertEqual(model.chats.first?.id, "new-piper")
    }

    /// Routes `chat?sheet=manageFolders` and `…?sheet=snoozeCustom` were
    /// no-ops: both sheet names now resolve to a sheet body.
    func testManageFoldersAndSnoozeCustomSheetsPresent() {
        let chats = ChatListViewModel(fetcher: { _ in ChatsResponse(ok: true, chats: []) })
        let graph = AccountWindowGraph(account: AccountRecord(id: "cf2-test", displayName: "Test"), chats: chats)
        let model = WindowModel(graph: graph, accountKey: "cf2-test", options: LaunchOptions(args: ["--evidence"]))
        let nav = Navigator(model: model)
        model.navigator = nav
        addTeardownBlock { _ = nav }
        let chat = model.provider(.chat)
        XCTAssertNotNil(chat.sheet(SheetRequest(ChatCommands.manageFoldersSheet, in: .chat), model))
        XCTAssertNotNil(chat.sheet(SheetRequest(ChatCommands.snoozeCustomSheet, in: .chat, arg: "demo"), model))
    }
}
