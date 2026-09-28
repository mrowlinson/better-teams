// WireTests.swift — WIRE lane pins: UI-side demo stores stay in memory
// (twin of core DemoLeakTests), New Chat sheet search never touches
// Calls Speed Dial, Join a Team public search in demo, pinned channels
// through the core store in the user's order.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class WireTests: XCTestCase {
    /// Demo ConversationServices (translation, no-app snooze) and the
    /// `seed=pins` evidence store use in-memory defaults. Control first:
    /// live services hold the real `.standard`, and the scan flags it.
    func testDemoConversationStoresNeverUseRealDefaults() {
        let live = ConversationServices(demo: false)
        _ = live.snooze(nil)
        XCTAssertFalse(Self.realDefaults(in: live).isEmpty, "scan blind: live services not flagged")

        let demo = ConversationServices(demo: true)
        _ = demo.snooze(nil) // lazy fallback store
        XCTAssertEqual(Self.realDefaults(in: demo), [])

        defer { RichMediaCache.memoryOnly = false } // process-global (AppState demo sets it)
        let app = AppState(args: ["--demo"])
        let m = WindowModel(graph: app, accountKey: "demo", options: LaunchOptions(
            args: ["--demo", "--route", "chat/wire-demo?seed=pins"]))
        let before = app.pinnedMessages
        ConversationEvidence.seed(m, chatID: "wire-demo")
        XCTAssertFalse(app.pinnedMessages === before, "seed=pins did not run")
        XCTAssertEqual(Self.realDefaults(in: app.pinnedMessages), [], "evidence pins use real defaults")
    }

    /// The New Chat sheet searches its own directory store: a sheet
    /// search leaves the Calls Speed Dial store's results untouched.
    func testNewChatSheetSearchLeavesSpeedDialAlone() async {
        defer { RichMediaCache.memoryOnly = false }
        let app = AppState(args: ["--demo"])
        await app.contacts.search(query: "a")
        let speedDial = app.contacts.results
        XCTAssertFalse(speedDial.isEmpty)

        let sheet = try? XCTUnwrap(NewChatSheet.directory(app, demo: true))
        XCTAssertFalse(sheet === app.contacts)
        await sheet?.search(query: "zzqx-nobody")
        XCTAssertEqual(sheet?.results, [])
        XCTAssertEqual(app.contacts.results, speedDial)
        XCTAssertEqual(app.contacts.lastQuery, "a")
        XCTAssertNil(NewChatSheet.directory(nil, demo: true), "side windows have no directory")
    }

    /// Join a Team (demo, in memory): prompt → results → join a hit →
    /// member; no hits = No Teams Found; a failed search = error.
    func testJoinSheetPublicSearchDemo() async {
        let ledger = DemoTeams.Ledger()
        let teams = TeamsViewModel(fetcher: { DemoTeams.response(ledger: ledger) },
                                   joiner: { try DemoTeams.join($0, ledger: ledger) },
                                   publicSearcher: { DemoTeams.search($0, ledger: ledger) })
        await teams.load()
        XCTAssertEqual(JoinTeamSheet.state(teams), .prompt)

        await teams.searchPublic(query: "research")
        XCTAssertEqual(JoinTeamSheet.state(teams), .results)
        let hit = try? XCTUnwrap(teams.publicResults.first { $0.name == "Research" })
        XCTAssertFalse(hit.map(teams.isMember) ?? true)
        if let hit { await teams.join(publicTeam: hit) }
        XCTAssertNil(teams.joinError)
        XCTAssertTrue(hit.map(teams.isMember) ?? false)

        await teams.searchPublic(query: "zzqx")
        XCTAssertEqual(JoinTeamSheet.state(teams), .empty)
        XCTAssertEqual(JoinTeamSheet.state(teams, forced: .error), .error(JoinTeamSheet.forcedErrorMessage))
        XCTAssertEqual(JoinTeamSheet.state(teams, forced: .loading), .loading)

        struct Down: Error {}
        let failing = TeamsViewModel(fetcher: { DemoTeams.response(ledger: ledger) },
                                     publicSearcher: { _ in throw Down() })
        await failing.searchPublic(query: "research")
        guard case .error = JoinTeamSheet.state(failing) else {
            return XCTFail("failed search is not the error state")
        }
    }

    /// Teams pins go through the core `PinnedChannelStore`: existing
    /// pins under the old key load in order, a pin appends, a move
    /// reorders, and the stored array follows.
    func testPinnedChannelsKeepOrderThroughCoreStore() {
        let suite = "wire-pins-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let key = PinnedChannelStore.key(for: "acct")
        XCTAssertEqual(key, "bt.teams.pinned.acct") // the former ChannelPrefs key
        d.set(["c", "a", "b"], forKey: key)

        let prefs = ChannelPrefs(pins: PinnedChannelStore(accountKey: "acct", defaults: d), rules: nil, demo: false)
        XCTAssertEqual(prefs.pinned, ["c", "a", "b"])
        prefs.setPinned("d", true)
        prefs.pins.move("d", to: 0)
        prefs.setPinned("a", false)
        XCTAssertEqual(prefs.pinned, ["d", "c", "b"])
        XCTAssertTrue(prefs.isPinned("d"))
        XCTAssertEqual(d.stringArray(forKey: key), ["d", "c", "b"])
    }

    /// Every `UserDefaults` reachable from `value` that is not the
    /// in-memory demo defaults (reflection, depth-capped).
    private static func realDefaults(in value: Any, label: String = "root", depth: Int = 0) -> [String] {
        guard depth <= 4 else { return [] }
        if let d = value as? UserDefaults { return d is MemoryDefaults ? [] : [label] }
        var out: [String] = []
        var mirror: Mirror? = Mirror(reflecting: value)
        while let cur = mirror {
            if cur.displayStyle == .collection || cur.displayStyle == .dictionary { break }
            for child in cur.children {
                out += realDefaults(in: child.value, label: "\(label).\(child.label ?? "?")", depth: depth + 1)
            }
            mirror = cur.superclassMirror
        }
        return out
    }
}
