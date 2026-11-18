// ReadStateGuardTests — READSTATE lane: the two owner-reported gaps stay
// fixed. Mark-all-read clears every chat-list section (local + mentions;
// demo stops before the server write) and collapse-all/expand-all hides
// and restores them, persisted per account. Nothing is shown on screen.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class ReadStateGuardTests: XCTestCase {
    private struct NoDock: DockBadging { func setBadge(_ label: String?) {} }

    private nonisolated static func chat(_ id: String) -> ChatItem {
        ChatItem(chatId: id, name: id, is_group: false,
                 last_message_time: "2026-09-28T09:50:00.000Z",
                 last_message_sender: id, last_message_preview: "Hello")
    }

    // MARK: section split (the one split the pane renders)

    func testSplitSectionsKeepsPinnedAboveFavorites() {
        let rows = [Self.chat("c1"), Self.chat("c2"), Self.chat("c3")]
        let split = ChatSection.splitSections(rows, pinnedIDs: ["c1"], favoriteIDs: ["c1", "c2"])
        XCTAssertEqual(split.pinned.map(\.id), ["c1"])
        // A pinned chat in Favorites stays under Pinned (Teams parity).
        XCTAssertEqual(split.favorites.map(\.id), ["c2"])
        XCTAssertEqual(split.recent.map(\.id), ["c3"])
    }

    func testSectionChatIDsScopeToOneSection() {
        let rows = [Self.chat("c1"), Self.chat("c2"), Self.chat("c3")]
        XCTAssertEqual(ChatSection.chatIDs(in: .pinned, rows: rows, pinnedIDs: ["c1"], favoriteIDs: []), ["c1"])
        XCTAssertEqual(ChatSection.chatIDs(in: .recent, rows: rows, pinnedIDs: ["c1"], favoriteIDs: []),
                       ["c2", "c3"])
        XCTAssertEqual(ChatSection.chatIDs(in: .channels, rows: rows, pinnedIDs: [], favoriteIDs: []), [])
    }

    // MARK: collapse state

    func testCollapseStartsExpanded() {
        let state = ChatSectionState()
        XCTAssertTrue(ChatListSection.allCases.allSatisfy { !state.isCollapsed($0) })
        XCTAssertTrue(state.collapsed.isEmpty)
    }

    func testToggleCollapseAllExpandAll() {
        let state = ChatSectionState()
        state.toggleCollapsed(.recent)
        XCTAssertTrue(state.isCollapsed(.recent))
        XCTAssertFalse(state.isCollapsed(.pinned))
        state.toggleCollapsed(.recent)
        XCTAssertFalse(state.isCollapsed(.recent))
        state.collapseAll()
        XCTAssertTrue(ChatListSection.allCases.allSatisfy { state.isCollapsed($0) })
        state.expandAll()
        XCTAssertTrue(state.collapsed.isEmpty)
    }

    func testCollapsePersistsPerAccount() {
        let key = "readstate-guard-\(UUID().uuidString)"
        let full = ChatSectionState.collapseKeyPrefix + key
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: full) }
        let first = ChatSectionState(accountKey: key, persist: true)
        first.setCollapsed(.pinned, true)
        first.setCollapsed(.channels, true)
        let second = ChatSectionState(accountKey: key, persist: true)
        XCTAssertTrue(second.isCollapsed(.pinned))
        XCTAssertTrue(second.isCollapsed(.channels))
        XCTAssertFalse(second.isCollapsed(.recent))
        // Another account starts expanded.
        XCTAssertTrue(ChatSectionState(accountKey: key + "-other", persist: true).collapsed.isEmpty)
    }

    func testMemoryStateNeverTouchesDefaults() {
        let key = "readstate-guard-\(UUID().uuidString)"
        let full = ChatSectionState.collapseKeyPrefix + key
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: full) }
        // persist: false (tests, demo) never writes, even with an account key.
        let state = ChatSectionState(accountKey: key)
        state.collapseAll()
        XCTAssertNil(UserDefaults.standard.stringArray(forKey: full))
    }

    // MARK: mark-all-read commands

    func testMarkAllReadHasMenuTwinAndToolbarButton() {
        let cmd = CommandCatalog.command(ChatCommands.markAllRead)
        let unwrapped = try? XCTUnwrap(cmd)
        XCTAssertNotNil(unwrapped?.menu, "toolbar command must keep its menu twin")
        XCTAssertNotNil(unwrapped?.toolbar, "mark-all-read rides the list toolbar")
        XCTAssertTrue(CommandCatalog.toolbarCommands.map(\.id).contains(ChatCommands.markAllRead))
        // Collapse commands are menu-only (chevrons cover the toolbar job).
        XCTAssertNotNil(CommandCatalog.command(ChatCommands.collapseAll)?.menu)
        XCTAssertNotNil(CommandCatalog.command(ChatCommands.expandAll)?.menu)
        XCTAssertNil(CommandCatalog.command(ChatCommands.collapseAll)?.toolbar)
        XCTAssertNil(CommandCatalog.command(ChatCommands.expandAll)?.toolbar)
    }

    /// Mark-all-read over pinned + recent rows: unread and mentions clear
    /// at once (demo: local only, no server write).
    func testMarkAllReadClearsEverySection() throws {
        let (app, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        app.chats.insertLocally(Self.chat("c1"))
        app.chats.insertLocally(Self.chat("c2"))
        app.chats.pin("c1")
        app.unread.markUnread(chatID: "c1")
        app.unread.markUnread(chatID: "c2")
        app.mentions.seed(["c2": Date()])
        nav.select(section: .chat)
        let provider = try XCTUnwrap(model.provider(.chat) as? ChatSection)
        let scopeBefore = app.chats.displayChats.filter { app.unread.isUnread(chatID: $0.id) }.map(\.id)
        XCTAssertTrue(scopeBefore.contains("c1") && scopeBefore.contains("c2"),
                      "seeded pinned + recent rows read unread")
        let countBefore = app.unread.chatCount
        XCTAssertTrue(provider.validate(ChatCommands.markAllRead, arg: nil, model).enabled,
                      "unread rows enable the command")
        XCTAssertTrue(provider.perform(ChatCommands.markAllRead, arg: nil, model))
        for id in scopeBefore {
            XCTAssertFalse(app.unread.isUnread(chatID: id), "\(id) clears with mark-all-read")
        }
        XCTAssertFalse(app.mentions.contains(chatID: "c2"), "mentions clear with the rows")
        XCTAssertEqual(app.unread.chatCount, countBefore - scopeBefore.count,
                       "rows outside the chat list are untouched")
        let anyLeft = app.chats.displayChats.contains { app.unread.isUnread(chatID: $0.id) }
        XCTAssertEqual(provider.validate(ChatCommands.markAllRead, arg: nil, model).enabled, anyLeft,
                       "the command tracks remaining unread")
        XCTAssertNil(app.chats.readStateError, "demo writes nothing, so nothing fails")
    }

    /// Scoped mark-all-read (section header menu): only that section clears.
    func testMarkSectionReadScopesToOneSection() throws {
        let (app, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        app.chats.insertLocally(Self.chat("c1"))
        app.chats.insertLocally(Self.chat("c2"))
        app.chats.pin("c1")
        app.unread.markUnread(chatID: "c1")
        app.unread.markUnread(chatID: "c2")
        nav.select(section: .chat)
        let provider = try XCTUnwrap(model.provider(.chat) as? ChatSection)
        XCTAssertTrue(provider.perform(ChatCommands.markAllRead, arg: ChatListSection.recent.rawValue, model))
        XCTAssertTrue(app.unread.isUnread(chatID: "c1"), "pinned survives a Recent-scoped mark")
        XCTAssertFalse(app.unread.isUnread(chatID: "c2"), "recent clears")
    }

    /// Collapse-all/expand-all validate against current state and act.
    func testCollapseAllExpandAllRoundTrip() throws {
        let (_, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        nav.select(section: .chat)
        let provider = try XCTUnwrap(model.provider(.chat) as? ChatSection)
        let state = provider.state(model)
        state.expandAll()
        XCTAssertTrue(provider.validate(ChatCommands.collapseAll, arg: nil, model).enabled)
        XCTAssertFalse(provider.validate(ChatCommands.expandAll, arg: nil, model).enabled)
        XCTAssertTrue(provider.perform(ChatCommands.collapseAll, arg: nil, model))
        XCTAssertTrue(ChatListSection.allCases.allSatisfy { state.isCollapsed($0) })
        XCTAssertTrue(provider.validate(ChatCommands.expandAll, arg: nil, model).enabled)
        XCTAssertFalse(provider.validate(ChatCommands.collapseAll, arg: nil, model).enabled)
        XCTAssertTrue(provider.perform(ChatCommands.expandAll, arg: nil, model))
        XCTAssertTrue(state.collapsed.isEmpty)
    }
}
