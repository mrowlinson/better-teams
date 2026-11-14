// AccountMenuTests.swift — P2#11: the Status submenu carries
// Presence Schedule…, and Add Account… sits top-level in the app menu.
import XCTest

@testable import BetterTeamsUI

@MainActor
final class AccountMenuTests: XCTestCase {
    func testPresenceScheduleItem() {
        let on = ShellWindowController.presenceScheduleItem(live: true)
        XCTAssertEqual(on.title, "Presence Schedule…")
        XCTAssertEqual(on.arg, "schedule")
        XCTAssertTrue(on.enabled)
        XCTAssertTrue(on.separatorBefore)
        // No signed-in app (demo): never hidden, disabled instead.
        XCTAssertFalse(ShellWindowController.presenceScheduleItem(live: false).enabled)
    }

    func testTopLevelAddAccount() {
        let app = CommandCatalog.all.filter { $0.menu?.menu == .app }
            .sorted { ($0.menu!.group, $0.menu!.order) < ($1.menu!.group, $1.menu!.order) }
        let titles = app.map(\.title)
        XCTAssertTrue(titles.contains("Add Account…"), "app menu carries top-level Add Account…")
        let entry = app.first { $0.id == ShellCommand.addAccount }
        XCTAssertNotNil(entry)
        XCTAssertFalse(entry?.isSubmenu ?? true)
        // Beside Sign Out…: after Sign In Again…, before Sign Out….
        let ids = app.map(\.id)
        let add = ids.firstIndex(of: ShellCommand.addAccount)!
        let conn = ids.firstIndex(of: ShellCommand.connection)!
        let out = ids.firstIndex(of: ShellCommand.signOut)!
        XCTAssertLessThan(conn, add)
        XCTAssertLessThan(add, out)
    }
}
