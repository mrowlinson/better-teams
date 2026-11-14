// TabShortcutTests.swift — P2#18: ⌥⌘1–3 follow the shown conversation
// in Chat, Activity, and Search (Teams keeps its channel tabs).
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class TabShortcutTests: XCTestCase {
    func testTabConversationFollowsActivity() {
        let app = AppState(args: ["--demo"])
        let m = WindowModel(graph: app, accountKey: "tab-test", options: LaunchOptions(args: ["--demo"]))
        let nav = Navigator(model: m)
        m.navigator = nav
        addTeardownBlock {
            _ = nav
            UserDefaults.standard.removeObject(forKey: "bt.nav.tab-test")
        }
        guard let item = app.activity.items.first(where: { $0.kind != .missedCall && !$0.chatID.isEmpty })
        else {
            return XCTFail("control: demo feed has a chatted item")
        }
        nav.select(SectionSelection(id: item.id), in: .activity)
        nav.select(section: .activity)
        XCTAssertEqual(ShellWindowController.tabConversation(m), item.chatID)

        // The resolved ref drives detail tabs (the ⌥⌘1–3 perform path).
        nav.setDetailTab(.files, for: item.chatID)
        XCTAssertEqual(m.nav.tab(for: item.chatID), .files)
        nav.setDetailTab(.notes, for: item.chatID)
        XCTAssertEqual(m.nav.tab(for: item.chatID), .notes)
    }

    func testTabConversationNilWithoutConversation() {
        let app = AppState(args: ["--demo"])
        let m = WindowModel(graph: app, accountKey: "tab-test", options: LaunchOptions(args: ["--demo"]))
        let nav = Navigator(model: m)
        m.navigator = nav
        addTeardownBlock {
            _ = nav
            UserDefaults.standard.removeObject(forKey: "bt.nav.tab-test")
        }
        // Teams section: channel tabs own ⌥⌘1–3, never a conversation.
        nav.select(section: .teams)
        XCTAssertNil(ShellWindowController.tabConversation(m))
    }
}
