// TeamJoinTests.swift — om-h2-join lane: join wire decode + ViewModel join action.
import XCTest

@testable import OstMacCore

@MainActor
final class TeamJoinTests: XCTestCase {
    func testDecodeJoinResponse() {
        let json = #"{"ok":true,"team_id":"team-1"}"#
        let resp = try! decodeOrThrow(TeamJoinResponse.self, from: Data(json.utf8))
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.team_id, "team-1")
    }

    func testJoinSuccess() async {
        let model = TeamsViewModel(
            fetcher: { TeamsResponse(ok: true, teams: []) },
            joiner: { TeamJoinResponse(ok: true, team_id: $0) })
        await model.join(teamID: "team-1")
        XCTAssertEqual(model.joinsCompleted, 1)
        XCTAssertEqual(model.joinFailures, 0)
        XCTAssertNil(model.joinError)
        XCTAssertTrue(model.joiningIDs.isEmpty)
    }

    func testJoinBlankIsNoop() async {
        let model = TeamsViewModel(
            fetcher: { TeamsResponse(ok: true, teams: []) },
            joiner: { _ in
                XCTFail("joiner must not run for blank id")
                return TeamJoinResponse(ok: true, team_id: "")
            })
        await model.join(teamID: "   ")
        XCTAssertEqual(model.joinsCompleted, 0)
        XCTAssertEqual(model.joinFailures, 0)
        XCTAssertNil(model.joinError)
    }

    func testJoinFailure() async {
        let model = TeamsViewModel(
            fetcher: { TeamsResponse(ok: true, teams: []) },
            joiner: { _ in throw CoreCallError.failed("boom") })
        await model.join(teamID: "team-1")
        XCTAssertEqual(model.joinsCompleted, 0)
        XCTAssertEqual(model.joinFailures, 1)
        XCTAssertEqual(model.joinError, "boom")
        XCTAssertTrue(model.joiningIDs.isEmpty)
    }
}
