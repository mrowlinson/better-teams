// CallsBadgeTests.swift — P2#8: the Calls rail badge shows missed calls
// since last visit (same count as the subtitle; nil when none).
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class CallsBadgeTests: XCTestCase {
    func testBadgeMirrorsMissedCount() {
        let app = AppState(args: ["--demo"])
        let m = WindowModel(graph: app, accountKey: "demo", options: LaunchOptions(args: ["--demo"]))
        let nav = Navigator(model: m)
        m.navigator = nav
        addTeardownBlock { _ = nav }
        let s = CallsSection()
        let n = CallsSection.rows(m).filter(\.isMissed).count
        XCTAssertGreaterThan(n, 0, "control: demo seeds a missed call")
        XCTAssertEqual(s.badge(m), n)
        XCTAssertEqual(s.subtitle(m), n == 1 ? "1 missed call" : "\(n) missed calls")
        XCTAssertEqual(s.badgeChanges(m).count, 2, "history + activity publishers")
    }

    func testBadgeNilWithoutApp() {
        let chats = ChatListViewModel(fetcher: { _ in ChatsResponse(ok: true, chats: []) })
        let graph = AccountWindowGraph(account: AccountRecord(id: "calls-badge-test", displayName: "Test"),
                                       chats: chats)
        let m = WindowModel(graph: graph, accountKey: "calls-badge-test",
                            options: LaunchOptions(args: ["--evidence"]))
        let s = CallsSection()
        XCTAssertNil(s.badge(m))
        XCTAssertTrue(s.badgeChanges(m).isEmpty)
    }
}
