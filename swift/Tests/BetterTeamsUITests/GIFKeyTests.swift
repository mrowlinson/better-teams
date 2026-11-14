// GIFKeyTests.swift — P2#17: a GIF key saved after launch applies
// without relaunch (the empty first read must not stick).
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class GIFKeyTests: XCTestCase {
    func testLaterSavedKeyApplies() {
        let services = ConversationServices(demo: false)
        let store = KlipyMemoryKeyStore()
        services.keyStore = store
        XCTAssertFalse(services.hasGIFKey, "no key yet")
        KlipyClient.saveKey("  abc123  ", store: store)
        XCTAssertTrue(services.hasGIFKey, "later-saved key applies without relaunch")
    }

    func testSetKeyStaysCached() {
        let services = ConversationServices(demo: false)
        services.keyStore = KlipyMemoryKeyStore(key: "abc123")
        XCTAssertTrue(services.hasGIFKey)
        XCTAssertTrue(services.hasGIFKey, "cached while set")
    }

    func testDemoNeedsNoKey() {
        XCTAssertTrue(ConversationServices(demo: true).hasGIFKey)
    }
}
