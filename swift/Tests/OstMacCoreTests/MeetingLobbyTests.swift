// MeetingLobbyTests.swift — MEETFIX-B: lobby list from the core roster,
// admit / deny / admit-all wiring (fake core), LOBBY banner category.
import UserNotifications
import XCTest

@testable import OstMacCore

private final class FakeLobbyControl: MeetingLobbyControl, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var fail = false
    var calls: [String] { lock.withLock { _calls } }

    private func note(_ s: String) throws {
        lock.withLock { _calls.append(s) }
        if fail { throw CoreCallError.failed("no_link") }
    }

    func admit(id: String, name: String) throws { try note("admit \(id) \(name)") }
    func admitAll() throws { try note("admitAll") }
    func deny(id: String, name: String) throws { try note("deny \(id) \(name)") }
}

@MainActor
final class MeetingLobbyTests: XCTestCase {
    private func poll(_ json: String) throws -> CallRosterPoll {
        try JSONDecoder().decode(CallRosterPoll.self, from: Data(json.utf8))
    }

    /// The core's roster JSON (`lobby` rows) reaches the lobby model and
    /// stays out of the call roster.
    func testRosterPollFeedsLobby() throws {
        let fake = FakeLobbyControl()
        let mv = MeetingVideoModel(demo: false, lobby: MeetingLobbyModel(control: fake))
        let r = try poll("""
            {"ok":true,"call_id":"c1","updates":1,"participants":[{"id":"8:orgid:me","name":"Me","video_on":false,
            "screen_on":false,"is_self":true}],"lobby":[{"id":"8:teamsvisitor:g","name":"test"}],
            "dominant_msi":null,"dominant_id":null,"log":[]}
            """)
        mv.apply(roster: r, sources: nil, media: nil)
        XCTAssertEqual(mv.lobbyQueue.waiting, [CallLobbyParticipant(id: "8:teamsvisitor:g", name: "test")])
        XCTAssertEqual(mv.roster.map(\.id), ["8:orgid:me"])
        // Older core (no `lobby` key) decodes with an empty lobby.
        let old = try poll(#"{"ok":true,"call_id":"","updates":0,"participants":[],"log":[]}"#)
        mv.apply(roster: old, sources: nil, media: nil)
        XCTAssertTrue(mv.lobbyQueue.waiting.isEmpty)
    }

    func testArrivalsAnnounceOncePerWait() {
        let m = MeetingLobbyModel(control: FakeLobbyControl())
        var arrivals: [String] = []
        m.onArrival = { arrivals.append($0.id) }
        let a = CallLobbyParticipant(id: "a", name: "Ann Baker")
        let b = CallLobbyParticipant(id: "b", name: "")
        m.update([a])
        m.update([a, b])
        m.update([a, b])
        XCTAssertEqual(arrivals, ["a", "b"])
        m.update([b])
        m.update([a, b]) // Ann waits again
        XCTAssertEqual(arrivals, ["a", "b", "a"])
        XCTAssertEqual(b.displayName, "Guest")
    }

    func testAdmitDenyAdmitAllReachTheCore() async {
        let fake = FakeLobbyControl()
        let m = MeetingLobbyModel(control: fake)
        let a = CallLobbyParticipant(id: "a", name: "Ann Baker")
        let b = CallLobbyParticipant(id: "b", name: "Bob Carter")
        m.update([a, b])
        await m.admit(a)
        await m.deny(b)
        await m.admitAll()
        await m.admit(id: "b")
        await m.admit(id: "nobody")
        XCTAssertEqual(fake.calls, ["admit a Ann Baker", "deny b Bob Carter", "admitAll", "admit b Bob Carter"])
        XCTAssertEqual(m.pending, ["a", "b"], "in flight until the roster moves them")
        XCTAssertNil(m.lastError)
        m.update([b])
        XCTAssertEqual(m.pending, ["b"], "left the lobby: no longer pending")
    }

    func testFailedActionKeepsTheRowUsable() async {
        let fake = FakeLobbyControl()
        fake.fail = true
        let m = MeetingLobbyModel(control: fake)
        let a = CallLobbyParticipant(id: "a", name: "Ann Baker")
        m.update([a])
        await m.admit(a)
        XCTAssertEqual(m.waiting, [a])
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertNotNil(m.lastError)
    }

    func testLobbyBannerCategoryAndContent() {
        let c = MeetingLobbyInfo.category
        XCTAssertEqual(c.identifier, "OM_LOBBY")
        XCTAssertEqual(c.actions.map(\.identifier), [MeetingLobbyInfo.admitActionID])
        XCTAssertEqual(c.actions.first?.title, "Admit")
        let content = MeetingLobbyInfo.makeContent(CallLobbyParticipant(id: "8:teamsvisitor:g", name: "test"))
        XCTAssertEqual(content.title, "test is waiting in the lobby")
        XCTAssertEqual(content.categoryIdentifier, MeetingLobbyInfo.categoryID)
        XCTAssertEqual(content.userInfo[MeetingLobbyInfo.participantIDKey] as? String, "8:teamsvisitor:g")
        // Rides along in the category set every message post rewrites.
        let reply = UNTextInputNotificationAction(identifier: "r", title: "Reply", options: [])
        XCTAssertTrue(SystemNotificationCenter.categories(reply: reply).contains { $0.identifier == "OM_LOBBY" })
    }
}
