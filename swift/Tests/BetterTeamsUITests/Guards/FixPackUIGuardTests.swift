// FixPackUIGuardTests — filter stack (TRIAGE D5): chat type filters,
// channel/meeting filters as in-list native pull-downs; channel sheets
// (TRIAGE D6): Manage Channel sheet + Workflows store (demo acts, live
// unavailable). Logic-level (what each control is bound to); nothing is
// shown on screen.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class FixPackUIGuardTests: XCTestCase {
    // MARK: Chats: type filters

    private func chatFixture() throws -> (ChatFilterRules, [ChatItem]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fpui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var config = RulesConfig.default
        config.hiddenChatIDs = ["19:meeting_hidden@thread.v2"]
        let path = dir.appendingPathComponent("rules.json").path
        try config.save(to: path)
        let suite = "fpui-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let rules = ChatFilterRules(unread: UnreadStore(), mentions: MentionStore(), rules: RulesStore(path: path),
                                    snooze: SnoozeStore(defaults: defaults), folders: FolderStore(defaults: defaults))
        let rows = [
            ChatItem(chatId: "19:aaa_bbb@unq.gbl.spaces", name: "Ada"),
            ChatItem(chatId: "19:grp1@thread.v2", name: "Launch crew", is_group: true),
            ChatItem(chatId: "19:meeting_one@thread.v2", name: "Weekly sync", is_group: true),
            ChatItem(chatId: "19:meeting_hidden@thread.v2", name: "Old sync", is_group: true),
        ]
        return (rules, rows)
    }

    func testChatTypeFiltersPartitionByKindAndSkipHidden() throws {
        let (rules, rows) = try chatFixture()
        XCTAssertEqual(rules.apply(.chats, to: rows).map(\.name), ["Ada", "Launch crew"])
        XCTAssertEqual(rules.apply(.meetings, to: rows).map(\.name), ["Weekly sync"], "hidden meeting chat stays out")
        // Control: All keeps every non-hidden row, so the partition is not vacuous.
        XCTAssertEqual(rules.apply(.all, to: rows).count, 3)
        XCTAssertEqual(ChatFilter(arg: ChatFilter.chats.arg), .chats)
        XCTAssertEqual(ChatFilter(arg: ChatFilter.meetings.arg), .meetings)
        XCTAssertEqual(ChatFilter.meetings.emptyTitle(folderName: nil), "No Meeting Chats")
    }

    func testChatFilterPullDownOffersTypeFilters() {
        let (_, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        let items = model.provider(.chat).submenuItems(ChatCommands.filter, model)
        let titles = items.map(\.title)
        XCTAssertTrue(titles.contains("Chats") && titles.contains("Meetings"), "\(titles)")
        XCTAssertEqual(items.first { $0.title == "Chats" }?.separatorBefore, true)
    }

    // MARK: Channels

    func testChannelFilterRules() {
        func m(_ f: ChannelFilter, hidden: Bool = false, unread: Bool = false, mentioned: Bool = false,
               pinned: Bool = false, level: ChatNotifyLevel = .all) -> Bool {
            f.matches(hidden: hidden, unread: unread, mentioned: mentioned, pinned: pinned, level: level)
        }
        XCTAssertTrue(m(.all))
        XCTAssertTrue(m(.unread, unread: true))
        XCTAssertFalse(m(.unread))
        XCTAssertTrue(m(.mentions, mentioned: true))
        XCTAssertFalse(m(.mentions, unread: true))
        XCTAssertTrue(m(.pinned, pinned: true))
        XCTAssertTrue(m(.muted, level: .muted))
        XCTAssertFalse(m(.muted, level: .mentions))
        XCTAssertFalse(m(.unread, hidden: true, unread: true), "hidden channels only show in All")
        XCTAssertFalse(m(.all, hidden: true))
    }

    func testChannelFilterStateTogglesAndListsEveryFilter() {
        let state = TeamsSectionState(accountKey: "fpui", persist: false)
        XCTAssertEqual(ChannelFilter.allCases.map(\.title), ["All Channels", "Unread", "Mentions", "Pinned", "Muted"])
        state.toggleFilter(.unread)
        XCTAssertEqual(state.filter, .unread)
        state.toggleFilter(.muted)
        XCTAssertEqual(state.filter, .muted, "another filter switches")
        state.toggleFilter(.muted)
        XCTAssertEqual(state.filter, .all, "same filter again turns it off")
        state.toggleFilter(.pinned)
        state.toggleFilter(.all)
        XCTAssertEqual(state.filter, .all)
    }

    // MARK: Meetings

    func testMeetingFilterRulesAndState() {
        let chatOnly = Recap(id: "c1", title: "Sync", recording: nil, transcript: nil, date: nil, threadID: "19:meeting_x")
        let files = Recap(id: "r1", title: "Review", recording: RecordingItem(id: "r1", name: "Review.mp4"),
                          transcript: nil, date: nil)
        XCTAssertTrue(RecapFilter.meetingChats.matches(chatOnly))
        XCTAssertFalse(RecapFilter.meetingChats.matches(files))
        XCTAssertTrue(RecapFilter.recordings.matches(files))
        XCTAssertFalse(RecapFilter.recordings.matches(chatOnly))
        XCTAssertFalse(RecapFilter.transcripts.matches(files))
        XCTAssertTrue(RecapFilter.all.matches(chatOnly))

        let state = RecapsFilterState()
        XCTAssertEqual(RecapFilter.allCases.count, 4)
        state.toggle(.recordings)
        XCTAssertEqual(state.filter, .recordings)
        state.toggle(.recordings)
        XCTAssertEqual(state.filter, .all)
    }

    // MARK: Teams list filter wiring (what the list pane is bound to)

    func testTeamsListFilterWiringSelectsTheRightChannels() async throws {
        let (app, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        await app.teams.load()
        let teams = try XCTUnwrap(model.provider(.teams) as? TeamsSection)
        let prefs = teams.prefs(model)
        let all = app.teams.teams.flatMap { $0.channels }
        let a = try XCTUnwrap(all.first).channelId
        let b = try XCTUnwrap(all.dropFirst().first).channelId
        let c = try XCTUnwrap(all.dropFirst(2).first).channelId
        app.unread.markUnread(chatID: a)
        app.mentions.adopt(app.mentions.mentionedIDs.union([b]))
        prefs.setPinned(c, true)
        func ids(_ f: ChannelFilter) -> Set<String> {
            Set(TeamsListPane.matching(teams: app.teams.teams, filter: f, prefs: prefs,
                                       unread: app.unread, mentions: app.mentions).map(\.id))
        }
        XCTAssertTrue(ids(.unread).contains(a))
        XCTAssertFalse(ids(.unread).contains(b), "control: a mention is not unread")
        XCTAssertTrue(ids(.mentions).contains(b))
        XCTAssertFalse(ids(.mentions).contains(a))
        XCTAssertTrue(ids(.pinned).contains(c))
        XCTAssertFalse(ids(.pinned).contains(a))
        prefs.setLevel(a, .muted)
        XCTAssertTrue(ids(.muted).contains(a))
        // A hidden channel never shows in a filtered list.
        prefs.setHidden(a, true)
        XCTAssertFalse(ids(.muted).contains(a))
        XCTAssertFalse(ids(.unread).contains(a))
    }

    func testWorkflowsSourceIsDemoFakeOrUnavailableByMode() {
        let demo = DemoWorkflowsAPI()
        XCTAssertTrue(TeamsSection.workflowsAPI(demo: true, demoAPI: demo) as AnyObject === demo)
        XCTAssertTrue(TeamsSection.workflowsAPI(demo: false, demoAPI: demo) is UnavailableWorkflowsAPI)
    }

    func testMembersSourceIsDemoFakeOrLiveByMode() {
        let demo = DemoMembersAPI()
        XCTAssertTrue(TeamsSection.membersAPI(demo: true, demoAPI: demo) as AnyObject === demo)
        XCTAssertTrue(TeamsSection.membersAPI(demo: false, demoAPI: demo) is LiveChannelMembersAPI)
    }

    // MARK: Sheets: Manage Channel roster (demo acts in-memory, never the wire)

    func testDemoMembersListAddRemove() async throws {
        let api = DemoMembersAPI()
        let r = ChannelMembersViewModel(teamID: "t", channelID: "c", api: api)
        await r.load()
        if case .loaded = r.state {} else { return XCTFail("expected loaded, got \(r.state)") }
        XCTAssertEqual(r.members.count, 3)
        XCTAssertEqual(ChannelMembersViewModel.sorted(r.members).first?.isOwner, true)
        await r.add(user: "zoe@example.com", owner: false)
        if case .loaded = r.state {} else { return XCTFail("expected loaded after add") }
        XCTAssertEqual(r.members.count, 4)
        let added = try XCTUnwrap(r.members.first { $0.displayName == "zoe@example.com" })
        await r.remove(memberID: added.id)
        XCTAssertEqual(r.members.count, 3)
        XCTAssertNil(r.members.first { $0.id == added.id })
        if case .loaded = r.state {} else { return XCTFail("expected loaded after remove") }
        // Control: a second channel seeds independently.
        let other = try api.list(teamID: "t", channelID: "other")
        XCTAssertEqual(other.members.count, 3)
        XCTAssertTrue(other.members.allSatisfy { !$0.id.contains("-added-") })
    }

    // MARK: Sheets: Manage Channel (what the sheet is bound to, not the team roster)

    func testManageChannelOpensItsOwnSheetNotTheTeamRoster() async throws {
        let (app, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        await app.teams.load()
        let team = try XCTUnwrap(app.teams.teams.first { !$0.channels.isEmpty })
        let ch = try XCTUnwrap(team.channels.first)
        let teams = try XCTUnwrap(model.provider(.teams) as? TeamsSection)
        let before = model.nav.selection(in: .teams)
        XCTAssertTrue(teams.perform(TeamsCommands.manageChannel, arg: ch.channelId, model))
        XCTAssertEqual(model.nav.selection(in: .teams), before, "no roster navigation any more")
        XCTAssertNotNil(teams.sheet(SheetRequest(TeamsCommands.manageChannelSheet, in: .teams, arg: ch.channelId), model))
        // Control: an unknown channel is refused.
        XCTAssertFalse(teams.perform(TeamsCommands.manageChannel, arg: "nope", model))
        XCTAssertEqual(ManageChannelInfo.typeTitle("private"), "Private")
        XCTAssertEqual(ManageChannelInfo.typeTitle(nil), "Standard")
        XCTAssertEqual(ManageChannelInfo.audience("shared"), "Selected people and teams")
    }

    // MARK: Sheets: channel Workflows (demo acts, live unavailable, never writes)

    func testWorkflowsSheetOpensForADemoChannel() async throws {
        let (app, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        await app.teams.load()
        let team = try XCTUnwrap(app.teams.teams.first { !$0.channels.isEmpty })
        let ch = try XCTUnwrap(team.channels.first)
        let teams = try XCTUnwrap(model.provider(.teams) as? TeamsSection)
        XCTAssertTrue(teams.perform(TeamsCommands.channelWorkflows, arg: ch.channelId, model))
        XCTAssertNotNil(teams.sheet(SheetRequest(TeamsCommands.channelWorkflowsSheet, in: .teams, arg: ch.channelId), model))
    }

    func testDemoWorkflowsListAddToggleRun() async throws {
        let store = ChannelWorkflowsStore(api: DemoWorkflowsAPI(now: { Date(timeIntervalSince1970: 5_000) }),
                                          teamID: "t", channelID: "c")
        await store.load()
        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.workflows.count, 2)
        XCTAssertEqual(store.templates.count, DemoWorkflowsAPI.catalog.count)
        await store.add(store.templates[0])
        XCTAssertEqual(store.workflows.count, 3)
        let off = try XCTUnwrap(store.workflows.first { !$0.isEnabled })
        await store.setEnabled(true, off.id)
        XCTAssertTrue(try XCTUnwrap(store.workflows.first { $0.id == off.id }).isEnabled)
        await store.run(off.id)
        let ran = try XCTUnwrap(store.workflows.first { $0.id == off.id })
        XCTAssertEqual(ran.lastRun, Date(timeIntervalSince1970: 5_000))
        XCTAssertEqual(ran.lastRunSucceeded, true)
        XCTAssertNil(store.actionError)
        XCTAssertTrue(store.busy.isEmpty)
    }

    func testFailedRunShowsErrorAndRecordsTheAttempt() async throws {
        let api = DemoWorkflowsAPI()
        let store = ChannelWorkflowsStore(api: api, teamID: "t", channelID: "c")
        await store.load()
        let id = try XCTUnwrap(store.workflows.first).id
        await api.failNextRunOnce()
        await store.run(id)
        XCTAssertNotNil(store.actionError)
        XCTAssertEqual(store.workflows.first { $0.id == id }?.lastRunSucceeded, false)
        XCTAssertEqual(store.state, .loaded, "the list stays")
        await store.run(id)
        XCTAssertNil(store.actionError, "a later success clears it")
    }

    /// Live sign-ins: Workflows say they are unavailable and do nothing;
    /// every call (reads and writes) throws, so no live write can happen.
    func testLiveSourceIsUnavailableAndNeverWrites() async {
        let api = UnavailableWorkflowsAPI()
        let store = ChannelWorkflowsStore(api: api, teamID: "t", channelID: "c")
        await store.load()
        XCTAssertEqual(store.state, .unsupported(UnavailableWorkflowsAPI.reason))
        XCTAssertFalse(store.isSupported)
        XCTAssertTrue(store.workflows.isEmpty)
        let t = WorkflowTemplate(id: "x", name: "x", trigger: "x")
        await assertUnsupported { _ = try await api.add(template: t, teamID: "t", channelID: "c") }
        await assertUnsupported { _ = try await api.setEnabled(true, workflowID: "w") }
        await assertUnsupported { _ = try await api.run(workflowID: "w") }
        // Control: the demo source does not throw.
        let ok = try? await DemoWorkflowsAPI().list(teamID: "t", channelID: "c")
        XCTAssertEqual(ok?.count, 2)
    }

    private func assertUnsupported(_ op: () async throws -> Void, line: UInt = #line) async {
        do { try await op(); XCTFail("expected unsupported", line: line) } catch {
            XCTAssertEqual(error as? ChannelWorkflowsError, .unsupported(UnavailableWorkflowsAPI.reason), line: line)
        }
    }
}
