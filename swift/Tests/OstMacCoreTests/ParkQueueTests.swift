// ParkQueueTests.swift — PHONE-PLUS R1: pickup-code rules, queue/attendant
// parse, demo park/pickup round-trip, live-source licence gating. Sync API
// seam (no transport, zero live network).
import Foundation
import XCTest
@testable import OstMacCore

final class ParkQueueTests: XCTestCase {
    // MARK: pickup codes

    func testNormalizeKeepsDigitsOnly() {
        XCTAssertEqual(CallParkCode.normalize("#731"), "731")
        XCTAssertEqual(CallParkCode.normalize("45 28"), "4528")
    }

    func testNormalizeCapsAtEight() {
        XCTAssertEqual(CallParkCode.normalize("123456789").count, 8)
    }

    func testRetrievableNeedsTwoToEightDigits() {
        XCTAssertFalse(CallParkCode.isRetrievable(""))
        XCTAssertFalse(CallParkCode.isRetrievable("7"))
        XCTAssertFalse(CallParkCode.isRetrievable("##"))
        XCTAssertTrue(CallParkCode.isRetrievable("73"))
        XCTAssertTrue(CallParkCode.isRetrievable("#731"))
        XCTAssertTrue(CallParkCode.isRetrievable("45281234"))
        // Normalize truncates (DialPad precedent): 9 digits in, 8-digit code out.
        XCTAssertTrue(CallParkCode.isRetrievable("452812345"))
    }

    // MARK: parse

    func testParseQueueSkipsNameless() {
        let data = Data("{\"value\":[{\"id\":\"q1\",\"name\":\"Support\",\"agentCount\":4,\"routing\":\"Round robin\"},{\"id\":\"q2\"}]}".utf8)
        let list = CallQueue.parseList(data)
        XCTAssertEqual(list?.count, 1)
        XCTAssertEqual(list?.first?.agentCount, 4)
    }

    func testParseQueueRejectsGarbage() {
        XCTAssertNil(CallQueue.parseList(Data("nope".utf8)))
    }

    func testParseAttendantSkipsNameless() {
        let data = Data("{\"value\":[{\"id\":\"a1\",\"name\":\"Main\",\"greeting\":\"Hello\"},{\"name\":\"unnamed\"}]}".utf8)
        let list = AutoAttendant.parseList(data)
        XCTAssertEqual(list?.count, 1)
        XCTAssertEqual(list?.first?.greeting, "Hello")
    }

    func testParseAttendantRejectsGarbage() {
        XCTAssertNil(AutoAttendant.parseList(Data("nope".utf8)))
    }

    // MARK: demo round-trip

    func testDemoSeedsTwoParkedTwoQueuesTwoAttendants() throws {
        let api = DemoParkQueueAPI()
        XCTAssertEqual(try api.parked().count, 2)
        XCTAssertEqual(try api.queues().count, 2)
        XCTAssertEqual(try api.attendants().count, 2)
    }

    func testDemoParkThenPickup() throws {
        let api = DemoParkQueueAPI()
        let c = try api.park(name: "Priya Nair")
        XCTAssertTrue(CallParkCode.isRetrievable(c.code))
        XCTAssertEqual(try api.parked().count, 3)
        let back = try api.pickup(code: c.code)
        XCTAssertEqual(back.id, c.id)
        XCTAssertEqual(try api.parked().count, 2)
    }

    func testDemoPickupUnknownCodeFails() {
        let api = DemoParkQueueAPI()
        XCTAssertThrowsError(try api.pickup(code: "9999")) { e in
            XCTAssertTrue((e as? PhoneAPIError)?.message.contains("No parked call") == true)
        }
    }

    func testDemoPickupMalformedCodeFails() {
        let api = DemoParkQueueAPI()
        XCTAssertThrowsError(try api.pickup(code: "x")) { e in
            XCTAssertTrue((e as? PhoneAPIError)?.message.contains("pickup code") == true)
        }
    }

    func testDemoParkBlankNameFails() {
        let api = DemoParkQueueAPI()
        XCTAssertThrowsError(try api.park(name: "  "))
    }

    // MARK: licence gating

    /// Every live op throws the licence reason (R0: no Graph endpoint, no
    /// scope, no policy — nothing to attempt live).
    func testUnavailableThrowsLicenceReasons() {
        let api = UnavailableParkQueueAPI()
        XCTAssertThrowsError(try api.parked()) { e in
            XCTAssertEqual((e as? PhoneAPIError)?.message, PhoneStore.parkReason)
        }
        XCTAssertThrowsError(try api.park(name: "x")) { e in
            XCTAssertEqual((e as? PhoneAPIError)?.message, PhoneStore.parkReason)
        }
        XCTAssertThrowsError(try api.pickup(code: "731")) { e in
            XCTAssertEqual((e as? PhoneAPIError)?.message, PhoneStore.parkReason)
        }
        XCTAssertThrowsError(try api.queues()) { e in
            XCTAssertEqual((e as? PhoneAPIError)?.message, PhoneStore.queuesReason)
        }
        XCTAssertThrowsError(try api.attendants()) { e in
            XCTAssertEqual((e as? PhoneAPIError)?.message, PhoneStore.queuesReason)
        }
    }

    func testReasonsNameLicenceAndPolicy() {
        XCTAssertTrue(PhoneStore.parkReason.contains("call park policy"))
        XCTAssertTrue(PhoneStore.queuesReason.contains("Teams Phone licence"))
    }

    func testDemoStoreAdoptsPlus() async {
        let store = await MainActor.run { PhoneStore(demo: true) }
        let q = CallQueue(id: "q", name: "Support", agentCount: 1, routing: "Serial")
        await MainActor.run { store.adoptPlus(parked: [], queues: [q], attendants: []) }
        let count = await MainActor.run { store.queues.count }
        XCTAssertEqual(count, 1)
    }
}
