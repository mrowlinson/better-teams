// ChatFoldersTests.swift — d1-folders: folders, manual assign, auto-rules.
import XCTest

@testable import OstMacCore

@MainActor
final class ChatFoldersTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(
            suiteName: "test-folders-\(UUID().uuidString)") ?? .standard
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "test-folders-teardown")
        defaults = nil
        super.tearDown()
    }

    private func makeStore() -> FolderStore {
        FolderStore(defaults: defaults)
    }

    private func chat(
        id: String, name: String, group: Bool = false,
        sender: String? = nil
    ) -> ChatItem {
        ChatItem(
            chatId: id, name: name, is_group: group,
            last_message_sender: sender)
    }

    // MARK: - CRUD + persistence

    func testCreatePersistsAcrossRelaunch() {
        let store = makeStore()
        let folder = store.createFolder(name: "Work")
        XCTAssertNotNil(folder)
        let reopened = makeStore()
        XCTAssertEqual(reopened.folders.map(\.name), ["Work"])
        XCTAssertEqual(reopened.folders.first?.id, folder?.id)
    }

    func testEmptyNameRefused() {
        let store = makeStore()
        XCTAssertNil(store.createFolder(name: ""))
        XCTAssertNil(store.createFolder(name: "   "))
        XCTAssertTrue(store.folders.isEmpty)
    }

    func testDuplicateNameRefused() {
        let store = makeStore()
        XCTAssertNotNil(store.createFolder(name: "Work"))
        XCTAssertNil(store.createFolder(name: "Work"))
        XCTAssertNil(store.createFolder(name: "work"))
        XCTAssertNil(store.createFolder(name: "  Work  "))
        XCTAssertEqual(store.folders.count, 1)
    }

    func testRenameRoundTripAndRejects() {
        let store = makeStore()
        let a = store.createFolder(name: "Work")!
        store.createFolder(name: "Family")
        XCTAssertTrue(store.renameFolder(id: a.id, name: "Clients"))
        XCTAssertFalse(store.renameFolder(id: a.id, name: ""))
        XCTAssertFalse(store.renameFolder(id: a.id, name: "Family"))
        XCTAssertFalse(store.renameFolder(id: a.id, name: "family"))
        XCTAssertFalse(store.renameFolder(id: "nope", name: "Ghost"))
        XCTAssertEqual(makeStore().folders.first(where: { $0.id == a.id })?.name, "Clients")
    }

    func testDeleteRemovesFolderRulesAndAssignments() {
        let store = makeStore()
        let work = store.createFolder(name: "Work")!
        store.assign(chatID: "8:alice", folderID: work.id)
        let rule = store.addRule(FolderRule(folderID: work.id, namePattern: "standup"))!
        XCTAssertNotNil(rule.id)
        store.deleteFolder(id: work.id)
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertTrue(store.rules.isEmpty)
        let reopened = makeStore()
        XCTAssertTrue(reopened.folders.isEmpty)
        XCTAssertTrue(reopened.rules.isEmpty)
        XCTAssertNil(reopened.folderID(for: chat(id: "8:alice", name: "Alice")))
    }

    // MARK: - Manual assign

    func testManualAssignBeatsAutoRule() {
        let store = makeStore()
        let work = store.createFolder(name: "Work")!
        let family = store.createFolder(name: "Family")!
        store.addRule(FolderRule(folderID: work.id, namePattern: "Alice"))
        let alice = chat(id: "8:alice", name: "Alice Carter")
        XCTAssertEqual(store.folderID(for: alice), work.id)
        store.assign(chatID: alice.id, folderID: family.id)
        XCTAssertEqual(store.folderID(for: alice), family.id)
        store.assign(chatID: alice.id, folderID: nil)
        XCTAssertEqual(store.folderID(for: alice), work.id)
    }

    func testAssignUnknownFolderIsNoOp() {
        let store = makeStore()
        store.createFolder(name: "Work")
        store.assign(chatID: "8:bob", folderID: "missing")
        XCTAssertNil(store.folderID(for: chat(id: "8:bob", name: "Bob")))
        store.assign(chatID: "  ", folderID: nil)
    }

    // MARK: - Auto-rule resolver

    func testFirstMatchingRuleWins() {
        let first = FolderRule(folderID: "f1", namePattern: "standup")
        let second = FolderRule(folderID: "f2", namePattern: "standup")
        let c = chat(id: "19:t@thread", name: "Team Standup", group: true)
        XCTAssertEqual(
            FolderResolve.folderFor(chat: c, rules: [first, second], overrides: [:]),
            "f1")
        XCTAssertEqual(
            FolderResolve.folderFor(chat: c, rules: [second, first], overrides: [:]),
            "f2")
    }

    func testDisabledRuleNeverMatches() {
        let rule = FolderRule(folderID: "f1", namePattern: "standup", enabled: false)
        let c = chat(id: "19:t@thread", name: "Team Standup", group: true)
        XCTAssertNil(FolderResolve.folderFor(chat: c, rules: [rule], overrides: [:]))
    }

    func testInvalidRegexNeverMatches() {
        let rule = FolderRule(folderID: "f1", namePattern: "re:([unclosed")
        let c = chat(id: "19:t@thread", name: "Team Standup", group: true)
        XCTAssertNil(FolderResolve.folderFor(chat: c, rules: [rule], overrides: [:]))
    }

    func testValidRegexMatches() {
        let rule = FolderRule(folderID: "f1", namePattern: "re:sev-?\\d+")
        XCTAssertEqual(
            FolderResolve.folderFor(
                chat: chat(id: "19:t@thread", name: "sev123 bridge", group: true),
                rules: [rule], overrides: [:]),
            "f1")
    }

    func testWholeWordMatching() {
        let rule = FolderRule(folderID: "f1", namePattern: "standup")
        XCTAssertNil(FolderResolve.folderFor(
            chat: chat(id: "19:t@thread", name: "standups archive", group: true),
            rules: [rule], overrides: [:]))
        XCTAssertEqual(FolderResolve.folderFor(
            chat: chat(id: "19:t@thread", name: "Team Standup", group: true),
            rules: [rule], overrides: [:]), "f1")
    }

    func testSenderDomainMatchesSender() {
        let rule = FolderRule(folderID: "f1", senderDomain: "contoso.com")
        XCTAssertEqual(FolderResolve.folderFor(
            chat: chat(id: "8:erin", name: "Erin", sender: "erin@contoso.com"),
            rules: [rule], overrides: [:]), "f1")
        XCTAssertNil(FolderResolve.folderFor(
            chat: chat(id: "8:frank", name: "Frank", sender: "frank@fabrikam.com"),
            rules: [rule], overrides: [:]))
        XCTAssertNil(FolderResolve.folderFor(
            chat: chat(id: "8:gail", name: "Gail"),
            rules: [rule], overrides: [:]))
    }

    func testKindMatchesGroupOrDirect() {
        let groups = FolderRule(folderID: "fg", kind: .group)
        let directs = FolderRule(folderID: "fd", kind: .direct)
        let g = chat(id: "19:t@thread", name: "Team", group: true)
        let d = chat(id: "8:henry", name: "Henry")
        XCTAssertEqual(
            FolderResolve.folderFor(chat: g, rules: [groups, directs], overrides: [:]), "fg")
        XCTAssertEqual(
            FolderResolve.folderFor(chat: d, rules: [groups, directs], overrides: [:]), "fd")
    }

    func testRuleMatchersOrTogether() {
        let rule = FolderRule(
            folderID: "f1", namePattern: "standup",
            senderDomain: "contoso.com", kind: .group)
        XCTAssertEqual(FolderResolve.folderFor(
            chat: chat(id: "19:a@thread", name: "Team Standup", group: true),
            rules: [rule], overrides: [:]), "f1")
        XCTAssertEqual(FolderResolve.folderFor(
            chat: chat(id: "8:erin", name: "Erin", sender: "erin@contoso.com"),
            rules: [rule], overrides: [:]), "f1")
        XCTAssertNil(FolderResolve.folderFor(
            chat: chat(id: "8:frank", name: "Frank", sender: "frank@fabrikam.com"),
            rules: [rule], overrides: [:]))
    }

    func testMatcherlessRuleNeverMatches() {
        let rule = FolderRule(folderID: "f1")
        XCTAssertNil(FolderResolve.folderFor(
            chat: chat(id: "8:henry", name: "Henry"),
            rules: [rule], overrides: [:]))
    }

    // MARK: - Sanitize on load

    func testSanitizeOnLoadDropsBlankAndDupes() {
        let folders = [
            ChatFolder(id: "a", name: "Work"),
            ChatFolder(id: "b", name: "  "),
            ChatFolder(id: "c", name: "work"),
            ChatFolder(id: "a", name: "Work Again"),
        ]
        let data = try! JSONEncoder().encode(folders)
        defaults.set(data, forKey: FolderStore.foldersKey)
        let store = makeStore()
        XCTAssertEqual(store.folders.map(\.name), ["Work"])
    }

    func testSanitizeDropsRulesForUnknownFolders() {
        let store = makeStore()
        let work = store.createFolder(name: "Work")!
        store.addRule(FolderRule(folderID: work.id, namePattern: "standup"))
        var rules = store.rules
        rules.append(FolderRule(folderID: "ghost", namePattern: "x"))
        defaults.set(try! JSONEncoder().encode(rules), forKey: FolderStore.rulesKey)
        defaults.set(
            ["8:alice": work.id, "8:bob": "ghost", "": work.id],
            forKey: FolderStore.assignmentsKey)
        let reopened = makeStore()
        XCTAssertEqual(reopened.rules.count, 1)
        XCTAssertEqual(
            reopened.folderID(for: chat(id: "8:alice", name: "Alice")), work.id)
        XCTAssertNil(reopened.folderID(for: chat(id: "8:bob", name: "Bob")))
    }

    func testCorruptPayloadFallsBackToEmpty() {
        defaults.set(Data("not-json".utf8), forKey: FolderStore.foldersKey)
        defaults.set("not-a-dict", forKey: FolderStore.assignmentsKey)
        let store = makeStore()
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertTrue(store.rules.isEmpty)
    }

    // MARK: - Projection

    func testFolderFilterPreservesOrder() {
        let rule = FolderRule(folderID: "f1", kind: .group)
        let chats = [
            chat(id: "19:a@thread", name: "Alpha", group: true),
            chat(id: "8:bob", name: "Bob"),
            chat(id: "19:c@thread", name: "Charlie", group: true),
        ]
        let got = FolderResolve.filter(chats, folderID: "f1", rules: [rule], overrides: [:])
        XCTAssertEqual(got.map(\.id), ["19:a@thread", "19:c@thread"])
        let all = FolderResolve.filter(chats, folderID: nil, rules: [rule], overrides: [:])
        XCTAssertEqual(all.map(\.id), chats.map(\.id))
    }

    func testSelectionSurvivesSwitchWhenVisible() {
        let visible = [
            chat(id: "8:alice", name: "Alice"),
            chat(id: "8:bob", name: "Bob"),
        ]
        XCTAssertEqual(
            FolderResolve.selectedAfterSwitch(selectedID: "8:bob", visible: visible),
            "8:bob")
        XCTAssertNil(FolderResolve.selectedAfterSwitch(selectedID: nil, visible: visible))
        XCTAssertNil(FolderResolve.selectedAfterSwitch(
            selectedID: "19:gone@thread", visible: visible))
    }

    func testIngestKeepsFolderMembership() {
        // Membership derives from chat content at render time: an ingest
        // bubble changes order, never the folder a chat resolves to.
        let rule = FolderRule(folderID: "f1", namePattern: "standup")
        let before = [
            chat(id: "8:bob", name: "Bob"),
            chat(id: "19:t@thread", name: "Team Standup", group: true),
        ]
        let msg = RealtimeMessage(
            chatID: "19:t@thread", msgId: "m1", sender: "Ivy",
            text: "standup notes", time: "2026-09-25T03:00:00Z",
            isEdit: false)
        let after = ChatListViewModel.ingested(msg, into: before)
        XCTAssertEqual(after.first?.id, "19:t@thread")
        for row in after {
            let want: String? = row.id == "19:t@thread" ? "f1" : nil
            XCTAssertEqual(
                FolderResolve.folderFor(chat: row, rules: [rule], overrides: [:]), want)
        }
    }
}
