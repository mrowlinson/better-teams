// TagsGuardTests — TAGS guard: the Manage Tags entry (native label,
// menu-bar twin), the sheet's live gate (scope-blocked: unavailable
// with a reason, never fake controls; demo fully interactive), and
// the @-mention picker tag rows. No windows, no network.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class TagsGuardTests: XCTestCase {
    private func window(args: [String] = ["--demo"]) -> WindowModel {
        let app = AppState(args: args)
        let model = WindowModel(graph: app, accountKey: "demo",
                                options: LaunchOptions(args: args))
        let nav = Navigator(model: model)
        model.navigator = nav
        addTeardownBlock { _ = nav }
        return model
    }

    func testManageTagsCommandIsNativeMenuTitle() {
        let entry = TeamsCommands.all.first { $0.id == TeamsCommands.manageTags }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.title, "Manage Tags…")
    }

    func testManageTagsValidationNeedsATeam() {
        let section = TeamsSection()
        let m = window()
        XCTAssertFalse(section.validate(TeamsCommands.manageTags, arg: nil, m).enabled)
        XCTAssertFalse(section.perform(TeamsCommands.manageTags, arg: nil, m))
    }

    func testDemoStoreLoadsSeededTags() {
        let m = window()
        let section = TeamsSection()
        let store = section.tagStore("guard-team", m)
        XCTAssertTrue(store.canEdit)
        if case .loaded = store.state {} else { return XCTFail("demo tags store must load") }
        XCTAssertEqual(store.tags.count, 3)
    }

    func testLiveStoreIsUnavailableWithReason() {
        let store = TeamTagsStore(teamID: "guard-live", demo: false)
        XCTAssertFalse(store.canEdit)
        if case .unavailable(let reason) = store.state {
            XCTAssertFalse(reason.isEmpty)
        } else {
            return XCTFail("live tags store must be unavailable")
        }
    }

    func testLiveWritesRefuseWithoutFaking() {
        let store = TeamTagsStore(teamID: "guard-live", demo: false)
        XCTAssertFalse(store.create(name: "X", description: nil, memberIDs: []))
        XCTAssertFalse(store.remove(id: "x"))
        XCTAssertEqual(store.error, TeamTags.unavailableReason)
        XCTAssertTrue(store.tags.isEmpty)
    }

    func testTagNamesFlowToMentionCandidates() {
        let tags = TeamTagsStore.demoTags(teamID: "guard-picker")
        let names = TeamTags.mentionCandidates(tags, query: "")
        XCTAssertEqual(names.count, 3)
        XCTAssertTrue(names.contains("Designers"))
        XCTAssertEqual(TeamTags.insert("QA", into: "heads up"), "heads up @QA ")
    }
}
