// TeamCreateTests.swift — om-jf-teamcreate lane: team-create wire decode + ViewModel + sheet gate.
import XCTest

@testable import OstMacCore

@MainActor
final class TeamCreateTests: XCTestCase {
    // MARK: - Wire decode

    func testDecodeCreateEnvelope() throws {
        let json = """
            {"ok":true,"team":{"id":"team-9","name":"Squad","channels":[]},\
            "polls":4,"elapsed_ms":12500}
            """
        let response = try decodeOrThrow(TeamCreateResponse.self, from: Data(json.utf8))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.team.teamId, "team-9")
        XCTAssertEqual(response.team.name, "Squad")
        XCTAssertTrue(response.team.channels.isEmpty)
        XCTAssertEqual(response.polls, 4)
        XCTAssertEqual(response.elapsedMs, 12500)
    }

    func testDecodeLegacyEnvelopeWithoutTelemetry() throws {
        // polls/elapsed_ms are optional: older cores stay decodable.
        let json = """
            {"ok":true,"team":{"id":"team-9","name":"Squad","channels":[]}}
            """
        let response = try decodeOrThrow(TeamCreateResponse.self, from: Data(json.utf8))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.team.teamId, "team-9")
        XCTAssertNil(response.polls)
        XCTAssertNil(response.elapsedMs)
    }

    func testErrorEnvelopeThrows() {
        let json = #"{"ok":false,"error":"team_create","detail":"nope"}"#
        XCTAssertThrowsError(
            try decodeOrThrow(TeamCreateResponse.self, from: Data(json.utf8)))
    }

    // MARK: - ViewModel create

    nonisolated private static func created(_ name: String = "Squad") -> TeamCreateResponse {
        TeamCreateResponse(
            ok: true,
            team: TeamItem(teamId: "team-9", name: name, channels: []),
            polls: 2, elapsedMs: 6100)
    }

    func testCreateAppendsTeamRow() async {
        let model = TeamsViewModel(
            fetcher: { TeamsTests.teamsJSON() },
            teamCreator: { name, _ in
                XCTAssertEqual(name, "Squad") // trimmed before core
                return Self.created(name)
            })
        await model.load()
        XCTAssertEqual(model.teams.count, 2)
        XCTAssertFalse(model.teamCreating)
        await model.createTeam(name: "  Squad ", description: "Ship it")
        XCTAssertEqual(model.teams.count, 3)
        XCTAssertEqual(model.teams.last?.name, "Squad")
        XCTAssertEqual(model.teams.last?.teamId, "team-9")
        XCTAssertNil(model.teamCreateError)
        XCTAssertFalse(model.teamCreating)
        XCTAssertEqual(model.teamsCreated, 1)
    }

    func testCreateBlankNameSkipsCore() async {
        let calls = LockedBox(0)
        let model = TeamsViewModel(
            fetcher: { TeamsTests.teamsJSON() },
            teamCreator: { _, _ in
                calls.mutate { $0 += 1 }
                throw CoreCallError.failed("must not call")
            })
        await model.load()
        await model.createTeam(name: "   ", description: nil)
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(model.teams.count, 2)
        XCTAssertNil(model.teamCreateError)
        XCTAssertEqual(model.teamsCreated, 0)
    }

    func testCreateFailureSurfacesError() async {
        let model = TeamsViewModel(
            fetcher: { TeamsTests.teamsJSON() },
            teamCreator: { _, _ in throw CoreCallError.failed("boom") })
        await model.load()
        await model.createTeam(name: "Squad", description: nil)
        XCTAssertEqual(model.teams.count, 2)
        XCTAssertEqual(model.teamCreateError, "boom")
        XCTAssertFalse(model.teamCreating)
        XCTAssertEqual(model.teamsCreated, 0)
    }

    // MARK: - Sheet states + gate

    func testSheetPhaseTransitions() {
        // editing -> creating -> created(name) | failed(message) -> editing.
        var phase = TeamCreatePhase.editing
        XCTAssertTrue(phase.isEditing)
        phase = .creating
        XCTAssertTrue(phase.isCreating)
        phase = .created("Squad")
        XCTAssertEqual(phase.createdName, "Squad")
        XCTAssertFalse(phase.isCreating)
        phase = .failed("boom")
        XCTAssertEqual(phase.failureMessage, "boom")
        phase = .editing
        XCTAssertTrue(phase.isEditing)
    }
}
