// P1ShellTests.swift — P1 pure-logic acceptance (UI-SPEC §11.1, §12 P1):
// Navigator applies synchronously, CommandCatalog invariants, ToolbarModel,
// ScrollAnchor, RowHeightCache, rail capacity and minimum height.
import AppKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

/// Records what the Navigator pushes to AppKit, in call order.
@MainActor
private final class RecordingHost: ShellHost {
    var paneKey: String?
    var layout: SectionLayout?
    var inspectorVisible: Bool?
    var toolbar: Set<CommandID>?
    var title: String?
    var calls: [String] = []

    func applyPanes(key: String, provider: SectionProvider, layout: SectionLayout,
                    inspectorAvailable: Bool, inspectorVisible: Bool, searching: Bool) {
        paneKey = key
        self.layout = layout
        self.inspectorVisible = inspectorVisible
        calls.append("panes")
    }
    func applyToolbar(_ visible: Set<CommandID>) {
        toolbar = visible
        calls.append("toolbar")
    }
    func applyTitle(_ title: String, subtitle: String) {
        self.title = title
        calls.append("title")
    }
    func clearSearchField() {}
    func focusSearchField(placeholder: String) {}
}

@MainActor
final class P1ShellTests: XCTestCase {
    private func makeNavigator() -> (Navigator, RecordingHost) {
        let chats = ChatListViewModel(fetcher: { _ in ChatsResponse(ok: true, chats: []) })
        let graph = AccountWindowGraph(
            account: AccountRecord(id: "p1-test", displayName: "Test"), chats: chats)
        // --evidence: no persistence writes from the test.
        let model = WindowModel(graph: graph, accountKey: "p1-test",
                                options: LaunchOptions(args: ["--evidence"]))
        let nav = Navigator(model: model)
        let host = RecordingHost()
        nav.host = host
        return (nav, host)
    }

    // MARK: Navigator (R21)

    func testSelectWebSectionAppliesEverythingBeforeReturning() {
        let (nav, host) = makeNavigator()
        nav.select(section: .chat)
        host.calls.removeAll()

        nav.select(section: .web("web-demo"))

        // Collapse (layout .full), pane child, toolbar, and title are
        // already applied when select returns: no later turn involved.
        XCTAssertEqual(host.layout, .full)
        XCTAssertEqual(host.paneKey, SectionID.web("web-demo").key)
        XCTAssertEqual(host.title, nav.model.provider(.web("web-demo")).title)
        XCTAssertNotNil(host.toolbar)
        XCTAssertTrue(host.toolbar!.contains(ShellCommand.search))
        XCTAssertEqual(host.calls, ["panes", "toolbar", "title"])
        XCTAssertEqual(nav.model.nav.section, .web("web-demo"))
    }

    func testEndSearchRestoresPriorSection() {
        let (nav, host) = makeNavigator()
        nav.select(section: .files)
        nav.beginSearch(query: "design")
        XCTAssertEqual(host.paneKey, "search")
        XCTAssertEqual(host.title, "Search")

        nav.endSearch()
        XCTAssertEqual(nav.model.nav.section, .files)
        XCTAssertNil(nav.model.nav.search)
        XCTAssertEqual(host.paneKey, SectionID.files.key)
    }

    // MARK: CommandCatalog (R19)

    func testKeyEquivalentsAreUnique() {
        var seen: [String: CommandID] = [:]
        for c in CommandCatalog.all where !c.shortcut.isEmpty {
            XCTAssertNil(seen[c.shortcut], "\(c.id) duplicates \(seen[c.shortcut]!)")
            seen[c.shortcut] = c.id
        }
    }

    func testEveryToolbarCommandHasAMenuItem() {
        for c in CommandCatalog.toolbarCommands {
            XCTAssertNotNil(c.menu, "toolbar command \(c.id) has no menu-bar placement")
        }
    }

