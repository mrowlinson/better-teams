// OutOfOfficeTests.swift — OOO-SET R1: setting parse, PATCH body,
// duration mapping, store with stub transport (zero live network).
import Foundation
import XCTest
@testable import OstMacCore

/// Stub Graph transport: scripted replies, records every request.
final class OOOStubHTTP: CalendarHTTP, @unchecked Sendable {
    struct Call: Sendable { let method: String; let url: URL; let body: Data? }
    var calls: [Call] = []
    var status = 200
    var payload: Data = Data("{}".utf8)

    func send(_ method: String, url: URL, headers: [String: String], body: Data?) throws -> ReadHTTPResponse {
        calls.append(Call(method: method, url: url, body: body))
        return ReadHTTPResponse(status: status, data: payload)
    }
}

func oooClient(_ stub: OOOStubHTTP) -> OutOfOfficeGraph {
    OutOfOfficeGraph(http: stub) { "token" }
}

func oooMailbox(_ oof: String) -> Data {
    Data("{\"automaticRepliesSetting\":{\(oof)}}".utf8)
}

final class OutOfOfficeTests: XCTestCase {
    // MARK: parse

    func testParseDisabledIsOff() {
        let s = OutOfOfficeSetting.parse(oooMailbox("\"status\":\"disabled\""))
        XCTAssertEqual(s, .off)
    }

    func testParseMissingBlockIsOff() {
        XCTAssertEqual(OutOfOfficeSetting.parse(Data("{\"timeZone\":\"x\"}".utf8)), .off)
    }

    func testParseGarbageIsNil() {
        XCTAssertNil(OutOfOfficeSetting.parse(Data("nope".utf8)))
    }

    func testParseUnknownStatusIsNil() {
        XCTAssertNil(OutOfOfficeSetting.parse(oooMailbox("\"status\":\"someday\"")))
    }

    func testParseAlwaysEnabledKeepsMessage() {
        let s = OutOfOfficeSetting.parse(oooMailbox("\"status\":\"alwaysEnabled\",\"internalReplyMessage\":\"gone\""))
        XCTAssertEqual(s?.enabled, true)
        XCTAssertEqual(s?.message, "gone")
        XCTAssertNil(s?.start)
    }

    func testParseScheduledKeepsWindow() throws {
        let s = OutOfOfficeSetting.parse(oooMailbox(
            "\"status\":\"scheduled\",\"internalReplyMessage\":\"m\"," +
                "\"scheduledStartDateTime\":{\"dateTime\":\"2026-11-18T09:00:00\",\"timeZone\":\"UTC\"}," +
                "\"scheduledEndDateTime\":{\"dateTime\":\"2026-11-19T09:00:00\",\"timeZone\":\"UTC\"}"))
        XCTAssertEqual(s?.enabled, true)
        XCTAssertNotNil(s?.start)
        XCTAssertNotNil(s?.end)
        let gap = try XCTUnwrap(s?.end?.timeIntervalSince(s?.start ?? .distantPast))
        XCTAssertEqual(gap, 86400, accuracy: 1)
    }

    // MARK: body

    func testOffBodyDisablesOnly() {
        let body = OutOfOfficeSetting.off.patchBody()
        XCTAssertEqual(Set(body.keys), ["automaticRepliesSetting"])
        let oof = body["automaticRepliesSetting"] as? [String: Any]
        XCTAssertEqual(oof?["status"] as? String, "disabled")
    }

    func testScheduledBodyShape() {
        let start = Date(timeIntervalSince1970: 1_764_000_000)
        let end = start.addingTimeInterval(3600)
        let body = OutOfOfficeSetting(enabled: true, start: start, end: end, message: "m").patchBody()
        let oof = body["automaticRepliesSetting"] as? [String: Any]
        XCTAssertEqual(oof?["status"] as? String, "scheduled")
        XCTAssertEqual((oof?["scheduledStartDateTime"] as? [String: String])?["timeZone"], "UTC")
        XCTAssertEqual(oof?["internalReplyMessage"] as? String, "m")
        XCTAssertEqual(oof?["externalReplyMessage"] as? String, "m")
        XCTAssertEqual(oof?["externalAudience"] as? String, "contactsOnly")
    }

