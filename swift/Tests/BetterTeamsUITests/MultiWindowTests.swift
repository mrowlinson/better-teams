// MultiWindowTests.swift — P2#9: File ▸ Open Account in New Window ▸
// rows and the main-window "Chat — <Account>" title suffix (>1 window).
import XCTest

import OstMacCore
@testable import BetterTeamsUI

private final class TitleHost: ShellHost {
    var titles: [(String, String)] = []
    func applyPanes(key: String, provider: SectionProvider, layout: SectionLayout,
                    inspectorAvailable: Bool, inspectorVisible: Bool, searching: Bool) {}
    func applyToolbar(_ visible: Set<CommandID>) {}
    func applyTitle(_ title: String, subtitle: String) { titles.append((title, subtitle)) }
    func clearSearchField() {}
    func focusSearchField(placeholder: String) {}
}

@MainActor
final class MultiWindowTests: XCTestCase {
    func testOpenAccountWindowRows() {
        let accts = [AccountRecord(id: "a", displayName: "Ava Lindqvist"),
                     AccountRecord(id: "b", displayName: "Tom Carr")]
        let rows = ShellWindowController.openAccountWindowItems(accounts: accts, demo: false)
        XCTAssertEqual(rows.map(\.title),
                       ["Open \u{201C}Ava Lindqvist\u{201D} in New Window",
                        "Open \u{201C}Tom Carr\u{201D} in New Window"])
        XCTAssertEqual(rows.map(\.arg), ["window:a", "window:b"])
        XCTAssertTrue(rows.allSatisfy(\.enabled))
        // Demo: rows stay (never hidden) but disabled — windows need
        // signed-in accounts.
        let demo = ShellWindowController.openAccountWindowItems(accounts: accts, demo: true)
        XCTAssertTrue(demo.allSatisfy { !$0.enabled })
        XCTAssertTrue(ShellWindowController.openAccountWindowItems(accounts: [], demo: false).isEmpty)
    }

    func testFileMenuListsOpenAccountWindowSubmenu() {
        let file = CommandCatalog.all.filter { $0.menu?.menu == .file }
        let entry = file.first { $0.id == ShellCommand.openAccountWindow }
        XCTAssertNotNil(entry, "File ▸ Open Account in New Window ▸ entry exists")
        XCTAssertTrue(entry?.isSubmenu ?? false)
    }

    func testTitleSuffixOnlyWithSecondWindow() {
        let app = AppState(args: ["--demo"])
        let m = WindowModel(graph: app, accountKey: "demo", options: LaunchOptions(args: ["--demo"]))
        let nav = Navigator(model: m)
        m.navigator = nav
        addTeardownBlock { _ = nav }
        let host = TitleHost()
        nav.host = host
        nav.refreshTitle()
        let plain = host.titles.last?.0 ?? ""
        XCTAssertFalse(plain.contains("—"), "single window: no suffix")

        app.accountWindows.open(accountID: "second") {
            AccountWindowGraph(account: AccountRecord(id: "second", displayName: "Second"))
        }
        addTeardownBlock { app.accountWindows.close(accountID: "second") }
        nav.refreshTitle()
        let suffixed = host.titles.last?.0 ?? ""
        XCTAssertTrue(suffixed.hasPrefix(plain), "suffix appends to the section title")
        XCTAssertTrue(suffixed.contains("—"), "second window: 'Title — <Account>'")

        app.accountWindows.close(accountID: "second")
        nav.refreshTitle()
        XCTAssertEqual(host.titles.last?.0, plain, "closing restores the plain title")
    }
}
