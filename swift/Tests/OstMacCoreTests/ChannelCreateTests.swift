// ChannelCreateTests.swift — om-h3-create lane: wire decode, ViewModel create, sheet gate.
import XCTest

@testable import OstMacCore

@MainActor
final class ChannelCreateTests: XCTestCase {
    // MARK: - Wire decode

    func testDecodeCreateEnvelope() throws {
        let json = """
            {"ok":true,"channel":{"id":"19:new@thread.tacv2","name":"New room"}}
            """
        let response = try decodeOrThrow(ChannelCreateResponse.self, from: Data(json.utf8))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.channel.id, "19:new@thread.tacv2")
        XCTAssertEqual(response.channel.name, "New room")
    }

    func testErrorEnvelopeThrows() {
        let json = #"{"ok":false,"error":"channel_create","detail":"nope"}"#
        XCTAssertThrowsError(
            try decodeOrThrow(ChannelCreateResponse.self, from: Data(json.utf8)))
    }

    // MARK: - ViewModel create

    func testCreateAppendsChannelToTeam() async {
        let model = TeamsViewModel(
            fetcher: { TeamsTests.teamsJSON() },
            creator: { teamID, name, _ in
                XCTAssertEqual(teamID, "team-1")
                return ChannelCreateResponse(
                    ok: true,
                    channel: TeamChannel(channelId: "19:new@thread.tacv2", name: name))
            })
        await model.load()
        XCTAssertEqual(model.teams[0].channels.count, 2)
        await model.createChannel(teamID: "team-1", name: "New room", description: "Second room")
        XCTAssertEqual(model.teams[0].channels.count, 3)
        XCTAssertEqual(model.teams[0].channels.last?.name, "New room")
        XCTAssertNil(model.createError)
    }

    func testCreateBlankNameSkipsCore() async {
        let calls = LockedBox(0)
        let model = TeamsViewModel(
            fetcher: { TeamsTests.teamsJSON() },
            creator: { _, _, _ in
                calls.mutate { $0 += 1 }
                throw CoreCallError.failed("must not call")
            })
        await model.load()
        await model.createChannel(teamID: "team-1", name: "   ", description: nil)
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(model.teams[0].channels.count, 2)
        XCTAssertNil(model.createError)
    }

    func testCreateFailureSurfacesError() async {
        let model = TeamsViewModel(
            fetcher: { TeamsTests.teamsJSON() },
            creator: { _, _, _ in throw CoreCallError.failed("boom") })
        await model.load()
        await model.createChannel(teamID: "team-1", name: "New room", description: nil)
        XCTAssertEqual(model.teams[0].channels.count, 2)
        XCTAssertEqual(model.createError, "boom")
    }

    func testCreateUnknownTeamStillErrorsNil() async {
        // Server accepted, team gone locally (stale list): no crash, no row.
        let model = TeamsViewModel(
            fetcher: { TeamsTests.teamsJSON() },
            creator: { _, name, _ in
                ChannelCreateResponse(
                    ok: true,
                    channel: TeamChannel(channelId: "19:new@thread.tacv2", name: name))
            })
        await model.load()
        await model.createChannel(teamID: "team-gone", name: "New room", description: nil)
        XCTAssertEqual(model.teams[0].channels.count, 2)
        XCTAssertNil(model.createError)
    }

    // MARK: - Sheet gate

}
