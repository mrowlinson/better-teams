// ChatManageGuardTests — GAPL2: group chat management (Teams behavior:
// rename the chat, add people with a history choice, remove people).
// Pins that Rename Chat…, Add People… and Remove from Chat… are offered
// for group chats only (never 1:1 or yourself), that Add People carries
// the three history choices, that the demo applies each change in memory,
// and that the core FFI is linked. Drives the statics and stores the
// views call; nothing is shown on screen.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class ChatManageGuardTests: XCTestCase {
    func testManageIsOfferedForGroupChatsOnly() {
        let group = ChatItem(chatId: "19:g@thread.v2", name: "Group", is_group: true)
        let direct = ChatItem(chatId: "19:a_b@unq.gbl.spaces", name: "Pat", is_group: false)
        XCTAssertTrue(ChatManageRule.canManage(group))
        XCTAssertFalse(ChatManageRule.canManage(direct), "1:1 chats have a fixed roster and no name")
        XCTAssertFalse(ChatManageRule.canManage(nil))
        XCTAssertTrue(ChatManageRule.canRemove(group, isYou: false))
        XCTAssertFalse(ChatManageRule.canRemove(group, isYou: true), "removing yourself is Leave Chat")
        XCTAssertFalse(ChatManageRule.canRemove(direct, isYou: false))
        XCTAssertNotEqual(ChatManageActions.renameSheet, ChatManageActions.addPeopleSheet)
    }

    func testAddPeopleOffersThreeHistoryChoices() {
        let modes: [AddPeopleHistoryMode] = [.none, .days, .all]
        XCTAssertEqual(Set(modes).count, 3)
        XCTAssertEqual(ChatHistoryShare.none.mode, "none")
        XCTAssertEqual(ChatHistoryShare.days(3).mode, "days")
        XCTAssertEqual(ChatHistoryShare.days(3).days, 3)
        XCTAssertEqual(ChatHistoryShare.all.mode, "all")
        XCTAssertEqual(ChatHistoryShare.all.days, 0)
    }

    func testDemoRenameAddRemoveApplyInMemory() async throws {
        let (app, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime((model, nav)) {} }
        let chats = app.chats
        await chats.load()
        let group = try XCTUnwrap(chats.chats.first { $0.is_group }, "demo has a group chat")
        let direct = try XCTUnwrap(chats.chats.first { !$0.is_group && !ChatListFilter.isSelfChat($0.id) })

        let renamed = await chats.renameChat(chatID: group.id, topic: "  Launch Crew  ")
        XCTAssertTrue(renamed)
        XCTAssertEqual(chats.chat(id: group.id)?.name, "Launch Crew")
        let directRenamed = await chats.renameChat(chatID: direct.id, topic: "Nope")
        XCTAssertFalse(directRenamed, "1:1 chats are never renamed")

        let roster = app.chatRoster
        await roster.load(chatID: group.id)
        let before = roster.members.count
        let person = TeamMember(id: "p-1", displayName: "Grace Walker", userId: "11111111-2222-3333-4444-555555555555")
        let failed = await chats.addPeople(chatID: group.id, people: [person], history: .days(2), roster: roster)
        XCTAssertEqual(failed, [])
        XCTAssertNil(chats.manageError)
        XCTAssertEqual(roster.members.count, before + 1)
        let added = try XCTUnwrap(roster.members.first { $0.displayName == "Grace Walker" })

        let removed = await chats.removeMember(chatID: group.id, member: added, roster: roster)
        XCTAssertTrue(removed)
        XCTAssertEqual(roster.members.count, before)
    }

    func testCoreFunctionsAreLinked() {
        // Blank ids fail in core before any network: proves the three
        // FFI symbols are exported and wired.
        XCTAssertThrowsError(try RustCore.renameChat(chatID: "", topic: "x"))
        XCTAssertThrowsError(try RustCore.addChatMembers(chatID: "", users: ["a@b.c"], history: .none))
        XCTAssertThrowsError(try RustCore.removeChatMember(chatID: "", user: "a@b.c"))
    }
}
