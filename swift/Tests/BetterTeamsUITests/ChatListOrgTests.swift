// ChatListOrgTests.swift — chatlist-org lane: R0 auto-rule end-to-end
// pin, R2 combined chats+channels switch (both positions). Nothing is
// shown on screen; no real user defaults are written.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class ChatListOrgTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "chatlistorg.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func chat(id: String, name: String, sender: String? = nil, group: Bool = false) -> ChatItem {
        ChatItem(chatId: id, name: name, is_group: group, last_message_sender: sender)
    }

    // MARK: R0 — editor drafts → save → auto-assign

    func testRuleDraftsThroughSaveFileChatsAndRefusalsNeverDo() {
        let store = FolderStore(defaults: suite())
        let work = try! XCTUnwrap(store.createFolder(name: "Work"))
        let people = try! XCTUnwrap(store.createFolder(name: "People"))
        // Editor-style drafts: an untrimmed pattern, a disabled rule,
        // and a matcherless rule.
        let drafts = [
            FolderRule(folderID: work.id, namePattern: "  budget "),
            FolderRule(folderID: people.id, senderDomain: "contoso.com", enabled: false),
            FolderRule(folderID: work.id),
        ]
        ManageFoldersSheet.commitRules(drafts, to: store)

        // The trimmed pattern files through the whole chain
        // (commitRules → FolderResolve.matches → FolderStore.folderID).
        let filed = chat(id: "c1", name: "Budget review", sender: "sam@example.test")
        XCTAssertTrue(FolderResolve.matches(chat: filed, rule: store.rules[0]))
        XCTAssertEqual(store.folderID(for: filed), work.id)

        // A disabled rule never files, even on a sender hit.
        let contoso = chat(id: "c2", name: "Random", sender: "ann@contoso.com")
        XCTAssertFalse(FolderResolve.matches(chat: contoso, rule: store.rules[1]))
        // A matcherless rule never files either.
        XCTAssertFalse(store.rules[2].hasMatchers)
        XCTAssertFalse(FolderResolve.matches(chat: contoso, rule: store.rules[2]))
        XCTAssertNil(store.folderID(for: contoso))
    }

    // MARK: R2 — combined chats+channels, default off

    func testCombinedChatsChannelsDefaultsOffAndPersists() {
        let fresh = AppSettings(defaults: MemoryDefaults())
        XCTAssertFalse(fresh.combinedChatsChannels, "combined view ships off")
        fresh.combinedChatsChannels = true
        XCTAssertEqual(fresh.defaults.object(forKey: AppSettings.Key.combinedChatsChannels) as? Bool, true)
        XCTAssertTrue(AppSettings(defaults: fresh.defaults).combinedChatsChannels, "an explicit on stays on")
    }

    private func sampleTeams() -> [TeamItem] {
        [
            TeamItem(teamId: "t-eng", name: "Eng", channels: [
                TeamChannel(channelId: "c-general", name: "General"),
                TeamChannel(channelId: "c-random", name: "Random"),
            ]),
            TeamItem(teamId: "t-ops", name: "Ops", channels: [
                TeamChannel(channelId: "c-alerts", name: "Alerts"),
            ]),
        ]
    }

    func testCombinedOffShowsNoChannelRows() {
        XCTAssertTrue(
            CombinedChatList.channelRows(teams: sampleTeams(), combined: false).isEmpty,
            "switch off = chat-only, even with teams loaded")
    }

    func testCombinedOnListsChannelsTeamThenChannel() {
        let rows = CombinedChatList.channelRows(teams: sampleTeams(), combined: true)
        XCTAssertEqual(rows.map(\.channelID), ["c-general", "c-random", "c-alerts"])
        XCTAssertEqual(rows[0].teamName, "Eng")
    }

    func testCombinedOnSkipsHiddenTeamsAndChannels() {
        let rows = CombinedChatList.channelRows(
            teams: sampleTeams(), hiddenTeams: ["t-ops"], hiddenChannels: ["c-random"], combined: true)
        XCTAssertEqual(rows.map(\.channelID), ["c-general"])
    }
}
