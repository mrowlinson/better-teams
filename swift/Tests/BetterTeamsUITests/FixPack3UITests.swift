// FixPack3UITests (FIXPACK3): menu bar icon default (R1), failed-delete
// context menu (R7c), Sign In Again enablement (R8), two account windows
// side by side and Manage Folders rule edit/reorder (R9). Nothing is shown
// on screen; no real core profile or user defaults are written.
import AppKit
import SwiftUI
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class FixPack3UITests: XCTestCase {
    private var savedPresenter: ((NSWindowController) -> Void)!
    private var presented: [NSWindowController] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        savedPresenter = PopOutPresenter.present
        PopOutPresenter.present = { [unowned self] c in presented.append(c) }
    }

    override func tearDown() {
        PopOutPresenter.present = savedPresenter
        super.tearDown()
    }

    // MARK: R1

    func testMenuBarIconIsOnByDefaultAndTheSettingCanTurnItOff() {
        let fresh = AppSettings(defaults: MemoryDefaults())
        XCTAssertTrue(fresh.showInMenuBar, "owner: menu bar on by default")
        fresh.showInMenuBar = false
        XCTAssertFalse(fresh.showInMenuBar)
        XCTAssertEqual(fresh.defaults.object(forKey: AppSettings.Key.menuBar) as? Bool, false)
        // An explicit OFF from an earlier build is still honored on the next launch.
        XCTAssertFalse(AppSettings(defaults: fresh.defaults).showInMenuBar, "a saved off stays off")
    }

    // MARK: R8

    func testSignInAgainIsEnabledOnlyWhenTheSessionIsExpired() {
        let app = AppState(args: ["--demo"])
        let wc = ShellWindowController(graph: app, options: LaunchOptions(args: ["--demo", "--evidence"]))
        wc.showShell() // off-display: validation answers only once the shell is installed
        let c = CommandCatalog.command(ShellCommand.connection)
        XCTAssertEqual(c?.key, "i")
        XCTAssertEqual(c?.modifiers, [.command, .shift])
        wc.model.setConnection(.expired)
        XCTAssertTrue(wc.validate(ShellCommand.connection).enabled, "control: expired enables it")
        wc.model.setConnection(.online)
        XCTAssertFalse(wc.validate(ShellCommand.connection).enabled)
        wc.model.setConnection(.offline)
        XCTAssertFalse(wc.validate(ShellCommand.connection).enabled)
    }

    // MARK: R7c

    func testFailedDeleteMenuKeepsTheNormalActionsAndAddsRetryDelete() {
        let app = AppState(args: ["--demo"])
        let wc = ShellWindowController(graph: app, options: LaunchOptions(args: ["--demo", "--evidence"]))
        let actions = TimelineActions(conv: wc.model.graph.conv, model: wc.model, services: ConversationServices.of(wc.model))
        let msg = ChatMessage(id: "m1", sender: "Claire Dawson", timestamp: "2026-09-29T10:00:00Z", content: "hello")
        func menu(failed: Bool) -> [String] {
            var row = MessageRowData(message: msg, showsHeader: true, send: .none, quote: nil, receipt: .none,
                                     translation: nil, isPinned: false, isSaved: false, ownName: nil, chatID: "c")
            row.deleteFailed = failed
            return ChatSyncEvidence.menuText(MessageContextMenu(row: row, actions: actions))
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let normal = menu(failed: false)
        XCTAssertFalse(normal.contains("Retry Delete"))
        let failed = menu(failed: true)
        XCTAssertEqual(failed.first, "Retry Delete", "\(failed)")
        for item in ["Reply", "Forward\u{2026}", "Copy", "Copy Link", "Mark as Unread"] {
            XCTAssertTrue(failed.contains(item), "\(item) missing from the failed-delete menu: \(failed)")
        }
        let items = { (l: [String]) in l.filter { $0 != "Retry Delete" && !$0.isEmpty && !$0.allSatisfy { $0 == "-" || $0 == "\u{2014}" } } }
        XCTAssertEqual(items(failed), items(normal), "everything the normal menu has, plus Retry Delete: \(failed) vs \(normal)")
    }

    // MARK: R9

    func testTwoAccountsOpenTwoWindowsSideBySide() throws {
        let (app, _, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        let model = WindowModel(graph: app, accountKey: "fixpack3-guard", options: LaunchOptions(args: []))
        let navigator = Navigator(model: model)
        model.navigator = navigator
        defer { withExtendedLifetime(navigator) {} }
        app.accounts.adoptLegacy(displayName: "Claire Dawson", upn: "claire@example.test")
        app.accounts.appendRecordWithoutProfileFlip(profile: "fp3-second", displayName: "Daniel Foster",
                                                    upn: "daniel@example.test")
        XCTAssertEqual(app.accounts.accounts.count, 2, "control: two accounts")
        let first = try XCTUnwrap(app.accounts.accounts.first?.id)
        let second = "fp3-second"
        XCTAssertEqual(app.accounts.activeID, first, "the seam never flips the active account")

        AccountWindowController.show(model, accountID: first)
        AccountWindowController.show(model, accountID: second)
        let w1 = try XCTUnwrap(AccountWindowController.window(for: first))
        let w2 = try XCTUnwrap(AccountWindowController.window(for: second))
        addTeardownBlock { w1.close(); w2.close() }
        XCTAssertFalse(w1 === w2, "one window per account")
        XCTAssertEqual(w1.title, "Claire Dawson")
        XCTAssertEqual(w2.title, "Daniel Foster")
        XCTAssertEqual(w2.subtitle, "daniel@example.test")
        XCTAssertEqual(presented.count, 2)
        XCTAssertFalse(w1.isVisible || w2.isVisible, "the test never orders a window in")
        // Both stay registered: opening the second did not replace the first.
        AccountWindowController.show(model, accountID: first)
        XCTAssertTrue(AccountWindowController.window(for: first) === w1)
        XCTAssertTrue(AccountWindowController.window(for: second) === w2)
        // Closing one leaves the other.
        w1.close()
        XCTAssertNil(AccountWindowController.window(for: first))
        XCTAssertTrue(AccountWindowController.window(for: second) === w2)
    }

    func testManageFoldersRuleEditAndReorderPersistInOrder() throws {
        let suite = "fixpack3.folders.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = FolderStore(defaults: defaults)
        let work = try XCTUnwrap(store.createFolder(name: "Work"))
        let people = try XCTUnwrap(store.createFolder(name: "People"))
        let a = try XCTUnwrap(store.addRule(FolderRule(folderID: work.id, namePattern: "budget")))
        let b = try XCTUnwrap(store.addRule(FolderRule(folderID: people.id, kind: .direct)))
        let c = try XCTUnwrap(store.addRule(FolderRule(folderID: work.id, senderDomain: "example.test")))
        XCTAssertEqual(store.rules.map(\.id), [a.id, b.id, c.id], "control: insertion order")

        // The sheet edits drafts: change a field, move a row (List.onMove), toggle one off.
        var drafts = store.rules
        drafts[0].namePattern = "  planning "
        drafts.move(fromOffsets: IndexSet(integer: 2), toOffset: 0) // c to the top
        drafts[2].enabled = false
        ManageFoldersSheet.commitRules(drafts, to: store)

        XCTAssertEqual(store.rules.map(\.id), [c.id, a.id, b.id], "reorder saved")
        XCTAssertEqual(store.rules[1].namePattern, "planning", "edit saved, trimmed")
        XCTAssertFalse(store.rules[2].enabled, "toggle saved")
        let again = FolderStore(defaults: defaults)
        XCTAssertEqual(again.rules.map(\.id), [c.id, a.id, b.id], "order survives a relaunch")
        // Order is priority: the first matching rule files the chat.
        let chat = ChatItem(chatId: "c1", name: "Planning sync", is_group: false, last_message_sender: nil)
        XCTAssertEqual(again.folderID(for: chat), work.id)

        // A rule of a deleted folder does not survive the save.
        store.deleteFolder(id: people.id)
        ManageFoldersSheet.commitRules(drafts, to: store)
        XCTAssertFalse(store.rules.contains { $0.folderID == people.id })
    }

    // MARK: R3

    func testPinnedMessageBarAppearsOnlyWhenTheChatHasPins() {
        let store = PinnedMessageStore(defaults: MemoryDefaults(), key: "fp3.pins")
        let conv = ConversationStore()
        let msg = ChatMessage(id: "m1", sender: "Claire Dawson", timestamp: "2026-09-29T10:00:00Z", content: "Ship it Friday")
        let host = NSHostingView(rootView: PinnedMessageBar(store: store, conv: conv, chatID: "19:pin@thread.v2"))
        XCTAssertEqual(host.fittingSize.height, 0, "no pins: no bar")
        store.pin(chatID: "19:pin@thread.v2", message: msg)
        let shown = NSHostingView(rootView: PinnedMessageBar(store: store, conv: conv, chatID: "19:pin@thread.v2"))
        XCTAssertGreaterThan(shown.fittingSize.height, 10, "a pinned message shows the bar")
        let other = NSHostingView(rootView: PinnedMessageBar(store: store, conv: conv, chatID: "19:other@thread.v2"))
        XCTAssertEqual(other.fittingSize.height, 0, "pins belong to their own chat")
    }

    // MARK: R2

    func testInfoPanelAndRailStartBelowTheToolbar() {
        // TOOLBARLINE supersedes the FIXPACK3 rail-stays-sidebar decision: the
        // rail is a plain item below the toolbar (see ToolbarLineGuardTests).
        let split = ShellSplitViewController(rail: NSViewController())
        XCTAssertFalse(split.railItem.allowsFullHeightLayout, "rail tint must not rise through the toolbar")
        XCTAssertFalse(split.inspectorItem.allowsFullHeightLayout, "info panel tint must not rise through the toolbar")
        XCTAssertTrue(split.detailItem.allowsFullHeightLayout, "control: the property is per item")
    }
}
