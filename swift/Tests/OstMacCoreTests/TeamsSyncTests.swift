// TeamsSyncTests.swift — TEAMSYNC lane: channel/team menu writes
// (optimistic + rollback), diff-applied tree sync, sync driver
// schedule, realtime thread-update decode. Fakes only: no write ever
// reaches the service. One opt-in read-only live latency probe.
import XCTest

@testable import OstMacCore

@MainActor
final class TeamsSyncTests: XCTestCase {
    private nonisolated static func ch(_ id: String, _ name: String) -> TeamChannel {
        TeamChannel(channelId: id, name: name)
    }

    private nonisolated static func tree(_ channels: [TeamChannel], second: Bool = true) -> [TeamItem] {
        var teams = [TeamItem(teamId: "team-1", name: "Engineering", channels: channels)]
        if second {
            teams.append(TeamItem(teamId: "team-2", name: "Design", channels: [ch("19:d@thread.tacv2", "General")]))
        }
        return teams
    }

    private nonisolated static let base = tree([
        ch("19:a@thread.tacv2", "General"), ch("19:b@thread.tacv2", "Builds"), ch("19:c@thread.tacv2", "Ops"),
    ])

    private func model(
        server: LockedBox<[TeamItem]>,
        fail: Bool = false,
        writes: LockedBox<Int> = LockedBox(0)
    ) -> TeamsViewModel {
        TeamsViewModel(
            fetcher: { TeamsResponse(ok: true, teams: server.value) },
            channelDeleter: { _, _ in
                writes.value += 1
                if fail { throw CoreCallError.failed("boom") }
            },
            channelUpdater: { _, _, _, _ in
                writes.value += 1
                if fail { throw CoreCallError.failed("boom") }
            },
            teamLeaver: { _ in
                writes.value += 1
                if fail { throw CoreCallError.failed("boom") }
            },
            ownerCheck: { $0 == "team-1" },
            settingsFetcher: { _ in throw CoreCallError.failed("no settings") })
    }

    // MARK: - Diff-applied sync

    func testIdenticalTreePublishesNothing() async {
        let server = LockedBox(Self.base)
        let vm = model(server: server)
        await vm.load()
        var publishes = 0
        let sub = vm.$teams.dropFirst().sink { _ in publishes += 1 }
        let ok = await vm.sync()
        XCTAssertTrue(ok)
        XCTAssertEqual(publishes, 0)
        XCTAssertEqual(vm.syncChanges, 0)
        sub.cancel()
    }

    func testRemoteDeleteRenameAddAndLeaveLandOnSync() async {
        let server = LockedBox(Self.base)
        let vm = model(server: server)
        await vm.load()
        server.value = [TeamItem(teamId: "team-1", name: "Engineering", channels: [
            Self.ch("19:a@thread.tacv2", "General"),
            Self.ch("19:c@thread.tacv2", "Operations"),
            Self.ch("19:e@thread.tacv2", "Launch"),
        ])]
        await vm.sync()
        XCTAssertEqual(vm.teams.map(\.teamId), ["team-1"])
        XCTAssertEqual(vm.teams[0].channels.map(\.name), ["General", "Operations", "Launch"])
        XCTAssertEqual(vm.deletedChannelIDs, ["19:b@thread.tacv2", "19:d@thread.tacv2"])
        XCTAssertEqual(vm.syncChanges, 1)
        // A channel that comes back leaves the deleted set.
        server.value = Self.base
        await vm.sync()
        XCTAssertFalse(vm.deletedChannelIDs.contains("19:b@thread.tacv2"))
    }

    func testFailedSyncKeepsRows() async {
        let server = LockedBox(Self.base)
        let flaky = LockedBox(false)
        let vm = TeamsViewModel(fetcher: {
            if flaky.value { throw CoreCallError.failed("offline") }
            return TeamsResponse(ok: true, teams: server.value)
        })
        await vm.load()
        flaky.value = true
        let ok = await vm.sync()
        XCTAssertFalse(ok)
        XCTAssertEqual(vm.teams, Self.base)
        XCTAssertEqual(vm.state, .loaded)
    }

