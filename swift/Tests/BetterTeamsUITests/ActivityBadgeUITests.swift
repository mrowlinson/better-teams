// ActivityBadgeUITests.swift — the rail Activity badge follows the dwell
// counter, not the unread total (owner 09-30). Demo graph, no windows.
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

@MainActor
final class ActivityBadgeUITests: XCTestCase {
    func testRailBadgeRestartsButSubtitleAndRowsStay() {
        defer { RichMediaCache.memoryOnly = false }
        let app = AppState(args: ["--demo"])
        let m = WindowModel(graph: app, accountKey: "demo", options: LaunchOptions(args: ["--demo"]))
        let nav = Navigator(model: m)
        m.navigator = nav
        addTeardownBlock { _ = nav }
        let a = ActivitySection()
        let unread = app.activity.unreviewedCount
        let rows = app.activity.storedCount
        XCTAssertGreaterThan(unread, 0, "control: demo feed has unread items")
        XCTAssertEqual(a.badge(m), unread, "control: badge shows the unread count before dismissal")

        app.activity.dismissBadge()
        XCTAssertNil(a.badge(m), "badge dismissed")
        XCTAssertEqual(a.subtitle(m), "\(unread) unread", "unread total untouched")
        XCTAssertEqual(app.activity.unreviewedCount, unread)
        XCTAssertEqual(app.activity.storedCount, rows, "rows stay listed")
    }
}
