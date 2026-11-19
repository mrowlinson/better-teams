// PhoneSettingsTests.swift — PHONEUI R1: dial-pad rules, forwarding
// validation, delegate parse, PhoneGraph request shapes (stub transport,
// zero live network), demo/live API seams.
import Foundation
import XCTest
@testable import OstMacCore

/// Stub Graph transport: scripted replies, records every request.
final class PhoneStubHTTP: CalendarHTTP, @unchecked Sendable {
    struct Call: Sendable { let method: String; let url: URL; let body: Data? }
    var calls: [Call] = []
    var status = 200
    var payload: Data = Data("{}".utf8)

    func send(_ method: String, url: URL, headers: [String: String], body: Data?) throws -> ReadHTTPResponse {
        calls.append(Call(method: method, url: url, body: body))
        return ReadHTTPResponse(status: status, data: payload)
    }
}

func phoneClient(_ stub: PhoneStubHTTP) -> PhoneGraph {
    PhoneGraph(http: stub) { "token" }
}

func phoneDelegatesPayload() -> Data {
    Data("{\"value\":[{\"id\":\"d1\",\"displayName\":\"Laura Bennett\",\"email\":\"laura@example.com\"},{\"id\":\"d2\",\"displayName\":\"James Carter\"}]}".utf8)
}

final class PhoneSettingsTests: XCTestCase {
    // MARK: dial pad

    func testNormalizeKeepsPlusLeadingOnly() {
        XCTAssertEqual(DialPad.normalize("+1 (555) 010-2030"), "+15550102030")
        XCTAssertEqual(DialPad.normalize("55+501"), "55501")
    }

    func testNormalizeCapsDigitsAtFifteen() {
        XCTAssertEqual(DialPad.normalize("+1234567890123456789").filter(\.isNumber).count, 15)
    }

    func testNormalizeKeepsStarHash() {
        XCTAssertEqual(DialPad.normalize("*67 555 0100"), "*675550100")
    }

    func testIsDialableNeedsThreeDigits() {
        XCTAssertFalse(DialPad.isDialable(""))
        XCTAssertFalse(DialPad.isDialable("**#"))
        XCTAssertFalse(DialPad.isDialable("55"))
        XCTAssertTrue(DialPad.isDialable("555"))
        XCTAssertTrue(DialPad.isDialable("+1 555 010 2030"))
    }

    // MARK: forwarding

    func testOffNeedsNoTarget() {
        XCTAssertNil(CallForwardingSettings.off.validate())
        XCTAssertNil(CallForwardingSettings(mode: .voicemail).validate())
        XCTAssertNil(CallForwardingSettings(mode: .myDelegates).validate())
    }

    func testSingleTargetNeedsDialableNumber() {
        XCTAssertNotNil(CallForwardingSettings(mode: .singleTarget, target: "").validate())
        XCTAssertNotNil(CallForwardingSettings(mode: .singleTarget, target: "55").validate())
        XCTAssertNil(CallForwardingSettings(mode: .singleTarget, target: "+15550102030").validate())
    }

    func testSummaryNamesTarget() {
        XCTAssertEqual(CallForwardingSettings(mode: .singleTarget, target: "+15550102030").summary(),
                       "Forward to +15550102030")
        XCTAssertEqual(CallForwardingSettings(mode: .myDelegates).summary(), "Ring my delegates")
    }

    // MARK: delegates parse

    func testParseListSkipsNameless() {
        let data = Data("{\"value\":[{\"id\":\"d1\",\"displayName\":\"Laura Bennett\"},{\"id\":\"\",\"displayName\":\"Nope\"},{\"id\":\"d3\"}]}".utf8)
        XCTAssertEqual(CallDelegate.parseList(data)?.map(\.id), ["d1"])
    }

    func testParseListGarbageIsNil() {
        XCTAssertNil(CallDelegate.parseList(Data("nope".utf8)))
    }

    // MARK: PhoneGraph request shapes

    func testFetchDelegatesIsBetaGet() throws {
        let stub = PhoneStubHTTP()
        stub.payload = phoneDelegatesPayload()
        let list = try phoneClient(stub).fetchDelegates()
        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertEqual(stub.calls[0].method, "GET")
        XCTAssertEqual(stub.calls[0].url.absoluteString,
                       "https://graph.microsoft.com/beta/me/communications/callSettings/delegates")
        XCTAssertNil(stub.calls[0].body)
        XCTAssertEqual(list.map(\.displayName), ["Laura Bennett", "James Carter"])
    }

    func testFetchDelegatesGarbageThrows() {
        let stub = PhoneStubHTTP()
        XCTAssertThrowsError(try phoneClient(stub).fetchDelegates())
    }

    func testAddDelegateIsBetaPost() throws {
        let stub = PhoneStubHTTP()
        stub.payload = Data("{\"id\":\"d9\",\"displayName\":\"sam\",\"email\":\"sam@example.com\"}".utf8)
        let d = try phoneClient(stub).addDelegate(email: "sam@example.com")
        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertEqual(stub.calls[0].method, "POST")
        XCTAssertTrue(stub.calls[0].url.absoluteString.hasSuffix("/delegates"))
        XCTAssertNotNil(stub.calls[0].body)
        XCTAssertEqual(d.id, "d9")
    }

    func testRemoveDelegateIsBetaDelete() throws {
        let stub = PhoneStubHTTP()
        try phoneClient(stub).removeDelegate(id: "d1")
        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertEqual(stub.calls[0].method, "DELETE")
        XCTAssertTrue(stub.calls[0].url.absoluteString.hasSuffix("/delegates/d1"))
        XCTAssertNil(stub.calls[0].body)
    }

    func testGraph403BecomesScopeMessage() {
        let stub = PhoneStubHTTP()
        stub.status = 403
        stub.payload = Data("{\"error\":{\"code\":\"Authorization_RequestDenied\"}}".utf8)
        XCTAssertThrowsError(try phoneClient(stub).fetchDelegates()) { e in
            XCTAssertTrue(String(describing: e).contains("CallDelegation.Read is not granted"))
        }
    }

    // MARK: API seams

    func testLiveAPIThrowsLicenceReason() {
        let api = UnavailablePhoneAPI()
        XCTAssertThrowsError(try api.voicemails()) { e in
            XCTAssertEqual((e as? PhoneAPIError)?.message, PhoneStore.liveReason)
        }
        XCTAssertThrowsError(try api.delegates())
        XCTAssertThrowsError(try api.forwarding())
    }

    func testDemoAPIRoundTrips() throws {
        let api = DemoPhoneAPI()
        XCTAssertEqual(try api.voicemails().count, 3)
        XCTAssertEqual(try api.delegates().count, 2)
        try api.markHeard(id: "demo-vm-1")
        XCTAssertTrue(try api.voicemails().first { $0.id == "demo-vm-1" }?.isRead == true)
        let fwd = CallForwardingSettings(mode: .singleTarget, target: "+15550102030")
        try api.saveForwarding(fwd)
        XCTAssertEqual(try api.forwarding(), fwd)
        let added = try api.addDelegate(email: "sam@example.com")
        XCTAssertEqual(try api.delegates().count, 3)
        try api.removeDelegate(id: added.id)
        XCTAssertEqual(try api.delegates().count, 2)
    }
}
