// ChannelRightsTests.swift — CHANMENU lane: who may edit/delete a
// channel (owner OR member permission, General never deletable, unknown
// answers never hide an action), General listed first, a failed channel
// read never empties a team. Fakes only: nothing reaches the service.
import XCTest

@testable import OstMacCore

@MainActor
final class ChannelRightsTests: XCTestCase {
    private nonisolated static func ch(_ id: String, _ name: String) -> TeamChannel {
        TeamChannel(channelId: id, name: name)
    }

    private nonisolated static let server = [
        TeamItem(teamId: "own", name: "Owned", channels: [ch("g1", "Builds"), ch("g2", "General"), ch("g3", "Ops")]),
        TeamItem(teamId: "mem", name: "Member", channels: [ch("m1", "General"), ch("m2", "Launch")]),
        TeamItem(teamId: "unk", name: "Unknown", channels: [ch("u1", "General"), ch("u2", "Plans")]),
    ]

    private func model(
        settings: @escaping @Sendable (String) throws -> TeamMemberSettings,
        owner: @escaping @Sendable (String) throws -> Bool = { $0 == "own" },
        rows: LockedBox<[TeamItem]> = LockedBox(server)
    ) -> TeamsViewModel {
        TeamsViewModel(
            fetcher: { TeamsResponse(ok: true, teams: rows.value) },
            ownerCheck: { id in
                if id == "unk" { throw CoreCallError.failed("roster unreadable") }
                return try owner(id)
            },
            settingsFetcher: settings)
    }

    func testPureGate() {
        let no = TeamMemberSettings(allowDeleteChannels: false, allowCreateUpdateChannels: false)
        // Owner beats a closed setting.
        XCTAssertTrue(ChannelRights.evaluate(.delete, isGeneral: false, isOwner: true, settings: no).isAllowed)
        // Member with the setting closed: refused with a reason.
        XCTAssertEqual(ChannelRights.evaluate(.delete, isGeneral: false, isOwner: false, settings: no),
                       .denied("Only team owners can delete channels in this team."))
        XCTAssertEqual(ChannelRights.evaluate(.edit, isGeneral: false, isOwner: false, settings: no).reason,
                       "Only team owners can edit channels in this team.")
        // Member with it open, or unknown: allowed (Teams decides).
        let yes = TeamMemberSettings(allowDeleteChannels: true, allowCreateUpdateChannels: true)
        XCTAssertTrue(ChannelRights.evaluate(.delete, isGeneral: false, isOwner: false, settings: yes).isAllowed)
        XCTAssertTrue(ChannelRights.evaluate(.delete, isGeneral: false, isOwner: false, settings: nil).isAllowed)
        // Ownership unknown never denies, even with the setting closed.
        XCTAssertTrue(ChannelRights.evaluate(.delete, isGeneral: false, isOwner: nil, settings: no).isAllowed)
        // General: never deletable, even for an owner; still editable.
        XCTAssertEqual(ChannelRights.evaluate(.delete, isGeneral: true, isOwner: true, settings: yes),
                       .denied("The General channel can't be deleted."))
        XCTAssertTrue(ChannelRights.evaluate(.edit, isGeneral: true, isOwner: true, settings: yes).isAllowed)
    }

    func testViewModelGateFromReads() async {
        let vm = model(settings: { id in
            id == "mem"
                ? TeamMemberSettings(allowDeleteChannels: false, allowCreateUpdateChannels: true,
                                     primaryChannelId: "m1")
                : TeamMemberSettings(primaryChannelId: id == "own" ? "g2" : nil)
        })
        await vm.load()
        await vm.refreshOwnership()
        // Owner: deletes an ordinary channel, not General.
        XCTAssertTrue(vm.permission(.delete, teamID: "own", channelID: "g1").isAllowed)
        XCTAssertFalse(vm.permission(.delete, teamID: "own", channelID: "g2").isAllowed)
        // Member, delete closed / edit open.
        XCTAssertFalse(vm.permission(.delete, teamID: "mem", channelID: "m2").isAllowed)
        XCTAssertTrue(vm.permission(.edit, teamID: "mem", channelID: "m2").isAllowed)
        // Roster unreadable: unknown owner stays allowed, General still guarded by name.
        XCTAssertTrue(vm.permission(.delete, teamID: "unk", channelID: "u2").isAllowed)
        XCTAssertFalse(vm.permission(.delete, teamID: "unk", channelID: "u1").isAllowed)
    }