    // MARK: - Menu writes

    func testDeleteChannelOptimisticThenCommitted() async {
        let server = LockedBox(Self.base)
        let writes = LockedBox(0)
        let vm = model(server: server, writes: writes)
        await vm.load()
        let ok = await vm.deleteChannel(teamID: "team-1", channelID: "19:b@thread.tacv2")
        XCTAssertTrue(ok)
        XCTAssertEqual(writes.value, 1)
        XCTAssertEqual(vm.teams[0].channels.map(\.channelId), ["19:a@thread.tacv2", "19:c@thread.tacv2"])
        XCTAssertTrue(vm.deletedChannelIDs.contains("19:b@thread.tacv2"))
        XCTAssertNil(vm.actionError)
    }

    func testDeleteChannelFailureRollsBackInPlace() async {
        let server = LockedBox(Self.base)
        let vm = model(server: server, fail: true)
        await vm.load()
        let ok = await vm.deleteChannel(teamID: "team-1", channelID: "19:b@thread.tacv2")
        XCTAssertFalse(ok)
        XCTAssertEqual(vm.teams, Self.base)
        XCTAssertFalse(vm.deletedChannelIDs.contains("19:b@thread.tacv2"))
        XCTAssertNotNil(vm.actionError)
    }

    func testEditChannelAndRollback() async {
        let server = LockedBox(Self.base)
        let vm = model(server: server)
        await vm.load()
        let ok = await vm.updateChannel(
            teamID: "team-1", channelID: "19:b@thread.tacv2", name: " CI ", description: "Nightly")
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.teams[0].channels[1].name, "CI")
        XCTAssertEqual(vm.teams[0].channels[1].description, "Nightly")

