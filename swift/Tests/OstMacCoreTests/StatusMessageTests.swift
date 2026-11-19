// StatusMessageTests.swift — PRESENCE-PLUS R1: duration mapping,
// request bodies, guards, 403 capability mapping, store with stub
// transport (zero live network).
import Foundation
import XCTest
@testable import OstMacCore

/// Stub Graph transport: scripted replies, records every request.
final class StatusStubHTTP: CalendarHTTP, @unchecked Sendable {
    struct Call: Sendable { let method: String; let url: URL; let body: Data? }
    var calls: [Call] = []
    var status = 200
    var payload: Data = Data("{}".utf8)

    func send(_ method: String, url: URL, headers: [String: String], body: Data?) throws -> ReadHTTPResponse {
        calls.append(Call(method: method, url: url, body: body))
        return ReadHTTPResponse(status: status, data: payload)
    }
}

func statusMsgClient(_ stub: StatusStubHTTP) -> StatusMessageGraph {
    StatusMessageGraph(http: stub) { "token" }
}

func utcCalendar(mondayFirst: Bool = false) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    if mondayFirst { cal.firstWeekday = 2 }
    return cal
}

final class StatusMessageTests: XCTestCase {
    // MARK: duration

    func testAllDurationsHaveLabels() {
        XCTAssertEqual(StatusMessageDuration.allCases.count, 6)
        for d in StatusMessageDuration.allCases {
            XCTAssertFalse(d.label.isEmpty)
        }
    }

    func testHourDurationsOffset() throws {
        let now = Date(timeIntervalSince1970: 1_764_000_000)
        let cal = utcCalendar()
        XCTAssertEqual(try XCTUnwrap(StatusMessageDuration.oneHour.expiry(now: now, calendar: cal)).timeIntervalSince(now), 3600, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(StatusMessageDuration.fourHours.expiry(now: now, calendar: cal)).timeIntervalSince(now), 4 * 3600, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(StatusMessageDuration.eightHours.expiry(now: now, calendar: cal)).timeIntervalSince(now), 8 * 3600, accuracy: 1)
        XCTAssertNil(StatusMessageDuration.never.expiry(now: now, calendar: cal))
    }

    func testTodayExpiresAtMidnightUTC() throws {
        // Thursday 2026-11-19 → Friday 00:00 UTC.
        let now = Date(timeIntervalSince1970: 1_795_050_000)
        let end = try XCTUnwrap(StatusMessageDuration.today.expiry(now: now, calendar: utcCalendar()))
        let comps = utcCalendar().dateComponents([.year, .month, .day, .hour, .minute], from: end)
        XCTAssertEqual(comps.day, 20)
        XCTAssertEqual(comps.hour, 0)
        XCTAssertEqual(comps.minute, 0)
    }

    func testThisWeekExpiresAtWeekEnd() throws {
        // Thursday 2026-11-19, Monday-first week → Monday 2026-11-23 00:00 UTC.
        let now = Date(timeIntervalSince1970: 1_795_050_000)
        let end = try XCTUnwrap(StatusMessageDuration.thisWeek.expiry(now: now, calendar: utcCalendar(mondayFirst: true)))
        let comps = utcCalendar().dateComponents([.year, .month, .day, .hour], from: end)
        XCTAssertEqual(comps.day, 23)
        XCTAssertEqual(comps.hour, 0)
    }

    // MARK: guards

    func testBlankIsNotSettable() {
        XCTAssertFalse(StatusMessageDraft(message: "   ").isSettable)
        XCTAssertNil(StatusMessageDraft(message: "  ").body())
    }

    func testLengthCap() {
        XCTAssertTrue(StatusMessageDraft(message: String(repeating: "x", count: 280)).isSettable)
        XCTAssertFalse(StatusMessageDraft(message: String(repeating: "x", count: 281)).isSettable)
        XCTAssertNil(StatusMessageDraft(message: String(repeating: "x", count: 281)).body())
    }

    // MARK: bodies

    func testSetBodyShape() throws {
        let now = Date(timeIntervalSince1970: 1_764_000_000)
        let json = try XCTUnwrap(StatusMessageDraft(message: " heads down ", duration: .oneHour).body(now: now, calendar: utcCalendar()))
        let sm = try XCTUnwrap(json["statusMessage"] as? [String: Any])
        let msg = try XCTUnwrap(sm["message"] as? [String: Any])
        XCTAssertEqual(msg["content"] as? String, "heads down")
        XCTAssertEqual(msg["contentType"] as? String, "text")
        let exp = try XCTUnwrap(sm["expiryDateTime"] as? [String: String])
        XCTAssertEqual(exp["timeZone"], "UTC")
        XCTAssertTrue((exp["dateTime"] ?? "").hasPrefix("2025-"))
    }

