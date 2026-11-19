// WebinarConfigTests.swift — WEBINARS lane: configure (PATCH) +
// registration list guards + request shapes. Stub transport only;
// zero live network.
import XCTest

@testable import OstMacCore

@MainActor
final class WebinarConfigTests: XCTestCase {
    func testAudienceRawValuesMatchGraph() {
        XCTAssertEqual(WebinarAudience.organization.rawValue, "organization")
        XCTAssertEqual(WebinarAudience.everyone.rawValue, "everyone")
    }

    func testPatchBodyOmitsUnsetFields() {
        let p = WebinarPatch(title: "Launch", description: nil, audience: nil)
        XCTAssertFalse(p.isEmpty)
        XCTAssertEqual(p.body["displayName"] as? String, "Launch")
        XCTAssertNil(p.body["description"])
        XCTAssertNil(p.body["audience"])
        XCTAssertTrue(WebinarPatch(title: nil, description: nil, audience: nil).isEmpty)
    }

    func testPatchBodyCarriesAllFields() {
        let p = WebinarPatch(title: "Q4 Review", description: "Quarterly review", audience: .everyone)
        XCTAssertEqual(p.body["displayName"] as? String, "Q4 Review")
        XCTAssertEqual(p.body["description"] as? String, "Quarterly review")
        XCTAssertEqual(p.body["audience"] as? String, "everyone")
    }

    func testGuards() {
        XCTAssertEqual(WebinarPatch.error(title: "  ", start: Date(), end: Date().addingTimeInterval(60)),
                       "Title is required")
        XCTAssertEqual(WebinarPatch.error(title: "T", start: Date(), end: Date()),
                       "End must be after start")
        XCTAssertEqual(WebinarPatch.error(title: "T", start: Date(), end: Date().addingTimeInterval(60),
                                          description: String(repeating: "x", count: 2001)),
                       "Description is too long")
        XCTAssertNil(WebinarPatch.error(title: "T", start: Date(), end: Date().addingTimeInterval(60)))
    }

    func testRegistrationPageParsesRowsAndDropsBlankEmails() throws {
        let json = """
            {"value":[
             {"id":"R1","firstName":"Amy","lastName":"Wu","email":"amy@contoso.example","status":"registered",
              "registrationDateTime":"2026-10-01T12:00:00Z"},
             {"id":"R2","firstName":"Bo","lastName":"Li","email":"","status":"waitlisted",
              "registrationDateTime":"2026-10-02T12:00:00Z"},
             {"id":"R3","firstName":"Cy","lastName":"Dee","email":"cy@contoso.example","status":"cancelled",
              "registrationDateTime":"2026-10-03T12:00:00Z"}]}
            """
        let page = try WebinarRegistrations.page(Data(json.utf8))
        XCTAssertEqual(page.rows.count, 2, "blank-email row dropped")
        XCTAssertEqual(page.rows[0].displayName, "Amy Wu")
        XCTAssertEqual(page.rows[0].email, "amy@contoso.example")
        XCTAssertEqual(page.rows[0].status, "registered")
        XCTAssertEqual(page.rows[1].status, "cancelled")
        XCTAssertNil(page.next)
    }

    func testRegistrationPageKeepsNextLink() throws {
        let json = """
            {"value":[],"@odata.nextLink":"https://graph.microsoft.com/v1.0/solutions/virtualEvents/webinars/W1/registrations?$skip=100"}
            """
        let page = try WebinarRegistrations.page(Data(json.utf8))
        XCTAssertNotNil(page.next)
    }

    func testUpdateAndListRequestShapes() throws {
        let http = StubCalendarHTTP([
            (200, "{}"),
            (200, #"{"value":[{"id":"R1","firstName":"Amy","lastName":"Wu","email":"amy@contoso.example","status":"registered","registrationDateTime":"2026-10-01T12:00:00Z"}]}"#),
        ])
        let g = CalendarEventsTests.graph(http)
        try g.updateWebinar(id: "W1", patch: WebinarPatch(title: "New Title", description: nil, audience: .everyone))
        let regs = try g.listRegistrations(webinarID: "W1")
        let s = http.sent
        XCTAssertEqual(s[0].method, "PATCH")
        XCTAssertTrue(s[0].url.path.hasSuffix("/solutions/virtualEvents/webinars/W1"))
        XCTAssertEqual(s[0].body?["displayName"] as? String, "New Title")
        XCTAssertEqual(s[0].body?["audience"] as? String, "everyone")
        XCTAssertEqual(s[1].method, "GET")
        XCTAssertTrue(s[1].url.path.hasSuffix("/solutions/virtualEvents/webinars/W1/registrations"))
        XCTAssertEqual(regs.map(\.email), ["amy@contoso.example"])
    }

    func testSaveWebinarGuardSetsError() async {
        let store = CalendarWeekStore(
            weekFetcher: { _ in CalWeekResponse(ok: true, weekStart: 0, days: 7, meetings: []) },
            runners: CalendarRunners(
                detail: { _ in throw CalendarRunners.unsupported() },
                respond: { _, _ in throw CalendarRunners.unsupported() },
                update: { _, _ in throw CalendarRunners.unsupported() },
                meetNow: { _ in throw CalendarRunners.unsupported() }))
        let ok = await store.saveWebinar(id: "W1", patch: WebinarPatch(title: "  ", description: nil, audience: nil))
        XCTAssertFalse(ok)
        XCTAssertEqual(store.webinarSaveError, "Title is required")
    }
}
