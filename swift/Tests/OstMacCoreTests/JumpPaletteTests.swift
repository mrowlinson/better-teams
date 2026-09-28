// JumpPaletteTests.swift — om-cmdk lane: fuzzy scoring, ranking, targets.
import XCTest

import OstMacCore

final class JumpPaletteTests: XCTestCase {
    // MARK: - FuzzyMatch.score

    func testEmptyQueryScoresZero() {
        XCTAssertEqual(FuzzyMatch.score(query: "", target: "Anything"), 0)
    }

    func testNonSubsequenceIsNil() {
        XCTAssertNil(FuzzyMatch.score(query: "xyz", target: "Design Sync"))
        XCTAssertNil(FuzzyMatch.score(query: "sync design", target: "Design Sync"))
    }

    func testCaseInsensitive() {
        XCTAssertNotNil(FuzzyMatch.score(query: "AVA", target: "Ava Lindqvist"))
        XCTAssertNotNil(FuzzyMatch.score(query: "ava", target: "Ava Lindqvist"))
    }

    func testPrefixBeatsScattered() {
        let prefix = FuzzyMatch.score(query: "des", target: "Design Sync")!
        let scattered = FuzzyMatch.score(query: "des", target: "Ademo E S")!
        XCTAssertGreaterThan(prefix, scattered)
    }

    func testWordBoundaryBeatsMidWord() {
        // Same case + adjacency; only the boundary differs.
        let boundary = FuzzyMatch.score(query: "sync", target: "Pre sync")!
        let mid = FuzzyMatch.score(query: "sync", target: "Presync")!
        XCTAssertGreaterThan(boundary, mid)
    }

    // MARK: - FuzzyMatch.ranked

    func testEmptyQueryKeepsOrder() {
        let targets = sampleTargets()
        XCTAssertEqual(FuzzyMatch.ranked(targets, query: "  ").map(\.id), targets.map(\.id))
    }

    func testFiltersNonMatches() {
        let ranked = FuzzyMatch.ranked(sampleTargets(), query: "ava l")
        XCTAssertEqual(ranked.map(\.id), ["demo-2"])
    }

    func testQualifiedHitFindsChannelByTeam() {
        let ranked = FuzzyMatch.ranked(sampleTargets(), query: "eng ship")
        XCTAssertTrue(ranked.contains { $0.id == "demo-chan-shipping" })
    }

    func testDirectHitOutranksQualified() {
        let targets = sampleTargets()
        let ranked = FuzzyMatch.ranked(targets, query: "eng")
        XCTAssertEqual(ranked.first?.id, "demo-team-eng")
    }

    // MARK: - JumpTargets.build

    func testBuildCounts() {
        let targets = JumpTargets.build(chats: DemoData.chats, teams: DemoData.teams)
        let chats = targets.filter { $0.kind == .chat }
        let direct = targets.filter { $0.kind == .oneToOne }
        let channels = targets.filter { $0.kind == .channel }
        let teams = targets.filter { $0.kind == .team }
        XCTAssertEqual(chats.count + direct.count, DemoData.chats.count)
        XCTAssertEqual(channels.count, 4) // 3 eng + 1 design (om-hu-fixture long channel)
        XCTAssertEqual(teams.count, 2)
    }

    /// 1:1 chats build .oneToOne rows (person icon); groups stay .chat.
    func testBuildMarksOneToOne() {
        let targets = JumpTargets.build(chats: DemoData.chats, teams: [])
        let ava = targets.first { $0.id == "demo-2" }!
        XCTAssertEqual(ava.kind, .oneToOne)
        XCTAssertEqual(ava.subtitle, "Chat")
        let group = targets.first { $0.id == "demo" }!
        XCTAssertEqual(group.kind, .chat)
        XCTAssertEqual(group.subtitle, "Group chat")
    }

    func testTeamOpensFirstChannel() {
        let targets = JumpTargets.build(chats: [], teams: DemoData.teams)
        let eng = targets.first { $0.id == "demo-team-eng" }!
        XCTAssertEqual(eng.openID, "demo-chan-general")
        XCTAssertEqual(eng.openName, "Engineering > #General")
    }

    func testChannelLessTeamNotOpenable() {
        let lonely = TeamItem(teamId: "t-0", name: "Lonely", channels: [])
        let targets = JumpTargets.build(chats: [], teams: [lonely])
        XCTAssertEqual(targets.count, 1)
        XCTAssertNil(targets[0].openID)
    }

    // MARK: - jump() routing

    /// jump() routes known chat ids through the sidebar selection and
    /// everything else through open-by-id; pin the membership predicate.
    func testJumpRoutingPredicate() {
        XCTAssertTrue(DemoData.chats.contains { $0.id == DemoData.avaID })
        XCTAssertFalse(DemoData.chats.contains { $0.id == "demo-chan-general" })
    }

