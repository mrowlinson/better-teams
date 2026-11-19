// TeamAdminTests.swift — team-admin lane: team rename/re-describe,
// picture, archive/restore and delete (ViewModel + wire decode).
import XCTest

@testable import OstMacCore

@MainActor
final class TeamAdminTests: XCTestCase {
    nonisolated private static func rows() -> [TeamItem] {
        [TeamItem(teamId: "team-1", name: "Engineering",
                  channels: [TeamChannel(channelId: "c1", name: "General")]),
         TeamItem(teamId: "team-2", name: "Lonely", channels: [])]
    }

    private func model(
        owner: @escaping @Sendable (String) throws -> Bool = { _ in true },
        updater: @escaping @Sendable (String, String?, String?) throws -> Void = { _, _, _ in },
        photo: @escaping @Sendable (String, String) throws -> Void = { _, _ in },
        archiver: @escaping @Sendable (String) throws -> Void = { _ in },
        unarchiver: @escaping @Sendable (String) throws -> Void = { _ in },
        deleter: @escaping @Sendable (String) throws -> Void = { _ in },
        rows: [TeamItem]? = nil
    ) -> TeamsViewModel {
        TeamsViewModel(
            fetcher: { TeamsResponse(ok: true, teams: rows ?? Self.rows()) },
            ownerCheck: owner,
            teamUpdater: updater,
            teamPhotoSetter: photo,
            teamArchiver: archiver,
            teamUnarchiver: unarchiver,
            teamDeleter: deleter)
    }

    private func name(of vm: TeamsViewModel, team: String) -> String? {
        vm.teams.first { $0.teamId == team }?.name
    }

    // MARK: - Wire decode (new lifecycle fields stay backward compatible)

    func testDecodeLifecycleFields() throws {
        let json = "{\"ok\":true,\"teams\":[{\"id\":\"team-9\",\"name\":\"Squad\",\"description\":\"Ships it\",\"is_archived\":true,\"channels\":[]}]}"
        let response = try decodeOrThrow(TeamsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.teams[0].description, "Ships it")
        XCTAssertEqual(response.teams[0].isArchived, true)
        // Old payloads (no lifecycle keys) decode with nils.
        let legacy = try decodeOrThrow(
            TeamsResponse.self, from: Data("{\"ok\":true,\"teams\":[{\"id\":\"t\",\"name\":\"N\",\"channels\":[]}]}".utf8))
        XCTAssertNil(legacy.teams[0].description)
        XCTAssertNil(legacy.teams[0].isArchived)
    }

    // MARK: - Owner gate (fail closed)

    func testAdminGateFailClosed() async {
        let vm = model(owner: { $0 == "team-1" })
        await vm.load()
        // Unknown until the ownership pass runs: disabled, never a guess.
        XCTAssertFalse(vm.canAdminTeam(teamID: "team-1"))
        await vm.refreshOwnership()
        XCTAssertTrue(vm.canAdminTeam(teamID: "team-1"))
        XCTAssertFalse(vm.canAdminTeam(teamID: "team-2"))
        XCTAssertFalse(vm.canAdminTeam(teamID: "ghost"))
    }

    func testNonOwnerWritesRefuseBeforeNetwork() async {
        var calls = 0
        let vm = model(
            owner: { _ in false },
            updater: { _, _, _ in calls += 1 },
            photo: { _, _ in calls += 1 },
            archiver: { _ in calls += 1 },
            deleter: { _ in calls += 1 })
        await vm.load()
        await vm.refreshOwnership()
        let renamed = await vm.updateTeam(teamID: "team-1", name: "X", description: nil)
        XCTAssertFalse(renamed)
        XCTAssertEqual(vm.actionError, "Only team owners can edit the team.")
        let pictured = await vm.setTeamPhoto(teamID: "team-1", base64: "aGk=")
        XCTAssertFalse(pictured)
        XCTAssertEqual(vm.actionError, "Only team owners can change the team picture.")
        let archived = await vm.archiveTeam(teamID: "team-1")
        XCTAssertFalse(archived)
        XCTAssertEqual(vm.actionError, "Only team owners can archive the team.")
        let deleted = await vm.deleteTeam(teamID: "team-1")
        XCTAssertFalse(deleted)
        XCTAssertEqual(vm.actionError, "Only team owners can delete the team.")
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(vm.teams.count, 2)
    }

    // MARK: - Rename / re-describe