    func testAlwaysOnBodyHasNoWindow() {
        let body = OutOfOfficeSetting(enabled: true, message: "m").patchBody()
        let oof = body["automaticRepliesSetting"] as? [String: Any]
        XCTAssertEqual(oof?["status"] as? String, "alwaysEnabled")
        XCTAssertNil(oof?["scheduledStartDateTime"])
    }

    // MARK: duration mapping

    func testUntilOffMeansAlwaysOn() {
        let s = OutOfOfficeSetting.scheduled(message: " m ", start: Date(), duration: .untilOff)
        XCTAssertTrue(s.enabled)
        XCTAssertNil(s.start)
        XCTAssertEqual(s.message, "m")
    }

    func testTimedDurationSchedulesWindow() throws {
        let start = Date()
        let s = OutOfOfficeSetting.scheduled(message: "m", start: start, duration: .oneHour)
        XCTAssertEqual(s.start, start)
        XCTAssertEqual(try XCTUnwrap(s.end?.timeIntervalSince(start)), 3600, accuracy: 1)
    }

    // MARK: summary

    func testSummaryOffAndUntilOff() {
        XCTAssertEqual(OutOfOfficeSetting.off.summary(), "Off")
        let now = Date()
        XCTAssertEqual(OutOfOfficeSetting(enabled: true, message: "m").summary(now: now),
                       "Out of Office · until off")
    }

    // MARK: client + store (stub transport)

    func testFetchParsesLiveShape() throws {
        let stub = OOOStubHTTP()
        stub.payload = oooMailbox("\"status\":\"disabled\"")
        let s = try oooClient(stub).fetch()
        XCTAssertEqual(s, .off)
        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertEqual(stub.calls[0].method, "GET")
    }

    func testSaveSendsPatch() throws {
        let stub = OOOStubHTTP()
        try oooClient(stub).save(.off)
        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertEqual(stub.calls[0].method, "PATCH")
    }

    func testForbiddenSurfacesCapability() {
        let stub = OOOStubHTTP()
        stub.status = 403
        stub.payload = Data("{\"error\":{\"code\":\"ErrorAccessDenied\"}}".utf8)
        XCTAssertThrowsError(try oooClient(stub).fetch()) { e in
            XCTAssertTrue(String(describing: e).contains("MailboxSettings.ReadWrite"))
        }
    }

    @MainActor
    func testFreshStoreIsInert() {
        // Demo safety: a fresh store fetches nothing and reports no
        // error until an explicit refresh/save (both user actions).
        let store = OutOfOfficeStore(client: oooClient(OOOStubHTTP()))
        XCTAssertEqual(store.setting, .off)
        XCTAssertFalse(store.loading)
        XCTAssertNil(store.error)
    }

    @MainActor
    func testStoreAdoptsWithoutNetwork() {
        let store = OutOfOfficeStore(client: oooClient(OOOStubHTTP()))
        let want = OutOfOfficeSetting(enabled: true, message: "m")
        store.adopt(want)
        XCTAssertEqual(store.setting, want)
        XCTAssertNil(store.error)
    }

    @MainActor
    func testStoreSaveKeepsPreviousOnFailure() async {
        let stub = OOOStubHTTP()
        stub.status = 403
        stub.payload = Data("{\"error\":{\"code\":\"x\"}}".utf8)
        let store = OutOfOfficeStore(client: oooClient(stub))
        store.adopt(.off)
        store.save(OutOfOfficeSetting(enabled: true, message: "m"))
        let deadline = Date().addingTimeInterval(5)
        while store.loading, Date() < deadline { await Task.yield() }
        XCTAssertEqual(store.setting, .off)
        XCTAssertNotNil(store.error)
    }
}