    func testPrimaryIdBeatsName() async {
        // A localized General: the primary id marks it, the name does not.
        let rows = [TeamItem(teamId: "own", name: "Owned", channels: [Self.ch("x1", "Ops"), Self.ch("x2", "Allgemein")])]
        let vm = model(settings: { _ in TeamMemberSettings(primaryChannelId: "x2") }, rows: LockedBox(rows))
        await vm.load()
        await vm.refreshOwnership()
        XCTAssertFalse(vm.permission(.delete, teamID: "own", channelID: "x2").isAllowed)
        XCTAssertTrue(vm.permission(.delete, teamID: "own", channelID: "x1").isAllowed)
        // And it moves to the top once the primary id is known.
        XCTAssertEqual(vm.teams[0].channels.map(\.channelId), ["x2", "x1"])
    }

    func testGeneralListedFirstStable() async {
        let vm = model(settings: { _ in throw CoreCallError.failed("x") })
        await vm.load()
        XCTAssertEqual(vm.teams[0].channels.map(\.name), ["General", "Builds", "Ops"])
        XCTAssertEqual(vm.teams[1].channels.map(\.name), ["General", "Launch"])
    }

    func testFailedChannelReadNeverEmptiesTeamOrFlagsDeleted() async {
        let rows = LockedBox(Self.server)
        let vm = model(settings: { _ in throw CoreCallError.failed("x") }, rows: rows)
        await vm.load()
        // A refresh where one team's channel read failed (comes back empty).
        rows.value = [Self.server[0], TeamItem(teamId: "mem", name: "Member", channels: []), Self.server[2]]
        _ = await vm.sync()
        XCTAssertEqual(vm.teams[1].channels.count, 2)
        XCTAssertTrue(vm.deletedChannelIDs.isEmpty)
    }

    func testRemoteDeleteAndRenameApplyAsDiff() async {
        let rows = LockedBox(Self.server)
        let vm = model(settings: { _ in throw CoreCallError.failed("x") }, rows: rows)
        await vm.load()
        // Deleted elsewhere: row leaves, id is recorded for the inline state.
        rows.value = [TeamItem(teamId: "own", name: "Owned", channels: [Self.ch("g2", "General"), Self.ch("g3", "Ops")]),
                      Self.server[1], Self.server[2]]
        _ = await vm.sync()
        XCTAssertFalse(vm.teams[0].channels.contains { $0.channelId == "g1" })
        XCTAssertTrue(vm.deletedChannelIDs.contains("g1"))
        // Renamed elsewhere: same id, new name, no deleted flag.
        rows.value = [TeamItem(teamId: "own", name: "Owned", channels: [Self.ch("g2", "General"), Self.ch("g3", "Operations")]),
                      Self.server[1], Self.server[2]]
        let before = vm.syncChanges
        _ = await vm.sync()
        XCTAssertEqual(vm.teams[0].channels.last?.name, "Operations")
        XCTAssertEqual(vm.syncChanges, before + 1)
        XCTAssertFalse(vm.deletedChannelIDs.contains("g3"))
    }

    func testDeleteRequestShapeReachesDeleterOnce() async {
        let seen = LockedBox<[String]>([])
        let vm = TeamsViewModel(
            fetcher: { TeamsResponse(ok: true, teams: Self.server) },
            channelDeleter: { t, c in seen.value.append("\(t)/\(c)") },
            ownerCheck: { _ in true },
            settingsFetcher: { _ in TeamMemberSettings() })
        await vm.load()
        let ok = await vm.deleteChannel(teamID: "own", channelID: "g3")
        XCTAssertTrue(ok)
        XCTAssertEqual(seen.value, ["own/g3"])
        XCTAssertFalse(vm.teams[0].channels.contains { $0.channelId == "g3" })
    }

    func testSettingsDecodeNullsAsUnknown() throws {
        let json = #"{"ok":true,"team_id":"t","allow_delete_channels":null,"allow_create_update_channels":false,"primary_channel_id":null}"#
        let s = try JSONDecoder().decode(TeamMemberSettings.self, from: Data(json.utf8))
        XCTAssertNil(s.allowDeleteChannels)
        XCTAssertEqual(s.allowCreateUpdateChannels, false)
        XCTAssertNil(s.primaryChannelId)
    }

    func testMovingAChannelToASectionPersists() throws {
        let suite = "chanmenu-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FolderStore(defaults: defaults)
        let folder = try XCTUnwrap(store.createFolder(name: "Projects"))
        store.assign(chatID: "g1", folderID: folder.id)
        XCTAssertEqual(store.overrides["g1"], folder.id)
        // A fresh store on the same defaults (next launch) still has it.
        XCTAssertEqual(FolderStore(defaults: defaults).overrides["g1"], folder.id)
        store.assign(chatID: "g1", folderID: nil)
        XCTAssertNil(FolderStore(defaults: defaults).overrides["g1"])
    }
}
