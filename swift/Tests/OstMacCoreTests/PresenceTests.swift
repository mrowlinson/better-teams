// PresenceTests.swift — om-presence lane: envelopes, status table,
// store fetch/set/cache with mock fetchers (no core, no network).
import XCTest

@testable import OstMacCore

@MainActor
final class PresenceTests: XCTestCase {
    func testOwnEnvelopeDecodes() throws {
        let data = """
        {"ok":true,"availability":"Busy","activity":"InACall"}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(PresenceResponse.self, from: data)
        XCTAssertEqual(p.availability, "Busy")
        XCTAssertEqual(p.activity, "InACall")
    }

    func testUserEnvelopeDecodes() throws {
        let data = """
        {"ok":true,"id":"gid-7","availability":"Away","activity":"Away"}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(UserPresenceResponse.self, from: data)
        XCTAssertEqual(p.id, "gid-7")
        XCTAssertEqual(p.availability, "Away")
    }

    func testStatusTableRoundtrip() {
        // Teams set values → server availability → picker row (D1).
        let pairs: [(PresenceStatus, String)] = [
            (.available, "Available"), (.busy, "Busy"), (.dnd, "DoNotDisturb"),
            (.brb, "BeRightBack"), (.away, "Away"), (.offline, "Offline"),
        ]
        for (status, avail) in pairs {
            XCTAssertEqual(status.availability, avail)
            XCTAssertEqual(PresenceStatus.from(availability: avail), status)
        }
        XCTAssertEqual(PresenceStatus.dnd.rawValue, "dnd")
        XCTAssertEqual(PresenceStatus.brb.rawValue, "brb")
        XCTAssertNil(PresenceStatus.from(availability: "PresenceUnknown"))
        XCTAssertNil(PresenceStatus.from(availability: "FutureValue"))
    }

    func testPickerTitlesMatchTeams() {
        // Exact-copy pins (D1/D2): picker order + Teams client strings.
        XCTAssertEqual(
            PresenceStatus.allCases.map(\.title),
            ["Available", "Busy", "Do not disturb", "Be right back", "Appear away", "Appear offline"])
        XCTAssertEqual(PresenceStatus.brb.title, "Be right back")
        XCTAssertEqual(PresenceStatus.away.title, "Appear away")
        // Server echo "Away" still selects the "Appear away" row (D2).
        XCTAssertEqual(PresenceStatus.from(availability: "Away"), .away)
    }

    func testOnlineRuleMatchesOstTui() {
        // ost TUI: online = availability ∉ {Offline, PresenceUnknown}.
        for avail in ["Available", "Busy", "DoNotDisturb", "Away", "BeRightBack", "Whatever"] {
            XCTAssertTrue(PresenceFormat.isOnline(availability: avail), avail)
        }
        XCTAssertFalse(PresenceFormat.isOnline(availability: "Offline"))
        XCTAssertFalse(PresenceFormat.isOnline(availability: "PresenceUnknown"))
    }

    func testLabelCollapsesEqualPair() {
        XCTAssertEqual(
            PresenceFormat.label(availability: "Available", activity: "Available"), "Available")
        XCTAssertEqual(
            PresenceFormat.label(availability: "Busy", activity: "Busy"), "Busy")
        XCTAssertEqual(
            PresenceFormat.label(availability: "DoNotDisturb", activity: "DoNotDisturb"),
            "Do not disturb")
        XCTAssertEqual(PresenceFormat.label(availability: "Away", activity: ""), "Away")
    }

    func testLabelFriendlyPerActivity() {
        // (availability, activity) → Teams display text (D6, presence-admins).
        let cases: [(String, String, String)] = [
            ("Available", "Available", "Available"),
            ("Busy", "Busy", "Busy"),
            ("DoNotDisturb", "DoNotDisturb", "Do not disturb"),
            ("BeRightBack", "BeRightBack", "Be right back"),
            ("Away", "Away", "Away"),
            ("Offline", "OffWork", "Offline"),
            ("Busy", "InACall", "In a call"),
            ("Busy", "InAMeeting", "In a meeting"),
            ("Busy", "InAConferenceCall", "In a conference call"),
            ("DoNotDisturb", "Presenting", "Presenting"),
            ("DoNotDisturb", "Focusing", "Focusing"),
            ("Available", "OutOfOffice", "Available, Out of Office"),
            ("Busy", "OutOfOffice", "Out of Office"),
            ("Available", "", "Available"),
            ("PresenceUnknown", "PresenceUnknown", "Status unknown"),
            ("Busy", "SomeFutureActivity", "Some future activity"),
        ]
        for (avail, act, want) in cases {
            XCTAssertEqual(
                PresenceFormat.label(availability: avail, activity: act), want, "\(avail)/\(act)")
        }
        // No raw enum fragment leaks in any status line (D6 accept).
        let raw = [
            "InACall", "InAMeeting", "InAConferenceCall", "DoNotDisturb", "BeRightBack",
            "OutOfOffice", "OffWork", "PresenceUnknown", "UrgentInterruptionsOnly",
        ]
        for (avail, act, _) in cases {
            let line = PresenceFormat.label(availability: avail, activity: act)
            for token in raw {
                XCTAssertFalse(line.contains(token), "\(avail)/\(act) leaks \(token): \(line)")
            }
        }
    }