    func testNeverOmitsExpiry() throws {
        let json = try XCTUnwrap(StatusMessageDraft(message: "on call", duration: .never).body())
        let sm = try XCTUnwrap(json["statusMessage"] as? [String: Any])
        XCTAssertNil(sm["expiryDateTime"])
    }

    func testClearBodyNullsMessage() throws {
        let data = try JSONSerialization.data(withJSONObject: StatusMessageDraft.clearBody(), options: [.sortedKeys])
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"statusMessage":{"message":null}}"#)
    }

    // MARK: client (stub transport)

    func testSetSendsPost() throws {
        let stub = StatusStubHTTP()
        try statusMsgClient(stub).set(StatusMessageDraft(message: "m", duration: .never))
        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertEqual(stub.calls[0].method, "POST")
        XCTAssertTrue(stub.calls[0].url.absoluteString.hasSuffix("/me/presence/setStatusMessage"))
        let body = try XCTUnwrap(stub.calls[0].body.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        let sm = try XCTUnwrap(body["statusMessage"] as? [String: Any])
        XCTAssertEqual((sm["message"] as? [String: Any])?["content"] as? String, "m")
    }

    func testSetRefusesBlankBeforeNetwork() {
        let stub = StatusStubHTTP()
        XCTAssertThrowsError(try statusMsgClient(stub).set(StatusMessageDraft(message: " "))) { e in
            XCTAssertTrue(String(describing: e).contains("blank"))
        }
        XCTAssertTrue(stub.calls.isEmpty)
    }

    func testClearSendsPost() throws {
        let stub = StatusStubHTTP()
        try statusMsgClient(stub).clear()
        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertEqual(stub.calls[0].method, "POST")
    }

    func testForbiddenSurfacesCapability() {
        let stub = StatusStubHTTP()
        stub.status = 403
        stub.payload = Data(#"{"error":{"code":"ErrorAccessDenied"}}"#.utf8)
        XCTAssertThrowsError(try statusMsgClient(stub).set(StatusMessageDraft(message: "m"))) { e in
            XCTAssertTrue(String(describing: e).contains("Presence.ReadWrite"))
        }
        XCTAssertThrowsError(try statusMsgClient(stub).clear()) { e in
            XCTAssertTrue(String(describing: e).contains("Presence.ReadWrite"))
        }
    }

    // MARK: store (stub transport)

    @MainActor
    func testFreshStoreIsInert() {
        let store = StatusMessageStore(client: statusMsgClient(StatusStubHTTP()))
        XCTAssertFalse(store.saving)
        XCTAssertNil(store.error)
        XCTAssertNil(store.liveDisabledReason)
        XCTAssertNil(store.savedMessage)
    }

    @MainActor
    func testStoreAdoptsWithoutNetwork() {
        let store = StatusMessageStore(client: statusMsgClient(StatusStubHTTP()))
        store.adopt("heads down")
        XCTAssertEqual(store.savedMessage, "heads down")
        XCTAssertNil(store.error)
    }

    @MainActor
    func testStoreSaveEchoesMessage() async {
        let stub = StatusStubHTTP()
        let store = StatusMessageStore(client: statusMsgClient(stub))
        store.save(StatusMessageDraft(message: "m", duration: .never))
        let deadline = Date().addingTimeInterval(5)
        while store.saving, Date() < deadline { await Task.yield() }
        XCTAssertEqual(store.savedMessage, "m")
        XCTAssertNil(store.error)
        XCTAssertEqual(stub.calls.count, 1)
    }

    @MainActor
    func testStoreSavePinsLiveDisabledOn403() async {
        let stub = StatusStubHTTP()
        stub.status = 403
        stub.payload = Data(#"{"error":{"code":"x"}}"#.utf8)
        let store = StatusMessageStore(client: statusMsgClient(stub))
        store.adopt("old")
        store.save(StatusMessageDraft(message: "new"))
        let deadline = Date().addingTimeInterval(5)
        while store.saving, Date() < deadline { await Task.yield() }
        XCTAssertEqual(store.savedMessage, "old")
        XCTAssertNil(store.error)
        XCTAssertTrue((store.liveDisabledReason ?? "").contains("Presence.ReadWrite"))
        store.noteEdited()
        XCTAssertNil(store.liveDisabledReason)
    }

    @MainActor
    func testStoreClearPinsLiveDisabledOn403() async {
        let stub = StatusStubHTTP()
        stub.status = 403
        let store = StatusMessageStore(client: statusMsgClient(stub))
        store.adopt("old")
        store.clear()
        let deadline = Date().addingTimeInterval(5)
        while store.saving, Date() < deadline { await Task.yield() }
        XCTAssertEqual(store.savedMessage, "old")
        XCTAssertNotNil(store.liveDisabledReason)
    }
}
