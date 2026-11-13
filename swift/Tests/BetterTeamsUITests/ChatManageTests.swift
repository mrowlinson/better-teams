// ChatManageTests — GAPL2 follow-ups: a cleared group name falls back to
// the other members' first names (Teams), Add People hides current
// members, and after a partial add failure only the people not added
// stay picked. The fake service stands in for the chat service (the
// ost fake-server test pins the per-user outcomes it returns).
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class ChatManageTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [[String]] = []
        func record(_ v: [String]) { lock.lock(); list.append(v); lock.unlock() }
        var all: [[String]] { lock.lock(); defer { lock.unlock() }; return list }
    }

    func testBlankRenameTakesTheOtherMembersFirstNames() async throws {
        let (app, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime((model, nav)) {} }
        let chats = app.chats
        await chats.load()
        let group = try XCTUnwrap(chats.chats.first { $0.is_group })
        let r1 = await chats.renameChat(chatID: group.id, topic: "Launch Crew")
        XCTAssertTrue(r1)
        XCTAssertEqual(chats.chat(id: group.id)?.name, "Launch Crew")

        // Demo, roster not loaded: the demo roster names it, you left out.
        let r2 = await chats.renameChat(chatID: group.id, topic: "   ")
        XCTAssertTrue(r2)
        XCTAssertEqual(chats.chat(id: group.id)?.name, "Megan, Ava and Tom")

        // Live service with the open chat's roster: the name is cleared
        // on the server ("") and the row takes the members' names.
        let calls = Calls()
        chats.manage = ChatManageService(
            isDemo: false,
            rename: { id, topic in calls.record([id, topic]) },
            addMembers: { _, users, _ in users.map { ChatMemberAddResult(user: $0, ok: true) } },
            removeMember: { _, _ in })
        let r3 = await chats.renameChat(chatID: group.id, topic: "Launch Crew")
        XCTAssertTrue(r3)
        let roster = ChatRosterStore(demo: true)
        await roster.load(chatID: group.id)
        roster.applyRemoved(mri: "8:orgid:demo-u-tom")
        let r4 = await chats.renameChat(chatID: group.id, topic: "", roster: roster, ownUserID: "demo-u-me")
        XCTAssertTrue(r4)
        XCTAssertEqual(calls.all.last, [group.id, ""])
        XCTAssertEqual(chats.chat(id: group.id)?.name, "Megan and Ava")
    }

    func testAddPeopleHidesCurrentMembers() {
        let members = DemoChatRoster.members(for: DemoData.standupID)
        let directory = DemoData.peopleSearchResponse(for: "").people
        XCTAssertEqual(ChatManageRule.addable(directory, members: members).map(\.displayName),
                       ["Daniel Brooks", "Olivia Carter"])
        // MRI-only and email-only matches hide too; strangers stay.
        let byMRI = ChatMember(mri: "8:orgid:AAAA-1", userId: nil, displayName: "", email: nil)
        let byMail = ChatMember(mri: "8:orgid:bbbb-2", userId: nil, displayName: "", email: "Pat@Example.com")
        let people = [
            TeamMember(id: "aaaa-1", displayName: "Chris Hall", userId: "aaaa-1"),
            TeamMember(id: "x", displayName: "Pat Young", email: "pat@example.com"),
            TeamMember(id: "cccc-3", displayName: "Sam Reed", userId: "cccc-3"),
        ]
        XCTAssertEqual(ChatManageRule.addable(people, members: [byMRI, byMail]).map(\.displayName), ["Sam Reed"])
    }

    func testPartialAddFailureKeepsOnlyThePeopleNotAdded() async throws {
        let (app, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime((model, nav)) {} }
        let chats = app.chats
        await chats.load()
        let group = try XCTUnwrap(chats.chats.first { $0.is_group })
        let okID = "dddddddd-0000-0000-0000-000000000001"
        let noID = "dddddddd-0000-0000-0000-000000000002"
        let calls = Calls()
        chats.manage = ChatManageService(
            isDemo: false,
            rename: { _, _ in },
            addMembers: { _, users, _ in
                calls.record(users)
                return users.map { ChatMemberAddResult(user: $0, ok: $0 != noID, error: $0 == noID ? "403" : nil) }
            },
            removeMember: { _, _ in })
        let chosen = [
            TeamMember(id: okID, displayName: "Chris Hall", userId: okID),
            TeamMember(id: noID, displayName: "Sam Reed", userId: noID),
        ]
        let failed = await chats.addPeople(chatID: group.id, people: chosen, history: .all, roster: nil)
        XCTAssertEqual(failed, [noID])
        XCTAssertEqual(chats.manageError, "Couldn't add 1 person to the chat.")
        let retry = ChatManageRule.notAdded(chosen, failed: failed)
        XCTAssertEqual(retry.map(\.displayName), ["Sam Reed"])

        let again = await chats.addPeople(chatID: group.id, people: retry, history: .all, roster: nil)
        XCTAssertEqual(again, [noID])
        XCTAssertEqual(calls.all, [[okID, noID], [noID]], "the retry sends only the person not added")
    }
}
