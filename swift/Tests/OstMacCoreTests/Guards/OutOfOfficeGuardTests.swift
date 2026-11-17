// OutOfOfficeGuardTests.swift — OOO write-surface pins (need owner OK
// to edit/delete/skip): the OOO client performs exactly one write shape
// (PATCH /me/mailboxSettings carrying ONLY automaticRepliesSetting) and
// reads via GET. A save must never overwrite any other mailbox setting.
import Foundation
import XCTest
@testable import OstMacCore

final class OutOfOfficeGuardTests: XCTestCase {
    func testSaveTouchesOnlyAutomaticRepliesSetting() throws {
        let stub = OOOStubHTTP()
        let start = Date(timeIntervalSince1970: 1_764_000_000)
        let setting = OutOfOfficeSetting(
            enabled: true, start: start, end: start.addingTimeInterval(3600), message: "away")
        try OutOfOfficeGraph(http: stub) { "token" }.save(setting)
        XCTAssertEqual(stub.calls.count, 1)
        let call = stub.calls[0]
        XCTAssertEqual(call.method, "PATCH")
        XCTAssertEqual(call.url.host, "graph.microsoft.com")
        XCTAssertEqual(call.url.path, "/v1.0/me/mailboxSettings")
        let raw = try XCTUnwrap(call.body)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["automaticRepliesSetting"])
    }

    func testFetchIsGetOnly() throws {
        let stub = OOOStubHTTP()
        stub.payload = Data("{\"automaticRepliesSetting\":{\"status\":\"disabled\"}}".utf8)
        _ = try OutOfOfficeGraph(http: stub) { "token" }.fetch()
        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertEqual(stub.calls[0].method, "GET")
        XCTAssertNil(stub.calls[0].body)
    }
}
