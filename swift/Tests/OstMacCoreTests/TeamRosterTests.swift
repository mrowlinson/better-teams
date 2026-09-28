// TeamRosterTests.swift — om-h5-members lane: wire decode, name fallback, ViewModel.
import XCTest

@testable import OstMacCore

@MainActor
final class TeamRosterTests: XCTestCase {
    // MARK: - Fixtures

    nonisolated static func rosterJSON() -> TeamMembersResponse {
        let json = """
            {"ok":true,"team_id":"team-1","members":[\
            {"id":"M1","display_name":"Doe, Jane","user_id":"oid-1","email":"j@x.example","roles":["owner"],"is_owner":true},\
            {"id":"M2","display_name":"","user_id":"oid-2","email":null,"roles":[],"is_owner":false},\
            {"id":"M3","display_name":"M3","user_id":null,"email":null,"roles":[],"is_owner":false}]}
            """
        return try! decodeOrThrow(TeamMembersResponse.self, from: Data(json.utf8))
    }

    static func model(
        list: @escaping TeamRosterViewModel.ListFetcher,
        add: @escaping TeamRosterViewModel.AddFetcher = { _, _, _ in throw CoreCallError.failed("no add") },
        remove: @escaping TeamRosterViewModel.RemoveFetcher = { _, _ in throw CoreCallError.failed("no remove") }
    ) -> TeamRosterViewModel {
        TeamRosterViewModel(teamID: "team-1", listFetcher: list, addFetcher: add, removeFetcher: remove)
    }

    // MARK: - Wire decode

    func testDecodeWireShape() {
        let response = Self.rosterJSON()
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.teamId, "team-1")
        XCTAssertEqual(response.members.count, 3)
        XCTAssertEqual(response.members[0].id, "M1")
        XCTAssertEqual(response.members[0].displayName, "Doe, Jane")
        XCTAssertEqual(response.members[0].userId, "oid-1")
        XCTAssertEqual(response.members[0].email, "j@x.example")
        XCTAssertEqual(response.members[0].roles, ["owner"])
        XCTAssertTrue(response.members[0].isOwner)
        XCTAssertFalse(response.members[1].isOwner)
        XCTAssertNil(response.members[2].userId)
        XCTAssertNil(response.members[2].email)
    }

    func testDecodeAddRemoveShapes() {
        let add = try! decodeOrThrow(
            TeamMemberAddResponse.self,
            from: Data(#"{"ok":true,"member":{"id":"M9","display_name":"New Guy","user_id":"oid-9","email":null,"roles":[],"is_owner":false}}"#.utf8))
        XCTAssertTrue(add.ok)
        XCTAssertEqual(add.member.id, "M9")
        let remove = try! decodeOrThrow(
            TeamMemberRemoveResponse.self,
            from: Data(#"{"ok":true,"team_id":"team-1","member_id":"M2"}"#.utf8))
        XCTAssertTrue(remove.ok)
        XCTAssertEqual(remove.teamId, "team-1")
        XCTAssertEqual(remove.memberId, "M2")
    }

    func testErrorEnvelopeThrows() {
        let json = #"{"ok":false,"error":"team_members","detail":"nope"}"#
        XCTAssertThrowsError(
            try decodeOrThrow(TeamMembersResponse.self, from: Data(json.utf8)))
    }

    // MARK: - Name fallback chain

    func testDisplayNamePrefersGraphName() {
        let m = Self.rosterJSON().members[0]
        XCTAssertEqual(TeamRosterViewModel.displayName(for: m, names: ["oid-1": "Wrong"]), "Doe, Jane")
    }

    func testDisplayNameFallsBackToCallerMapThenId() {
        let blank = Self.rosterJSON().members[1]
        // Caller map keyed by raw user id.
        XCTAssertEqual(TeamRosterViewModel.displayName(for: blank, names: ["oid-2": "Mapped Mate"]), "Mapped Mate")
        // Caller map keyed by orgid MRI.
        XCTAssertEqual(TeamRosterViewModel.displayName(for: blank, names: ["8:orgid:oid-2": "MRI Mate"]), "MRI Mate")
        // No map, no email: membership id.
        XCTAssertEqual(TeamRosterViewModel.displayName(for: blank), "M2")
        // Email beats id.
        let withMail = TeamMember(id: "M4", displayName: "  ", userId: nil, email: "g@x.example")
        XCTAssertEqual(TeamRosterViewModel.displayName(for: withMail), "g@x.example")
    }

    // MARK: - Sort / partition / filter

    func testSortedOwnersFirstThenName() {
        let members = Self.rosterJSON().members
        let sorted = TeamRosterViewModel.sorted(members)
        XCTAssertTrue(sorted[0].isOwner)
        XCTAssertEqual(TeamRosterViewModel.owners(of: members).count, 1)
        XCTAssertEqual(TeamRosterViewModel.nonOwners(of: members).count, 2)
    }

    func testFilterMatchesNameEmailId() {
        let members = Self.rosterJSON().members
        XCTAssertEqual(TeamRosterViewModel.filtered(members, query: "  ").count, 3)
        XCTAssertEqual(TeamRosterViewModel.filtered(members, query: "jane").count, 1)
        XCTAssertEqual(TeamRosterViewModel.filtered(members, query: "x.example").count, 1)
        XCTAssertEqual(TeamRosterViewModel.filtered(members, query: "m3").count, 1)
        XCTAssertTrue(TeamRosterViewModel.filtered(members, query: "zzz").isEmpty)
    }

    // MARK: - ViewModel states

    func testLoadPopulatesRoster() async {
        let response = Self.rosterJSON()
        let model = Self.model(list: { _ in response })
        XCTAssertEqual(model.state, .loading)
        await model.load()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.members.count, 3)
    }

    func testLoadEmptyAndError() async {
        let empty = Self.model(list: { team in TeamMembersResponse(ok: true, teamId: team, members: []) })
        await empty.load()
        XCTAssertEqual(empty.state, .empty)
        let failing = Self.model(list: { _ in throw CoreCallError.failed("boom") })
        await failing.load()
        XCTAssertEqual(failing.state, .error("boom"))
    }

    func testAddAppendsAndRemoveDrops() async {
        let response = Self.rosterJSON()
        let added = TeamMember(id: "M9", displayName: "New Guy", userId: "oid-9")
        let model = Self.model(
            list: { _ in response },
            add: { team, user, owner in
                XCTAssertEqual(team, "team-1")
                XCTAssertEqual(user, "new@x.example")
                XCTAssertTrue(owner)
                return TeamMemberAddResponse(ok: true, member: added)
            },
            remove: { team, member in
                XCTAssertEqual(team, "team-1")
                return TeamMemberRemoveResponse(ok: true, teamId: team, memberId: member)
            })
        await model.load()
        XCTAssertEqual(model.members.count, 3)
        await model.add(user: "new@x.example", owner: true)
        XCTAssertEqual(model.members.count, 4)
        XCTAssertEqual(model.state, .loaded)
        await model.remove(memberID: "M2")
        XCTAssertEqual(model.members.count, 3)
        XCTAssertFalse(model.members.contains { $0.id == "M2" })
    }

    func testRemoveFailureKeepsRow() async {
        let response = Self.rosterJSON()
        let model = Self.model(
            list: { _ in response },
            remove: { _, _ in throw CoreCallError.failed("forbidden") })
        await model.load()
        await model.remove(memberID: "M1")
        XCTAssertEqual(model.members.count, 3)
        XCTAssertEqual(model.state, .error("forbidden"))
    }
}