    func testUpdateTeamOptimisticAndRevert() async {
        let seen = LockedBox<[String?]>([nil, nil])
        let vm = model(updater: { _, n, d in seen.value = [n, d] })
        await vm.load()
        await vm.refreshOwnership()
        let ok = await vm.updateTeam(teamID: "team-1", name: "  Launch  ", description: " Plans ")
        XCTAssertTrue(ok)
        XCTAssertEqual(name(of: vm, team: "team-1"), "Launch")
        XCTAssertEqual(vm.teams.first { $0.teamId == "team-1" }?.description, "Plans")
        XCTAssertEqual(seen.value[0], "Launch") // trimmed before core
        XCTAssertEqual(seen.value[1], "Plans")
        XCTAssertNil(vm.actionError)

        struct Boom: Error {}
        let vm2 = model(updater: { _, _, _ in throw Boom() })
        await vm2.load()
        await vm2.refreshOwnership()
        let failed = await vm2.updateTeam(teamID: "team-1", name: "Nope", description: nil)
        XCTAssertFalse(failed)
        XCTAssertEqual(self.name(of: vm2, team: "team-1"), "Engineering")
        XCTAssertNotNil(vm2.actionError)
    }

    func testUpdateTeamBlankIsNoop() async {
        let calls = LockedBox(0)
        let vm = model(updater: { _, _, _ in calls.mutate { $0 += 1 } })
        await vm.load()
        await vm.refreshOwnership()
        let blank = await vm.updateTeam(teamID: "team-1", name: "   ", description: nil)
        XCTAssertFalse(blank)
        let ghost = await vm.updateTeam(teamID: "ghost", name: "X", description: nil)
        XCTAssertFalse(ghost)
        XCTAssertEqual(calls.value, 0)
    }

    // MARK: - Picture

    func testSetPhotoCallsCore() async {
        let seen = LockedBox("")
        let vm = model(photo: { _, b in seen.value = b })
        await vm.load()
        await vm.refreshOwnership()
        let ok = await vm.setTeamPhoto(teamID: "team-1", base64: "aGk=")
        XCTAssertTrue(ok)
        XCTAssertEqual(seen.value, "aGk=")
        XCTAssertNil(vm.actionError)
        // Blank bytes never reach core.
        let blank = await vm.setTeamPhoto(teamID: "team-1", base64: "   ")
        XCTAssertFalse(blank)
    }

    // MARK: - Archive / restore

    func testArchiveRestoreFlagsAndRevert() async {
        let vm = model()
        await vm.load()
        await vm.refreshOwnership()
        let archived = await vm.archiveTeam(teamID: "team-1")
        XCTAssertTrue(archived)
        XCTAssertEqual(vm.teams.first { $0.teamId == "team-1" }?.isArchived, true)
        let restored = await vm.unarchiveTeam(teamID: "team-1")
        XCTAssertTrue(restored)
        XCTAssertEqual(vm.teams.first { $0.teamId == "team-1" }?.isArchived, false)

        struct Boom: Error {}
        let vm2 = model(archiver: { _ in throw Boom() })
        await vm2.load()
        await vm2.refreshOwnership()
        let failed = await vm2.archiveTeam(teamID: "team-1")
        XCTAssertFalse(failed)
        XCTAssertNil(vm2.teams.first { $0.teamId == "team-1" }?.isArchived)
        let ghost = await vm2.archiveTeam(teamID: "ghost")
        XCTAssertFalse(ghost)
    }

    // MARK: - Delete

    func testDeleteRemovesTeamAndRevert() async {
        let vm = model()
        await vm.load()
        await vm.refreshOwnership()
        XCTAssertTrue(vm.ownedTeamIDs.contains("team-1"))
        let ok = await vm.deleteTeam(teamID: "team-1")
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.teams.count, 1)
        XCTAssertFalse(vm.ownedTeamIDs.contains("team-1"))
        let ghost = await vm.deleteTeam(teamID: "ghost")
        XCTAssertFalse(ghost)

        struct Boom: Error {}
        let vm2 = model(deleter: { _ in throw Boom() })
        await vm2.load()
        await vm2.refreshOwnership()
        let failed = await vm2.deleteTeam(teamID: "team-1")
        XCTAssertFalse(failed)
        XCTAssertEqual(vm2.teams.count, 2)
        XCTAssertNotNil(vm2.actionError)
    }
}
