// CoreBTests.swift — core-b lane: public team search, pinned channels,
// file source conversation.
import XCTest

@testable import OstMacCore

@MainActor
final class CoreBTests: XCTestCase {
    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "test-coreb-\(UUID().uuidString)") ?? .standard
    }

    // MARK: - Public team search

    func testPublicSearchMarksMembersAndJoinsByHit() async {
        let joined = JoinedIDs()
        let vm = TeamsViewModel(
            fetcher: {
                TeamsResponse(ok: true, teams: joined.ids.map { TeamItem(teamId: $0, name: $0, channels: []) })
            },
            joiner: { id in
                joined.add(id)
                return TeamJoinResponse(ok: true, team_id: id)
            },
            publicSearcher: { q in
                PublicTeamsResponse(ok: true, query: q, source: "groups", teams: [
                    PublicTeam(id: "t-sup", name: "Support"),
                    PublicTeam(id: "t-soc", name: "Social"),
                ])
            })
        joined.add("t-soc")
        await vm.load()
        await vm.searchPublic(query: "  s ")
        XCTAssertEqual(vm.publicQuery, "s")
        XCTAssertEqual(vm.publicResults.map(\.id), ["t-sup", "t-soc"])
        XCTAssertFalse(vm.isMember(vm.publicResults[0]))
        XCTAssertTrue(vm.isMember(vm.publicResults[1]))
        await vm.join(publicTeam: vm.publicResults[0])
        XCTAssertEqual(vm.joinsCompleted, 1)
        XCTAssertTrue(vm.isMember(PublicTeam(id: "t-sup", name: "Support")))
        await vm.searchPublic(query: "  ")
        XCTAssertTrue(vm.publicResults.isEmpty)
    }

    func testPublicSearchErrorAndDemoSearch() async {
        let vm = TeamsViewModel(publicSearcher: { _ in throw CoreCallError.failed("403 Forbidden") })
        await vm.searchPublic(query: "x")
        XCTAssertEqual(vm.publicSearchError, "403 Forbidden")
        XCTAssertTrue(vm.publicResults.isEmpty)
        let demo = DemoTeams.search("re", ledger: DemoTeams.Ledger())
        XCTAssertTrue(demo.teams.map(\.id).contains("demo-team-research"))
        XCTAssertTrue(DemoTeams.search(" ", ledger: DemoTeams.Ledger()).teams.isEmpty)
    }

    func testPublicTeamsDecode() throws {
        let json = #"{"ok":true,"query":"sup","source":"teams","teams":[{"id":"t1","name":"Support","description":null,"visibility":"public"}]}"#
        let r = try JSONDecoder().decode(PublicTeamsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.teams, [PublicTeam(id: "t1", name: "Support")])
        XCTAssertEqual(r.source, "teams")
    }

    // MARK: - Pinned channels

    func testPinnedChannelsPersistInOrderPerAccount() {
        let d = freshSuite()
        let a = PinnedChannelStore(accountKey: "acct-a", defaults: d)
        a.pin("c1"); a.pin("c2"); a.pin("c3"); a.pin("c2"); a.pin("  ")
        XCTAssertEqual(a.orderedIDs, ["c1", "c2", "c3"])
        a.move(from: 2, to: 0)
        XCTAssertEqual(a.orderedIDs, ["c3", "c1", "c2"])
        a.move("c3", to: 99)
        XCTAssertEqual(a.orderedIDs, ["c1", "c2", "c3"])
        a.reorder(["c2", "nope", "c1"])
        XCTAssertEqual(a.orderedIDs, ["c2", "c1", "c3"])
        a.unpin("c1")
        XCTAssertEqual(PinnedChannelStore(accountKey: "acct-a", defaults: d).orderedIDs, ["c2", "c3"])
        XCTAssertEqual(d.stringArray(forKey: "bt.teams.pinned.acct-a"), ["c2", "c3"])
        XCTAssertTrue(PinnedChannelStore(accountKey: "acct-b", defaults: d).orderedIDs.isEmpty)
        struct Ch { let id: String }
        XCTAssertEqual(a.ordered([Ch(id: "c3"), Ch(id: "x"), Ch(id: "c2")], id: \.id).map(\.id), ["c2", "c3"])
    }

    func testPinnedChannelsMemoryOnlyNeverWrites() {
        let mem = PinnedChannelStore(accountKey: "acct-a", defaults: nil)
        XCTAssertNil(mem.storageKey)
        mem.seedDemo(["d1", "d1", "d2"])
        mem.pin("d3")
        XCTAssertEqual(mem.orderedIDs, ["d1", "d2", "d3"])
    }

    // MARK: - File source conversation

    func testUnifiedRowsStampSourceAndSearchResolves() {
        let chatFile = SharedFile(id: "f1", name: "deck.pdf", drive_id: "D1")
        let driveFile = SharedFile(id: "f2", name: "notes.txt", drive_id: "D2")
        let rows = [
            UnifiedFileRow(file: chatFile, source: .chat, sourceName: "Design Sync", sourceID: "19:chat"),
            UnifiedFileRow(file: driveFile, source: .drive, sourceName: "OneDrive"),
        ]
        XCTAssertEqual(rows[0].file.source_name, "Design Sync")
        XCTAssertEqual(rows[0].sourceID, "19:chat")
        XCTAssertNil(rows[1].file.source_name)
        // Search hit for the same drive item names the chat; drive-only
        // and unknown items pass through.
        let hit = UnifiedFilesStore.resolveSource(SharedFile(id: "f1", name: "deck.pdf", drive_id: "D1"), rows: rows)
        XCTAssertEqual(hit.source_name, "Design Sync")
        XCTAssertEqual(hit.source_id, "19:chat")
        XCTAssertNil(UnifiedFilesStore.resolveSource(driveFile, rows: rows).source_name)
        XCTAssertNil(UnifiedFilesStore.resolveSource(SharedFile(id: "f1", name: "x"), rows: rows).source_name)
        // Demo search rows carry name + id.
        let demo = DemoData.fileSearchResponse(for: "")
        XCTAssertTrue(demo.files.allSatisfy { $0.source_name != nil && $0.source_id != nil })
    }

    func testFileSearchStoreAppliesResolver() async {
        let store = FilePeopleSearchStore(
            fileSearcher: { q, _ in FileSearchResponse(ok: true, query: q, files: [SharedFile(id: "f1", name: "a")]) },
            peopleSearcher: { q, _ in PeopleSearchResponse(ok: true, query: q, people: []) })
        store.sourceResolver = { $0.withSource(name: "Chat", id: "c1") }
        await store.search(query: "a")
        XCTAssertEqual(store.files.first?.source_name, "Chat")
        XCTAssertEqual(store.files.first?.source_id, "c1")
    }
}

/// Thread-safe joined-id list for the join/fetch mocks (detached tasks).
private final class JoinedIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ id: String) { lock.lock(); list.append(id); lock.unlock() }
    var ids: [String] { lock.lock(); defer { lock.unlock() }; return list }
}
