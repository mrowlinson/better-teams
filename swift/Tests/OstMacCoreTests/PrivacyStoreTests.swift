// PrivacyStoreTests.swift — C6 SERVER-STATE (SET-10 remainder):
// standalone receipt/presence toggles, no ghost master needed.
import XCTest

@testable import OstMacCore

private final class PrivacySendBox: @unchecked Sendable {
    var calls: [(String, String)] = []
}

private final class PrivacySetBox: @unchecked Sendable {
    var calls: [String] = []
}

@MainActor
final class PrivacyStoreTests: XCTestCase {
    private func privacyDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-privacy-\(UUID().uuidString)") ?? .standard
    }

    func testDefaultsAreBothOn() {
        let p = PrivacyStore(defaults: privacyDefaults())
        XCTAssertTrue(p.sendReadReceipts)
        XCTAssertTrue(p.broadcastPresence)
    }

    func testTogglesPersistAcrossInstances() {
        let d = privacyDefaults()
        let p = PrivacyStore(defaults: d)
        p.sendReadReceipts = false
        p.broadcastPresence = false
        let reopened = PrivacyStore(defaults: d)
        XCTAssertFalse(reopened.sendReadReceipts)
        XCTAssertFalse(reopened.broadcastPresence)
    }

    func testReceiptsOffSendsNothingAndStaysRetryable() async {
        let box = PrivacySendBox()
        let store = ReceiptStore(
            sender: { chat, mid in box.calls.append((chat, mid)) },
            fetcher: { _ in [] })
        let p = PrivacyStore(defaults: privacyDefaults())
        p.sendReadReceipts = false
        store.privacy = p
        store.sendReadPosition(chatID: "c1", latestID: "m1")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(box.calls.count, 0)
        XCTAssertNil(store.sent["c1"], "privacy-off sends stay retryable")
        XCTAssertNil(store.lastError, "a gated send is not a failure")
    }

    func testReceiptsOnSendsNormally() async {
        let box = PrivacySendBox()
        let store = ReceiptStore(
            sender: { chat, mid in box.calls.append((chat, mid)) },
            fetcher: { _ in [] })
        store.privacy = PrivacyStore(defaults: privacyDefaults())
        store.sendReadPosition(chatID: "c1", latestID: "m1")
        var tries = 0
        while store.sent["c1"] != "m1", tries < 50 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            tries += 1
        }
        XCTAssertEqual(box.calls.count, 1)
    }

    func testPresenceOffHoldsManualSets() async {
        let box = PrivacySetBox()
        let store = PresenceStore(setFetcher: { want in
            box.calls.append(want)
            return PresenceResponse(ok: true, availability: "Busy", activity: "Busy")
        })
        let p = PrivacyStore(defaults: privacyDefaults())
        p.broadcastPresence = false
        store.privacy = p
        var hookFired = false
        store.manualSetHook = { hookFired = true }
        store.set(status: .busy)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(box.calls.count, 0)
        XCTAssertNil(store.own)
        XCTAssertFalse(store.setting)
        XCTAssertFalse(hookFired)
    }

    func testPresenceOnSetsNormally() async {
        let box = PrivacySetBox()
        let store = PresenceStore(setFetcher: { want in
            box.calls.append(want)
            return PresenceResponse(ok: true, availability: "Busy", activity: "Busy")
        })
        store.privacy = PrivacyStore(defaults: privacyDefaults())
        store.set(status: .busy)
        var tries = 0
        while box.calls.isEmpty, tries < 50 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            tries += 1
        }
        XCTAssertEqual(box.calls, ["busy"])
    }
}
