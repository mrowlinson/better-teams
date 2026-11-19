// TeamTagsTests.swift — TAGS lane: tag model helpers, demo seeds,
// store CRUD (demo acts, live refuses with the scope reason), and
// @-mention candidate shaping. Fakes only: nothing reaches Graph
// (TeamworkTag.* is scope-blocked; live 403 proven 11-19).
import XCTest

@testable import OstMacCore

@MainActor
final class TeamTagsTests: XCTestCase {
    func testValidName() {
        XCTAssertEqual(TeamTags.validName("Designers"), "Designers")
        XCTAssertEqual(TeamTags.validName("  On-Call "), "On-Call")
        XCTAssertNil(TeamTags.validName(""))
        XCTAssertNil(TeamTags.validName("   "))
        XCTAssertNil(TeamTags.validName(String(repeating: "x", count: 101)))
        XCTAssertNotNil(TeamTags.validName(String(repeating: "x", count: 100)))
    }

    func testFiltered() {
        let tags = DemoTeamTags.seed(teamID: "t")
        XCTAssertEqual(TeamTags.filtered(tags, query: "").count, 3)
        XCTAssertEqual(TeamTags.filtered(tags, query: "qa").map(\.displayName), ["QA"])
        XCTAssertEqual(TeamTags.filtered(tags, query: "DES").map(\.displayName), ["Designers"])
        XCTAssertTrue(TeamTags.filtered(tags, query: "zzz").isEmpty)
    }

    func testMentionCandidatesAndInsert() {
        let tags = DemoTeamTags.seed(teamID: "t")
        XCTAssertEqual(TeamTags.mentionCandidates(tags, query: ""), ["Designers", "On-Call", "QA"])
        XCTAssertEqual(TeamTags.mentionCandidates(tags, query: "on"), ["On-Call"])
        XCTAssertEqual(TeamTags.insert("Designers", into: ""), "@Designers ")
        XCTAssertEqual(TeamTags.insert("QA", into: "hi"), "hi @QA ")
    }

    func testDemoSeed() {
        let tags = DemoTeamTags.seed(teamID: "t1")
        XCTAssertEqual(tags.count, 3)
        XCTAssertTrue(tags.allSatisfy { $0.id.hasPrefix("t1-") && !Set($0.memberIDs).isEmpty })
    }

    func testDemoStoreActs() {
        let store = TeamTagsStore(teamID: "t-demo-\(UUID().uuidString)", demo: true)
        XCTAssertTrue(store.canEdit)
        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.tags.count, 3)
        XCTAssertTrue(store.create(name: "Docs", description: nil, memberIDs: ["demo-u-me"]))
        XCTAssertEqual(store.tags.count, 4)
        let id = store.tags.last!.id
        XCTAssertTrue(store.rename(id: id, name: "Docs Team"))
        XCTAssertEqual(store.tags.last!.displayName, "Docs Team")
        XCTAssertTrue(store.setMembers(id: id, memberIDs: ["a", "b"]))
        XCTAssertEqual(store.tags.last!.memberIDs, ["a", "b"])
        XCTAssertTrue(store.remove(id: id))
        XCTAssertEqual(store.tags.count, 3)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.create(name: "  ", description: nil, memberIDs: []))
        XCTAssertNotNil(store.error)
    }

    func testLiveStoreRefusesWithScopeReason() {
        let store = TeamTagsStore(teamID: "t-live", demo: false)
        XCTAssertFalse(store.canEdit)
        XCTAssertEqual(store.state, .unavailable(TeamTags.unavailableReason))
        XCTAssertTrue(store.tags.isEmpty)
        XCTAssertFalse(store.create(name: "X", description: nil, memberIDs: []))
        XCTAssertFalse(store.rename(id: "x", name: "Y"))
        XCTAssertFalse(store.remove(id: "x"))
        XCTAssertFalse(store.setMembers(id: "x", memberIDs: []))
        XCTAssertEqual(store.error, TeamTags.unavailableReason)
    }

    func testLiveReasonMentionsPermission() {
        XCTAssertTrue(TeamTags.unavailableReason.contains("TeamworkTag"))
        XCTAssertTrue(TeamTags.capabilityMessage.contains("TeamworkTag"))
    }

    func testDemoRegistryShared() {
        let team = "t-shared-\(UUID().uuidString)"
        let store = TeamTagsStore(teamID: team, demo: true)
        XCTAssertTrue(store.create(name: "Shared", description: nil, memberIDs: []))
        // A fresh store for the same team sees the first store's write.
        let again = TeamTagsStore(teamID: team, demo: true)
        XCTAssertTrue(again.tags.contains { $0.displayName == "Shared" })
        // And the picker source agrees.
        XCTAssertTrue(TeamTagsStore.demoTags(teamID: team).contains { $0.displayName == "Shared" })
    }
}
