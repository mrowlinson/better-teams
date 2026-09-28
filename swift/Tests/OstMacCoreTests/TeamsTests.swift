// TeamsTests.swift — om-teams lane: wire decode, ViewModel states, filter.
import XCTest

@testable import OstMacCore

@MainActor
final class TeamsTests: XCTestCase {
    // MARK: - Fixtures

    nonisolated static func teamsJSON() -> TeamsResponse {
        let json = """
            {"ok":true,"teams":[\
            {"id":"team-1","name":"Engineering","channels":[\
            {"id":"19:general@thread.tacv2","name":"General"},\
            {"id":"19:random@thread.tacv2","name":"Random"}]},\
            {"id":"team-2","name":"Lonely","channels":[]}]}
            """
        return try! decodeOrThrow(TeamsResponse.self, from: Data(json.utf8))
    }

    // MARK: - Wire decode

    func testDecodeWireShape() {
        let response = Self.teamsJSON()
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.teams.count, 2)
        XCTAssertEqual(response.teams[0].id, "team-1")
        XCTAssertEqual(response.teams[0].name, "Engineering")
        XCTAssertEqual(response.teams[0].channels.count, 2)
        XCTAssertEqual(response.teams[0].channels[0].id, "19:general@thread.tacv2")
        XCTAssertEqual(response.teams[0].channels[0].name, "General")
        XCTAssertTrue(response.teams[1].channels.isEmpty)
    }

    func testErrorEnvelopeThrows() {
        let json = #"{"ok":false,"error":"teams","detail":"nope"}"#
        XCTAssertThrowsError(
            try decodeOrThrow(TeamsResponse.self, from: Data(json.utf8)))
    }

    // MARK: - Channel detail (om-h1-listdetail)

    func testDecodeChannelDetail() {
        let json = """
            {"ok":true,"teams":[\
            {"id":"team-1","name":"Engineering","channels":[\
            {"id":"19:general@thread.tacv2","name":"General",\
            "description":"Team-wide announcements",\
            "membership_type":"standard",\
            "web_url":"https://teams.cloud.microsoft/l/channel/abc"}]}]}
            """
        let response = try! decodeOrThrow(TeamsResponse.self, from: Data(json.utf8))
        let ch = response.teams[0].channels[0]
        XCTAssertEqual(ch.description, "Team-wide announcements")
        XCTAssertEqual(ch.membershipType, "standard")
        XCTAssertEqual(ch.webUrl, "https://teams.cloud.microsoft/l/channel/abc")
    }

    func testDecodeLegacyChannelWithoutDetail() {
        // Pre-H1 wire shape (id+name only) still decodes; detail is nil.
        let response = Self.teamsJSON()
        let ch = response.teams[0].channels[0]
        XCTAssertNil(ch.description)
        XCTAssertNil(ch.membershipType)
        XCTAssertNil(ch.webUrl)
    }

    // MARK: - ViewModel states

    func testLoadPopulatesTeams() async {
        let response = Self.teamsJSON()
        let model = TeamsViewModel(fetcher: { response })
        XCTAssertEqual(model.state, .loading)
        await model.load()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.teams.count, 2)
        XCTAssertEqual(model.teams[0].channels.count, 2)
    }

    func testLoadEmpty() async {
        let model = TeamsViewModel(fetcher: {
            TeamsResponse(ok: true, teams: [])
        })
        await model.load()
        XCTAssertEqual(model.state, .empty)
        XCTAssertTrue(model.teams.isEmpty)
    }

    func testLoadError() async {
        let model = TeamsViewModel(fetcher: { () -> TeamsResponse in
            throw CoreCallError.failed("boom")
        })
        await model.load()
        XCTAssertEqual(model.state, .error("boom"))
    }

    // MARK: - Filter

    func testFilterEmptyQueryReturnsAll() {
        let teams = Self.teamsJSON().teams
        XCTAssertEqual(TeamsViewModel.filtered(teams, query: "  ").count, 2)
    }

    func testFilterTeamNameKeepsWholeTeam() {
        let teams = Self.teamsJSON().teams
        let out = TeamsViewModel.filtered(teams, query: "engINeer")
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].channels.count, 2) // whole team, unfiltered
    }

    func testFilterChannelNameNarrowsChannels() {
        let teams = Self.teamsJSON().teams
        let out = TeamsViewModel.filtered(teams, query: "random")
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].channels.count, 1)
        XCTAssertEqual(out[0].channels[0].name, "Random")
    }

    func testFilterNoMatch() {
        let teams = Self.teamsJSON().teams
        XCTAssertTrue(TeamsViewModel.filtered(teams, query: "zzz").isEmpty)
    }

    // MARK: - Demo data

    func testDemoTeamsResponse() {
        let response = DemoData.teamsResponse()
        XCTAssertTrue(response.ok)
        XCTAssertFalse(response.teams.isEmpty)
        XCTAssertTrue(response.teams.allSatisfy { !$0.channels.isEmpty })
    }

    func testDemoChannelNameAndMessages() {
        XCTAssertEqual(
            DemoData.name(for: "demo-chan-general"), "Engineering > #General")
        XCTAssertFalse(DemoData.messages(for: "demo-chan-general").isEmpty)
        // Any demo-chan- id shares the canned thread; unknown ids stay empty.
        XCTAssertFalse(DemoData.messages(for: "demo-chan-nope").isEmpty)
        XCTAssertTrue(DemoData.messages(for: "nope").isEmpty)
    }
}
