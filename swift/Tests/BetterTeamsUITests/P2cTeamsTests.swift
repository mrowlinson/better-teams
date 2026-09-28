// P2cTeamsTests.swift — P2c pure-logic tests (UI-SPEC §6.3, §11.1):
// Teams selection grammar, channel tab layout, post/thread grouping by
// `reply_to`, and the Teams toolbar item.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class P2cTeamsTests: XCTestCase {
    func testSelectionRoundTrip() {
        let cases = [
            TeamsSelection(teamID: "t"),
            TeamsSelection(teamID: "t", channelID: "19:a@thread.tacv2"),
            TeamsSelection(teamID: "t", channelID: "c", tab: .files),
            TeamsSelection(teamID: "t", channelID: "c", tab: .web("tab-1"), threadID: "m1"),
            TeamsSelection(teamID: "t", channelID: "c", threadID: "m1"),
        ]
        for s in cases { XCTAssertEqual(TeamsSelection(s.selection), s) }
        // Team-only selections drop tab and thread.
        XCTAssertEqual(TeamsSelection(SectionSelection(["t", "tab:files", "thread:m"])), TeamsSelection(teamID: "t"))
        XCTAssertNil(TeamsSelection(nil))
        XCTAssertEqual(TeamsSelection(teamID: "t", channelID: "c").rowTag, "chan:c")
        XCTAssertEqual(TeamsSelection(teamID: "t").rowTag, "team:t")
    }

    func testRouteSelectionResolvesDemoAliases() {
        let p = TeamsSection()
        let r = Route(string: "teams/demo-team/demo-channel?tab=posts&thread=demo-thread")
        let s = r.flatMap { TeamsSelection(p.selection(for: $0)) }
        XCTAssertEqual(s, TeamsSelection(teamID: "demo-team-eng", channelID: DemoTeams.threadedChannelID,
                                         threadID: DemoTeams.threadRootID))
    }

    func testChannelTabLayout() {
        let tabs = DemoTeams.tabs(for: DemoTeams.threadedChannelID) + [ChannelTab(id: "x", name: "Legacy")]
        let l = ChannelTabLayout(tabs)
        XCTAssertEqual(l.visibleWeb.map(\.name), ["Roadmap", "Release Board"])
        XCTAssertEqual(l.overflow.map(\.name), ["Wiki", "Status Page", "Sprint Board", "Legacy"])
        let plain = ChannelTabLayout(DemoTeams.tabs(for: "demo-chan-general"))
        XCTAssertTrue(plain.visibleWeb.isEmpty)
        XCTAssertTrue(plain.overflow.isEmpty)
    }

    private func msg(_ id: String, _ parent: String? = nil, _ t: String = "2026-09-22T09:00:00Z") -> ChatMessage {
        ChatMessage(id: id, sender: "A", timestamp: t, content: id, reply_to: parent)
    }

    func testThreadsGroupByReplyTo() {
        let list = [msg("r1"), msg("a", "r1"), msg("r2"), msg("b", "a"), msg("orphan", "gone"), msg("self", "self")]
        let t = ChannelThreads(list)
        XCTAssertEqual(t.roots.map(\.id), ["r1", "r2", "orphan", "self"])
        XCTAssertEqual(t.replies["r1"]?.map(\.id), ["a", "b"])
        XCTAssertNil(t.replies["r2"])
    }

    func testPostsScopeItems() {
        let list = [msg("r1"), msg("a", "r1"), msg("b", "r1", "2026-09-22T09:05:00Z"), msg("r2")]
        let items = TimelineSnapshot.items(messages: list, failed: [], scope: .posts,
                                           dayKey: { _ in "d" }, dayLabel: { $0 })
        XCTAssertEqual(items.map(\.id), ["day:d", "msg:r1", "thread:r1", "msg:r2", "thread:r2"])
        guard case .threadSummary(_, let n, let last) = items[2] else { return XCTFail("no summary") }
        XCTAssertEqual(n, 2)
        XCTAssertEqual(last, "2026-09-22T09:05:00Z")
        // Every post shows its author, even same-sender runs.
        for case .message(_, _, let header) in items { XCTAssertTrue(header) }
        // A new reply changes only the summary row's revision.
        let more = TimelineSnapshot.items(messages: list + [msg("c", "r1")], failed: [], scope: .posts,
                                          dayKey: { _ in "d" }, dayLabel: { $0 })
        XCTAssertEqual(more.map(\.id), items.map(\.id))
        XCTAssertNotEqual(more[2].revision, items[2].revision)
        XCTAssertEqual(more[1].revision, items[1].revision)
    }

    func testThreadScopeAndTargets() {
        let list = [msg("r1"), msg("a", "r1"), msg("r2"), msg("b", "a")]
        let items = TimelineSnapshot.items(messages: list, failed: [], scope: .thread(rootID: "r1"),
                                           dayKey: { _ in "d" }, dayLabel: { $0 })
        XCTAssertEqual(items.compactMap(\.messageID), ["r1", "a", "b"])
        XCTAssertTrue(TimelineSnapshot.items(messages: list, failed: [], scope: .thread(rootID: "zz")).isEmpty)
        let byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        XCTAssertEqual(TimelineSnapshot.visibleTarget("b", scope: .posts, in: byID), "r1")
        XCTAssertEqual(TimelineSnapshot.visibleTarget("b", scope: .conversation, in: byID), "b")
        XCTAssertFalse(TimelineSnapshot.showsQuote(msg("a", "r1"), scope: .thread(rootID: "r1")))
        XCTAssertTrue(TimelineSnapshot.showsQuote(msg("b", "a"), scope: .thread(rootID: "r1")))
    }

    func testJoinOrCreateIsListToolbarSubmenu() {
        let c = CommandCatalog.command(TeamsCommands.joinOrCreate)
        XCTAssertEqual(c?.toolbar, .list)
        XCTAssertEqual(c?.isSubmenu, true)
        XCTAssertNotNil(c?.menu)
        let order = ShellToolbarController.layout(CommandCatalog.toolbarCommands).order
        let sep = order.firstIndex(of: .listDetailSeparator) ?? 0
        let item = order.firstIndex(of: ShellToolbarController.ident(TeamsCommands.joinOrCreate)) ?? .max
        XCTAssertLessThan(item, sep)
    }

    func testChannelLink() {
        let teams = [TeamItem(teamId: "g-1", name: "Eng", channels: [
            TeamChannel(channelId: "19:abc@thread.tacv2", name: "Ship It"),
            TeamChannel(channelId: "c2", name: "Web", webUrl: "https://teams.example/c2"),
        ])]
        XCTAssertEqual(TeamsSection.link(channelID: "19:abc@thread.tacv2", teams: teams),
                       "https://teams.microsoft.com/l/channel/19%3Aabc%40thread.tacv2/Ship%20It?groupId=g-1")
        XCTAssertEqual(TeamsSection.link(channelID: "c2", teams: teams), "https://teams.example/c2")
        XCTAssertNil(TeamsSection.link(channelID: "nope", teams: teams))
    }
}