    func testCommandIDsAreUnique() {
        let ids = CommandCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testGoShortcutsCoverCommandOneThroughNine() {
        let go = [ShellCommand.goActivity, ShellCommand.goChat, ShellCommand.goTeams,
                  ShellCommand.goCalendar, ShellCommand.goCalls, ShellCommand.goFiles]
            + ShellCommand.goPinned
        let keys = go.compactMap { CommandCatalog.command($0) }
            .filter { $0.modifiers == [.command] }.map(\.key)
        XCTAssertEqual(keys, ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
    }

    // MARK: ToolbarModel (§5.4)

    /// §5.4: no inspector tracking separator; the always-visible
    /// trailing group (inspector toggle, account, search) ends the
    /// toolbar with search last. A new trailing status item (e.g. the
    /// P4a call item) lands after the flexible space, before the group.
    func testToolbarTrailingGroupEndsWithSearch() {
        let call = Command("call.toolbarItem", "Call", symbol: "phone", toolbar: .trailing)
        let group = ShellToolbarController.trailingGroup.map(ShellToolbarController.ident)
        for cmds in [CommandCatalog.toolbarCommands, CommandCatalog.toolbarCommands + [call]] {
            let order = ShellToolbarController.layout(cmds).order
            XCTAssertFalse(order.contains(.inspectorTrackingSeparator))
            XCTAssertEqual(Array(order.suffix(group.count)), group)
            XCTAssertEqual(order.last, ShellToolbarController.ident(ShellCommand.search))
            guard let flex = order.firstIndex(of: .flexibleSpace) else { return XCTFail("no flexible space") }
            let firstGroup = order.count - group.count
            for c in cmds where c.toolbar == .trailing && !ShellToolbarController.trailingGroup.contains(c.id) {
                let i = order.firstIndex(of: ShellToolbarController.ident(c.id)) ?? -1
                XCTAssertTrue(i > flex && i < firstGroup, "\(c.id.rawValue) outside the status region")
            }
        }
    }

    func testFullLayoutHidesListGroupAndSearchHidesSectionItems() {
        let listItems = CommandCatalog.toolbarCommands.filter { $0.toolbar == .list }.map(\.id)
        XCTAssertFalse(listItems.isEmpty)
        let full = ToolbarModel.visible(items: listItems, layout: .full, hasInspector: false,
                                        searching: false, call: false, connection: .online)
        XCTAssertTrue(full.isDisjoint(with: listItems))
        let split = ToolbarModel.visible(items: listItems, layout: .listDetail, hasInspector: true,
                                         searching: false, call: false, connection: .online)
        XCTAssertTrue(split.isSuperset(of: listItems))
        XCTAssertTrue(split.contains(ShellCommand.inspector))
        let searching = ToolbarModel.visible(items: listItems, layout: .listDetail, hasInspector: true,
                                             searching: true, call: false, connection: .offline)
        XCTAssertTrue(searching.isDisjoint(with: listItems))
        XCTAssertTrue(searching.contains(ShellCommand.connection))
        XCTAssertTrue(searching.contains(ShellCommand.search))
    }

    // MARK: ScrollAnchor (§6.2.1)

    func testPinnedWithinToleranceStaysPinned() {
        let a = ScrollAnchor.capture(visibleMinY: 580, visibleHeight: 400, contentHeight: 1000, rows: [])
        XCTAssertEqual(a, .pinnedToBottom)
        let y = ScrollAnchor.restoreOriginY(a, contentHeight: 1300, visibleHeight: 400) { _ in nil }
        XCTAssertEqual(y, 900)
    }

    func testHistoryPrependKeepsAnchorRowOffset() {
        let rows = [ScrollAnchor.Row(id: "a", minY: 0, maxY: 100),
                    ScrollAnchor.Row(id: "b", minY: 100, maxY: 200),
                    ScrollAnchor.Row(id: "c", minY: 200, maxY: 300)]
        let a = ScrollAnchor.capture(visibleMinY: 120, visibleHeight: 100, contentHeight: 3000, rows: rows)
        XCTAssertEqual(a, .anchored(id: "b", offset: -20))
        // 500 pt of history prepended above: b moves to 600.
        let y = ScrollAnchor.restoreOriginY(a, contentHeight: 3500, visibleHeight: 100) {
            $0 == "b" ? (600, 700) : nil
        }
        XCTAssertEqual(y, 620)
    }

    func testJumpCentersRowAndMissReturnsNil() {
        let y = ScrollAnchor.restoreOriginY(.jump(id: "m"), contentHeight: 2000, visibleHeight: 400) {
            $0 == "m" ? (1000, 1100) : nil
        }
        XCTAssertEqual(y, 850)
        XCTAssertNil(ScrollAnchor.restoreOriginY(.jump(id: "gone"), contentHeight: 2000,
                                                 visibleHeight: 400) { _ in nil })
    }

    // MARK: RowHeightCache (§6.2.1, DL4)

    func testMeasuresOncePerKeyAndRemeasuresOnWidthOrRevision() {
        let cache = RowHeightCache()
        let k = RowHeightKey(id: "m1", revision: 1, width: 600.2, scale: 1.0)
        XCTAssertEqual(cache.height(for: k) { 41.3 }, 42)
        XCTAssertEqual(cache.height(for: RowHeightKey(id: "m1", revision: 1, width: 599.9, scale: 1.0)) { 99 }, 42,
                       "sub-point width jitter must not re-measure")
        XCTAssertEqual(cache.measurements, 1)
        _ = cache.height(for: RowHeightKey(id: "m1", revision: 2, width: 600, scale: 1.0)) { 60 }
        _ = cache.height(for: RowHeightKey(id: "m1", revision: 1, width: 420, scale: 1.0)) { 80 }
        _ = cache.height(for: RowHeightKey(id: "m1", revision: 1, width: 600, scale: 1.3)) { 55 }
        XCTAssertEqual(cache.measurements, 4)
        cache.retain(width: 420, scale: 1.0)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.cached(RowHeightKey(id: "m1", revision: 1, width: 420, scale: 1.0)), 80)
    }

    // MARK: Rail capacity (§5.2)

    func testMinimumWindowHeight() {
        XCTAssertEqual(RailModel.minimumWindowHeight(itemHeight: RailModel.itemHeight(.small)), 600)
        XCTAssertEqual(RailModel.minimumWindowHeight(itemHeight: RailModel.itemHeight(.medium)), 600)
        XCTAssertEqual(RailModel.minimumWindowHeight(itemHeight: RailModel.itemHeight(.large)), 640)
    }

    func testOverflowGoesToMore() {
        let h = RailModel.itemHeight(.medium)
        let none = RailModel.layout(railHeight: 2000, itemHeight: h, pinnedCount: 3, fixedItems: 7)
        XCTAssertEqual(none.visiblePinned, 3)
        XCTAssertFalse(none.showsMore)
        let tight = RailModel.layout(railHeight: 540, itemHeight: h, pinnedCount: 8, fixedItems: 7)
        XCTAssertTrue(tight.showsMore)
        XCTAssertLessThan(tight.visiblePinned, 8)
    }
}
