// CalendarMeetingOptionsTests.swift — CAL-SCOPE R0 pins: middle-tier
// meeting-options URL shape, join-URL coordinates, GET parse, lobby /
// presenter enums, POST body, and stub-transport fetch/set (auth header
// keys asserted, never values). Stub transport only; zero live network.
import XCTest

@testable import OstMacCore

@MainActor
final class CalendarMeetingOptionsTests: XCTestCase {
    static let coords = MeetingCoordinates(
        tenantID: "11111111-2222-3333-4444-555555555555",
        organizerID: "66666666-7777-8888-9999-000000000000",
        threadID: "19:meeting_abcdef@thread.v2", messageID: "0")

    static let replyJSON = """
        {"options":[
         {"name":"AutoAdmittedUsers","type":"List","category":"Lobby","currentValue":"Everyone"},
         {"name":"PresenterOption","type":"List","category":"Presenters","currentValue":"EveryoneInCompany"},
         {"name":"CopilotModeOption","type":"List","category":"Copilot","currentValue":"Enabled"},
         {"name":"SomeBoolean","type":"Boolean","category":"X","currentValue":true}]}
        """

    static func slots() -> TokenSlots {
        TokenSlots(accessToken: StoredTokenValue(token: "aad"),
                   skypeToken: StoredTokenValue(token: "skype"))
    }

    func testURLShape() {
        let url = MeetingOptionsReader.url(middleTier: "https://teams.microsoft.com/api/mt/amer",
                                           coords: Self.coords)
        XCTAssertEqual(url?.absoluteString, "https://teams.microsoft.com/api/mt/amer"
            + "/beta/meetings/v1/options/11111111-2222-3333-4444-555555555555"
            + "/66666666-7777-8888-9999-000000000000/19:meeting_abcdef@thread.v2/0")
    }

    func testURLDefaultsBaseWhenMissing() {
        let url = MeetingOptionsReader.url(middleTier: nil, coords: Self.coords)
        XCTAssertTrue(url?.absoluteString.hasPrefix(MeetingOptionsReader.defaultMiddleTier) == true)
    }

    func testCoordinatesFromJoinURL() {
        let join = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abcdef%40thread.v2/0"
            + "?context=%7b%22Tid%22%3a%2211111111-2222-3333-4444-555555555555%22%2c"
            + "%22Oid%22%3a%2266666666-7777-8888-9999-000000000000%22%7d"
        XCTAssertEqual(MeetingCoordinates.fromJoinURL(join), Self.coords)
    }

    func testCoordinatesRejectsNonMeetingURL() {
        XCTAssertNil(MeetingCoordinates.fromJoinURL("https://teams.microsoft.com/l/meetup-join/"))
        XCTAssertNil(MeetingCoordinates.fromJoinURL("https://example.com/x"))
        XCTAssertNil(MeetingCoordinates.fromJoinURL("https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0"))
    }

    func testParseRowsAndEnums() {
        let rows = MeetingOptionsReader.parse(status: 200, data: Data(Self.replyJSON.utf8))
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(MeetingOptionsReader.lobby(of: rows), .everyone)
        XCTAssertEqual(MeetingOptionsReader.presenters(of: rows), .company)
    }

    func testParseRejectsUnknownShapes() {
        XCTAssertTrue(MeetingOptionsReader.parse(status: 200, data: Data("{}".utf8)).isEmpty)
        XCTAssertTrue(MeetingOptionsReader.parse(status: 403, data: Data(Self.replyJSON.utf8)).isEmpty)
        XCTAssertTrue(MeetingOptionsReader.parse(status: 200, data: Data("nope".utf8)).isEmpty)
    }

    func testUnknownEnumValueIsNil() {
        let rows = [MeetingOptionRow(name: "AutoAdmittedUsersOption", type: "List", currentValue: "FutureValue")]
        XCTAssertNil(MeetingOptionsReader.lobby(of: rows))
        XCTAssertNil(MeetingOptionsReader.presenters(of: rows))
    }

    func testPostBodyKeys() throws {
        let data = try XCTUnwrap(MeetingOptionsReader.body(lobby: .invited, presenters: .organizerOnly))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let opts = try XCTUnwrap(obj["options"] as? [[String: Any]])
        XCTAssertEqual(opts.count, 2)
        let byName = Dictionary(uniqueKeysWithValues: opts.map { ($0["name"] as? String ?? "", $0) })
        XCTAssertEqual(byName["AutoAdmittedUsersOption"]?["currentValue"] as? String, "InvitedUsers")
        XCTAssertEqual(byName["WhoCanPresentOption"]?["currentValue"] as? String, "OrganizerOnly")
    }

    func testFetchRawSendsMTAuth() {
        let http = StubCalendarHTTP([(200, Self.replyJSON)])
        let (status, rows) = MeetingOptionsReader.fetchRaw(
            slots: Self.slots(), now: 0, coords: Self.coords, http: http)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(rows.count, 4)
        let sent = try? XCTUnwrap(http.sent.first)
        XCTAssertEqual(sent?.method, "GET")
        XCTAssertTrue(sent?.url.absoluteString.contains("/beta/meetings/v1/options/") == true)
        XCTAssertFalse(sent?.headers["Authorization"]?.isEmpty == true)
        XCTAssertFalse(sent?.headers["X-Skypetoken"]?.isEmpty == true)
    }