    // MARK: - PaletteNav (om-lt4-palettenav: flat ↑↓ across chats + files + people)

    func testVisibleCountCapsAtFive() {
        XCTAssertEqual(PaletteNav.visibleCount(9), 5)
        XCTAssertEqual(PaletteNav.visibleCount(3), 3)
        XCTAssertEqual(PaletteNav.visibleCount(0), 0)
    }

    func testTotalSumsVisibleRows() {
        XCTAssertEqual(PaletteNav.total(mainCount: 3, fileCount: 2, personCount: 1), 6)
        XCTAssertEqual(PaletteNav.total(mainCount: 0, fileCount: 0, personCount: 0), 0)
    }

    func testResolveMapsSections() {
        XCTAssertEqual(PaletteNav.resolve(0, mainCount: 2, fileCount: 2, personCount: 1), .main(0))
        XCTAssertEqual(PaletteNav.resolve(1, mainCount: 2, fileCount: 2, personCount: 1), .main(1))
        XCTAssertEqual(PaletteNav.resolve(2, mainCount: 2, fileCount: 2, personCount: 1), .file(0))
        XCTAssertEqual(PaletteNav.resolve(3, mainCount: 2, fileCount: 2, personCount: 1), .file(1))
        XCTAssertEqual(PaletteNav.resolve(4, mainCount: 2, fileCount: 2, personCount: 1), .person(0))
        XCTAssertNil(PaletteNav.resolve(5, mainCount: 2, fileCount: 2, personCount: 1))
        XCTAssertNil(PaletteNav.resolve(-1, mainCount: 2, fileCount: 2, personCount: 1))
    }

    func testResolveSkipsEmptyMain() {
        XCTAssertEqual(PaletteNav.resolve(0, mainCount: 0, fileCount: 1, personCount: 1), .file(0))
        XCTAssertEqual(PaletteNav.resolve(1, mainCount: 0, fileCount: 1, personCount: 1), .person(0))
    }

    func testMoveClamps() {
        XCTAssertEqual(PaletteNav.move(current: 0, delta: -1, total: 5), 0)
        XCTAssertEqual(PaletteNav.move(current: 4, delta: 1, total: 5), 4)
        XCTAssertEqual(PaletteNav.move(current: 1, delta: 1, total: 5), 2)
        XCTAssertEqual(PaletteNav.move(current: 2, delta: -2, total: 5), 0)
        XCTAssertEqual(PaletteNav.move(current: 0, delta: 1, total: 0), 0)
    }

    // MARK: - PaletteNav skipping disabled rows (om-a3-keyboard)

    func testMoveSkippingJumpsDisabled() {
        let enabled = [true, false, false, true, true]
        XCTAssertEqual(
            PaletteNav.moveSkipping(current: 0, delta: 1, total: 5) { enabled[$0] }, 3)
        XCTAssertEqual(
            PaletteNav.moveSkipping(current: 3, delta: -1, total: 5) { enabled[$0] }, 0)
        XCTAssertEqual(
            PaletteNav.moveSkipping(current: 3, delta: 1, total: 5) { enabled[$0] }, 4)
    }

    func testMoveSkippingStaysAtEdge() {
        let enabled = [true, false, false]
        XCTAssertEqual(
            PaletteNav.moveSkipping(current: 0, delta: 1, total: 3) { enabled[$0] }, 0)
        XCTAssertEqual(
            PaletteNav.moveSkipping(current: 0, delta: -1, total: 3) { enabled[$0] }, 0)
    }

    func testMoveSkippingSettlesDisabledCurrent() {
        let enabled = [false, false, true]
        XCTAssertEqual(
            PaletteNav.moveSkipping(current: 0, delta: 0, total: 3) { enabled[$0] }, 2)
        XCTAssertEqual(
            PaletteNav.moveSkipping(current: 1, delta: -1, total: 3) { enabled[$0] }, 2)
    }

    func testFirstEnabled() {
        XCTAssertEqual(PaletteNav.firstEnabled(total: 3) { $0 == 2 }, 2)
        XCTAssertNil(PaletteNav.firstEnabled(total: 3) { _ in false })
        XCTAssertNil(PaletteNav.firstEnabled(total: 0) { _ in true })
    }

    // MARK: - Sticky scope (gap-g6g7)

    func testScopeRawValuesMatchRecentsStore() {
        // The persisted chip strings round-trip through the view scope.
        XCTAssertEqual(JumpPaletteScope(rawValue: "chats"), .chats)
        XCTAssertEqual(JumpPaletteScope(rawValue: "messages"), .messages)
        XCTAssertNil(JumpPaletteScope(rawValue: "bogus"))
        XCTAssertEqual(JumpPaletteScope.messages.rawValue, "messages")
    }

    private func sampleTargets() -> [JumpTarget] {
        JumpTargets.build(chats: DemoData.chats, teams: DemoData.teams)
    }
}
