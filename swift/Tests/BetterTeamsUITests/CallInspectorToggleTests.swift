// CallInspectorToggleTests.swift — P2#13: the Call menu's Show/Hide
// People/Chat lands on the call section's inspector segment and flips
// its title with visibility.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class CallInspectorToggleTests: XCTestCase {
    func testShowHidePeopleChat() {
        let chats = ChatListViewModel(fetcher: { _ in ChatsResponse(ok: true, chats: []) })
        let graph = AccountWindowGraph(account: AccountRecord(id: "call-toggle-test", displayName: "Test"),
                                       chats: chats)
        let model = WindowModel(graph: graph, accountKey: "call-toggle-test",
                                options: LaunchOptions(args: ["--evidence"]))
        let nav = Navigator(model: model)
        model.navigator = nav
        addTeardownBlock {
            _ = nav
            UserDefaults.standard.removeObject(forKey: "bt.nav.call-toggle-test")
        }
        let section = CallSection()

        // No running call: disabled.
        XCTAssertFalse(section.validate(CallCommands.showPeople, arg: nil, model).enabled)
        XCTAssertFalse(section.validate(CallCommands.showChat, arg: nil, model).enabled)
        XCTAssertFalse(section.perform(CallCommands.showPeople, arg: nil, model))

        guard let call = model.beginCall(.test, presentation: .separateWindow, show: false) else {
            return XCTFail("control: test call begins")
        }
        defer { call.leave() }

        XCTAssertEqual(section.validate(CallCommands.showPeople, arg: nil, model).title, "Show People")
        XCTAssertTrue(section.perform(CallCommands.showPeople, arg: nil, model))
        XCTAssertEqual(model.nav.section, .call)
        XCTAssertTrue(model.nav.isInspectorVisible(.call))
        XCTAssertEqual(model.inspectorSegment, "people")
        XCTAssertEqual(section.validate(CallCommands.showPeople, arg: nil, model).title, "Hide People")
        XCTAssertEqual(section.validate(CallCommands.showChat, arg: nil, model).title, "Show Chat")

        // Same segment again hides the inspector.
        XCTAssertTrue(section.perform(CallCommands.showPeople, arg: nil, model))
        XCTAssertFalse(model.nav.isInspectorVisible(.call))

        // Chat segment.
        XCTAssertTrue(section.perform(CallCommands.showChat, arg: nil, model))
        XCTAssertTrue(model.nav.isInspectorVisible(.call))
        XCTAssertEqual(model.inspectorSegment, "chat")
        XCTAssertEqual(section.validate(CallCommands.showChat, arg: nil, model).title, "Hide Chat")

        // Call menu lists both items.
        let items = CommandCatalog.all.filter { $0.menu?.menu == .call }
        XCTAssertTrue(items.contains { $0.id == CallCommands.showPeople })
        XCTAssertTrue(items.contains { $0.id == CallCommands.showChat })
    }
}