    func testUnknownLabelMatchesTeams() {
        XCTAssertEqual(PresenceFormat.unknownLabel, "Status unknown") // D7
    }

    func testRefreshOwnAdoptsAndClearsError() async {
        let store = PresenceStore(
            ownFetcher: { PresenceResponse(ok: true, availability: "Away", activity: "Away") })
        await store.refreshOwn()
        XCTAssertEqual(store.own?.availability, "Away")
        XCTAssertNil(store.error)
    }

    func testRefreshOwnFailureKeepsStale() async {
        struct Boom: Error {}
        let store = PresenceStore(
            ownFetcher: { throw Boom() })
        store.adoptOwn(PresenceResponse(ok: true, availability: "Available", activity: "Available"))
        await store.refreshOwn()
        XCTAssertEqual(store.own?.availability, "Available") // stale kept
        XCTAssertNotNil(store.error)
    }

    func testSetAppliesEcho() async {
        let store = PresenceStore(
            setFetcher: { want in
                XCTAssertEqual(want, "busy")
                return PresenceResponse(ok: true, availability: "Busy", activity: "InACall")
            })
        store.set(status: .busy)
        // set() is fire-and-forget; poll briefly for the echo.
        await TestWait.until { store.own?.availability == "Busy" }
        XCTAssertEqual(store.own?.availability, "Busy")
        XCTAssertFalse(store.setting)
    }

    func testSetBrbSendsBrbAndEchoSelectsIt() async {
        // D1 end-to-end (store seam): set .brb → core gets "brb" → echo
        // availability BeRightBack re-selects the row.
        let store = PresenceStore(
            setFetcher: { want in
                XCTAssertEqual(want, "brb")
                return PresenceResponse(ok: true, availability: "BeRightBack", activity: "BeRightBack")
            })
        store.set(status: .brb)
        await TestWait.until { store.own?.availability == "BeRightBack" }
        XCTAssertEqual(store.own?.availability, "BeRightBack")
        XCTAssertEqual(PresenceStatus.from(availability: "BeRightBack"), .brb)
        XCTAssertFalse(store.setting)
    }

    func testRefreshPeersCachesByID() async {
        let store = PresenceStore(
            userFetcher: { id in
                UserPresenceResponse(ok: true, id: id, availability: "Available", activity: "Available")
            })
        await store.refreshPeers(ids: ["u1", "u2"])
        XCTAssertEqual(store.peers.count, 2)
        XCTAssertEqual(store.peers["u1"]?.availability, "Available")
        XCTAssertNil(store.error)
    }

    func testRefreshChatPeerPinsToChat() async {
        let store = PresenceStore(
            userFetcher: { _ in
                UserPresenceResponse(ok: true, id: "gid-9", availability: "Busy", activity: "InACall")
            })
        await store.refreshChatPeer(chatID: "19:t", userID: "gid-9")
        XCTAssertEqual(store.availabilityForChat("19:t"), "Busy")
        XCTAssertEqual(store.peers["gid-9"]?.activity, "InACall")
        XCTAssertNil(store.availabilityForChat("19:other"))
    }

    func testClearDropsEverything() {
        let store = PresenceStore()
        store.adoptOwn(PresenceResponse(ok: true, availability: "Available", activity: "Available"))
        store.adoptChatPeer(
            chatID: "19:t",
            response: UserPresenceResponse(ok: true, id: "u", availability: "Busy", activity: "x"))
        store.clear()
        XCTAssertNil(store.own)
        XCTAssertTrue(store.peers.isEmpty)
        XCTAssertTrue(store.chatPeers.isEmpty)
    }

    func testDemoFixtures() {
        XCTAssertEqual(DemoData.ownPresence().availability, "Available")
        let peers = DemoData.peerPresence()
        XCTAssertEqual(peers[DemoData.avaID]?.availability, "Busy")
    }
}
