// TeamAdminMenuTests.swift — team-admin lane: the owner-only team
// lifecycle items disable with their reason (offline, non-owner).
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

@MainActor
final class TeamAdminMenuTests: XCTestCase {
    nonisolated private static func rows() -> [TeamItem] {
        [TeamItem(teamId: "team-1", name: "Engineering",
                  channels: [TeamChannel(channelId: "c1", name: "General")])]
    }

    private func model(owner: @escaping @Sendable (String) throws -> Bool) -> TeamsViewModel {
        TeamsViewModel(
            fetcher: { TeamsResponse(ok: true, teams: Self.rows()) },
            ownerCheck: owner)
    }

    func testTeamAdminDisabledReasons() async {
        let full = model(owner: { _ in true })
        await full.load()
        await full.refreshOwnership()
        XCTAssertNil(TeamsListPane.teamAdminDisabled(teamID: "team-1", teams: full, offline: false))
        XCTAssertEqual(TeamsListPane.teamAdminDisabled(teamID: "team-1", teams: full, offline: true),
                       "You're offline.")

        let stranger = model(owner: { _ in false })
        await stranger.load()
        await stranger.refreshOwnership()
        XCTAssertEqual(TeamsListPane.teamAdminDisabled(teamID: "team-1", teams: stranger, offline: false),
                       "Only team owners can do this.")

        // Unknown ownership (pass never ran) fails closed too.
        let unknown = model(owner: { _ in true })
        await unknown.load()
        XCTAssertEqual(TeamsListPane.teamAdminDisabled(teamID: "team-1", teams: unknown, offline: false),
                       "Only team owners can do this.")
    }
}