        let failing = model(server: server, fail: true)
        await failing.load()
        let bad = await failing.updateChannel(
            teamID: "team-1", channelID: "19:b@thread.tacv2", name: "CI", description: nil)
        XCTAssertFalse(bad)
        XCTAssertEqual(failing.teams, Self.base)
        XCTAssertNotNil(failing.actionError)
    }

    func testLeaveTeamAndRollback() async {
        let server = LockedBox(Self.base)
        let vm = model(server: server)
        await vm.load()
        let left = await vm.leaveTeam(teamID: "team-2")
        XCTAssertTrue(left)
        XCTAssertEqual(vm.teams.map(\.teamId), ["team-1"])
        XCTAssertTrue(vm.deletedChannelIDs.contains("19:d@thread.tacv2"))

        let failing = model(server: server, fail: true)
        await failing.load()
        let refused = await failing.leaveTeam(teamID: "team-2")
        XCTAssertFalse(refused)
        XCTAssertEqual(failing.teams, Self.base)
        XCTAssertNotNil(failing.actionError)
    }

    func testOwnershipGatesChannelWrites() async {
        let vm = model(server: LockedBox(Self.base))
        await vm.load()
        await vm.refreshOwnership()
        XCTAssertTrue(vm.canManageChannels(teamID: "team-1"))
        XCTAssertFalse(vm.canManageChannels(teamID: "team-2"))
    }

    // MARK: - Driver

    func testBackoffSchedule() {
        XCTAssertEqual(TeamsSync.delay(active: true, failures: 0), 15)
        XCTAssertEqual(TeamsSync.delay(active: false, failures: 0), 60)
        XCTAssertEqual(TeamsSync.delay(active: true, failures: 1), 30)
        XCTAssertEqual(TeamsSync.delay(active: true, failures: 3), 120)
        XCTAssertEqual(TeamsSync.delay(active: true, failures: 9), 300)
        XCTAssertEqual(TeamsSync.delay(active: false, failures: 1), 120)
    }

    func testKickLandsRemoteDeleteWithinSeconds() async throws {
        let server = LockedBox(Self.base)
        let vm = model(server: server)
        await vm.load()
        let sync = TeamsSync(model: vm, isActive: { true })
        server.value = Self.tree([Self.ch("19:a@thread.tacv2", "General")])
        sync.kick(after: 0.05)
        // Only the kick can drive a sync here (start() is never called, so no
        // periodic loop exists): the change landing at all proves the kick
        // path; no wall-clock bound needed.
        await TestWait.until { vm.syncChanges > 0 }
        XCTAssertGreaterThan(vm.syncChanges, 0)
        XCTAssertEqual(vm.teams[0].channels.count, 1)
        XCTAssertEqual(sync.failures, 0)
    }

    func testDemoLedgerKeepsWritesAcrossRefresh() throws {
        let ledger = DemoTeams.Ledger()
        let first = DemoTeams.response(ledger: ledger).teams
        let team = try XCTUnwrap(first.first)
        let chan = try XCTUnwrap(team.channels.last)
        XCTAssertNotNil(chan.email)
        ledger.editChannel(chan.channelId, name: "Renamed", description: nil)
        ledger.deleteChannel(team.channels[0].channelId)
        let after = DemoTeams.response(ledger: ledger).teams
        XCTAssertFalse(after[0].channels.contains { $0.channelId == team.channels[0].channelId })
        XCTAssertEqual(after[0].channels.last?.name, "Renamed")
        ledger.leaveTeam(team.teamId)
        XCTAssertFalse(DemoTeams.response(ledger: ledger).teams.contains { $0.teamId == team.teamId })
    }

    // MARK: - Realtime

    func testPollDecodesThreadUpdatesAndOldBuilds() throws {
        let new = #"{"ok":true,"messages":[],"resync":false,"skipped":0,"threads":["19:t@thread.tacv2"]}"#
        let old = #"{"ok":true,"messages":[],"resync":false,"skipped":0}"#
        XCTAssertEqual(try JSONDecoder().decode(RealtimePoll.self, from: Data(new.utf8)).threads,
                       ["19:t@thread.tacv2"])
        XCTAssertNil(try JSONDecoder().decode(RealtimePoll.self, from: Data(old.utf8)).threads)
    }

    func testFeedDispatchesThreadUpdates() throws {
        let got = LockedBox<[String]>([])
        let feed = RealtimeFeed(
            poll: { RealtimePoll(ok: true, messages: [], resync: false, skipped: 0, threads: ["19:t@thread.tacv2"]) },
            pollWait: { _ in RealtimePoll(ok: true, messages: [], resync: false, skipped: 0) },
            start: { 0 }, stop: { 0 })
        feed.onThreadUpdate { ids in got.mutate { $0 += ids } }
        _ = try feed.pollOnce()
        XCTAssertEqual(got.value, ["19:t@thread.tacv2"])
    }

    // MARK: - Live (read-only, opt-in)

    /// Read-only refresh latency on the signed-in account: one full tree
    /// GET per run. Opt-in (`TEAMSYNC_LIVE=1`); prints counts and ms only.
    func testLiveRefreshLatencyReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["TEAMSYNC_LIVE"] == "1" else {
            throw XCTSkip("set TEAMSYNC_LIVE=1 for the read-only live latency probe")
        }
        let vm = TeamsViewModel(ownerCheck: { _ in false })
        let sync = TeamsSync(model: vm, isActive: { true })
        // Two runs: cold (token + first GETs), then warm (steady state).
        for run in ["cold", "warm"] {
            await sync.runNow()
            let teams = vm.teams.count
            let channels = vm.teams.reduce(0) { $0 + $1.channels.count }
            let ms = Int((sync.lastLatency ?? -1) * 1000)
            print("TEAMSYNC_LIVE run=\(run) teams=\(teams) channels=\(channels) refresh_ms=\(ms) ok=\(sync.failures == 0)")
            XCTAssertEqual(sync.failures, 0)
        }
    }
}