    func testSetRawPostsOptions() {
        let http = StubCalendarHTTP([(200, "{}")])
        let status = MeetingOptionsReader.setRaw(
            slots: Self.slots(), now: 0, coords: Self.coords,
            lobby: .organizerOnly, presenters: .everyone, http: http)
        XCTAssertEqual(status, 200)
        let sent = http.sent.first
        XCTAssertEqual(sent?.method, "POST")
        let names = (sent?.body?["options"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names?.sorted(), ["AutoAdmittedUsersOption", "WhoCanPresentOption"])
    }

    func testParseKeepsCategory() {
        let rows = MeetingOptionsReader.parse(status: 200, data: Data(Self.replyJSON.utf8))
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.first { $0.name == "AutoAdmittedUsers" }?.category, "Lobby")
        XCTAssertEqual(rows.first { $0.name == "PresenterOption" }?.category, "Presenters")
    }

    func testPostBodySubsetKeepsTwoRows() throws {
        let rows = MeetingOptionsReader.parse(status: 200, data: Data(Self.replyJSON.utf8))
        let data = try XCTUnwrap(MeetingOptionsReader.bodySubset(
            rows: rows, lobby: .company, presenters: .specific))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let opts = try XCTUnwrap(obj["options"] as? [[String: Any]])
        XCTAssertEqual(opts.count, 2)
        let byName = Dictionary(uniqueKeysWithValues: opts.map { ($0["name"] as? String ?? "", $0) })
        XCTAssertEqual(byName["AutoAdmittedUsers"]?["currentValue"] as? String, "EveryoneInCompany")
        XCTAssertEqual(byName["PresenterOption"]?["currentValue"] as? String, "SpecifiedPeople")
        XCTAssertNil(MeetingOptionsReader.bodySubset(rows: [], lobby: .company, presenters: .specific))
    }

    func testPostBodyKeepsReplyTypes() throws {
        let rows = MeetingOptionsReader.parse(status: 200, data: Data(Self.replyJSON.utf8))
        let data = try XCTUnwrap(MeetingOptionsReader.body(
            rows: rows, lobby: .company, presenters: .specific))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let opts = try XCTUnwrap(obj["options"] as? [[String: Any]])
        XCTAssertEqual(opts.count, 4)
        let byName = Dictionary(uniqueKeysWithValues: opts.map { ($0["name"] as? String ?? "", $0) })
        XCTAssertEqual(byName["AutoAdmittedUsers"]?["currentValue"] as? String, "EveryoneInCompany")
        XCTAssertEqual(byName["PresenterOption"]?["type"] as? String, "List")
        XCTAssertEqual(byName["CopilotModeOption"]?["currentValue"] as? String, "Enabled")
    }

    func testCandidateMatchingByModelKeyAndCase() {
        let rows = [
            MeetingOptionRow(name: "autoAdmittedUsers", type: "List", currentValue: "InvitedUsers"),
            MeetingOptionRow(name: "presenterOption", type: "List", currentValue: "OrganizerOnly"),
        ]
        XCTAssertEqual(MeetingOptionsReader.lobby(of: rows), .invited)
        XCTAssertEqual(MeetingOptionsReader.presenters(of: rows), .organizerOnly)
        XCTAssertEqual(MeetingOptionsReader.lobbyRow(in: rows)?.name, "autoAdmittedUsers")
        let upper = [MeetingOptionRow(name: "AUTOADMITTEDUSERSOPTION", type: "List", currentValue: "Everyone")]
        XCTAssertEqual(MeetingOptionsReader.lobby(of: upper), .everyone)
    }

    func testSelectionRefusals() {
        XCTAssertThrowsError(try MeetingOptionsReader.selection(status: 403, rows: []))
        XCTAssertThrowsError(try MeetingOptionsReader.selection(status: 200, rows: []))
        XCTAssertThrowsError(try MeetingOptionsReader.selection(status: 404, rows: []))
    }

    func testLabelsCoverEveryCase() {
        for v in MeetingLobbyBypass.allCases {
            XCTAssertFalse(MeetingLobbyLabel.label(v).isEmpty)
        }
        for v in MeetingPresenters.allCases {
            XCTAssertFalse(MeetingLobbyLabel.label(v).isEmpty)
        }
        XCTAssertEqual(Set(MeetingLobbyBypass.allCases.map(MeetingLobbyLabel.label).map(\.self)).count,
                       MeetingLobbyBypass.allCases.count, "lobby labels distinct")
        XCTAssertEqual(Set(MeetingPresenters.allCases.map(MeetingLobbyLabel.label).map(\.self)).count,
                       MeetingPresenters.allCases.count, "presenter labels distinct")
    }

    func testNoTokensSendsNothing() {
        let http = StubCalendarHTTP([(200, Self.replyJSON)])
        let (status, rows) = MeetingOptionsReader.fetchRaw(
            slots: TokenSlots(), now: 0, coords: Self.coords, http: http)
        XCTAssertEqual(status, 0)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(http.sent.isEmpty)
    }
}
