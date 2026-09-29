// ChatTabBarWidthTests.swift — TABS2: the chat header's tab row never
// runs past the pane, whatever the width, tab count or tab name; tabs
// that do not fit go into "+N" and the selected tab always shows.
import AppKit
import SwiftUI
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

@MainActor
final class ChatTabBarWidthTests: XCTestCase {
    static let longFile = "Quarterly Engineering Release Notes and Migration Checklist (final, reviewed).docx"
    /// Detail pane minimum (`ShellSplitViewController` 440), mid, wide.
    static let widths: [CGFloat] = [440, 700, 1200]

    private func tabs(_ n: Int) -> [ChannelTab] {
        (1..<n).map { ChannelTab(id: "t\($0)", name: "Tab \($0)", appID: "3p") }
            + [ChannelTab(id: "long", name: Self.longFile, appID: ChatTabCatalog.officeFileAppID)]
    }

    private func headerWidth(_ layout: ChatTabLayout, selected: ChatTabKey, opened: ChatTabKey?, in w: CGFloat,
                             scale: Double = 1.0) -> CGFloat {
        let header = ConversationHeader(name: "Design Review Group With A Long Name", isGroup: true, subtitle: "5 people",
                                        layout: layout, tab: .constant(selected), opened: opened)
            .environment(\.contentTextScale, scale)
        return NSHostingController(rootView: header).sizeThatFits(in: CGSize(width: w, height: 200)).width
    }

    /// Owner 09-28: a file opened from "+N" in a group chat widened the
    /// row past the pane (unfixed: 752.5 pt in a 470 pt pane).
    func testOverflowFileTabStaysInsidePane() {
        let layout = ChatTabLayout(kind: .group, tabs: DemoChatTabs.tabs(for: "demo"))
        let w = headerWidth(layout, selected: .pinned("demo-tab-notes"), opened: .pinned("demo-tab-notes"), in: 470)
        XCTAssertLessThanOrEqual(w, 470)
    }

    /// 3 widths x {3, 8, 15} pinned tabs (the last a long file name),
    /// with Chat or the long file (opened from "+N") selected.
    func testWidthInvariant() {
        for n in [3, 8, 15] {
            for kind in [ChatKind.group, .meeting] {
                let layout = ChatTabLayout(kind: kind, tabs: tabs(n))
                for w in Self.widths {
                    for (sel, opened) in [(ChatTabKey.builtin(.chat), ChatTabKey?.none), (.pinned("long"), .pinned("long"))] {
                        for scale in [1.0, 2.0] {
                            let got = headerWidth(layout, selected: sel, opened: opened, in: w, scale: scale)
                            XCTAssertLessThanOrEqual(got, w, "n=\(n) \(kind) w=\(w) x\(scale) sel=\(sel): \(got)")
                        }
                    }
                }
            }
        }
    }

    /// Every fold splits all tabs exactly once between the row and "+N",
    /// both in row order, and keeps the selected (then opened) tab.
    func testOverflowMembershipAndSelectedVisible() {
        for n in [3, 8, 15] {
            let layout = ChatTabLayout(kind: .meeting, tabs: tabs(n))
            let ids = layout.all.map(\.id)
            for (sel, opened) in [(ChatTabKey.builtin(.chat), ChatTabKey?.none), (.pinned("long"), .pinned("long")),
                                  (.builtin(.notes), .pinned("t2"))] {
                let folds = layout.folds(selected: sel, opened: opened)
                XCTAssertFalse(folds.isEmpty)
                XCTAssertEqual(Set(folds.map(\.id)).count, folds.count, "fold ids unique")
                for f in folds {
                    XCTAssertEqual(Set(f.segments.map(\.id)).union(f.more.map(\.id)), Set(ids))
                    XCTAssertTrue(Set(f.segments.map(\.id)).isDisjoint(with: f.more.map(\.id)))
                    XCTAssertEqual(f.segments.map(\.id), ids.filter { i in f.segments.contains { $0.id == i } })
                    XCTAssertEqual(f.more.map(\.id), ids.filter { i in f.more.contains { $0.id == i } })
                    XCTAssertTrue(f.segments.contains { $0.key == sel }, "selected always a segment")
                }
                // The opened tab shows in every fold with room for two.
                if let opened, opened != sel {
                    XCTAssertTrue(folds.filter { $0.segments.count >= 2 }.allSatisfy { f in f.segments.contains { $0.key == opened } })
                }
                XCTAssertEqual(folds.last?.segments.map(\.key), [sel])
            }
        }
        // Few tabs: the widest fold shows them all, no "+N".
        XCTAssertEqual(ChatTabLayout(kind: .group, tabs: tabs(2)).folds(selected: .builtin(.chat), opened: nil).first?.more, [])
    }

    /// Only tabs past the standing pinned ones open as temporary tabs.
    func testOnlyOverflowPinnedTabsAreTemporary() {
        let layout = ChatTabLayout(kind: .group, tabs: tabs(8))
        XCTAssertFalse(layout.isOverflowPinned(.builtin(.chat)))
        XCTAssertFalse(layout.isOverflowPinned(.pinned("t1")))
        XCTAssertFalse(layout.isOverflowPinned(.pinned("gone")))
        XCTAssertTrue(layout.isOverflowPinned(.pinned("long")))
    }

    /// Open / replace / close the temporary tab: closing returns to the
    /// tab shown before it opened; closing one not showing keeps the view.
    func testOpenReplaceCloseTemporaryTab() {
        let chats = ChatListViewModel(fetcher: { _ in ChatsResponse(ok: true, chats: []) })
        let graph = AccountWindowGraph(account: AccountRecord(id: "tabs2-test", displayName: "Test"), chats: chats)
        let model = WindowModel(graph: graph, accountKey: "tabs2-test", options: LaunchOptions(args: ["--evidence"]))
        let nav = Navigator(model: model)
        model.navigator = nav
        let ref = "demo"
        nav.setDetailTab(.files, for: ref)
        nav.openDetailAppTab("t5", for: ref)
        XCTAssertEqual(model.nav.detailOpenedTab[ref], "t5")
        XCTAssertEqual(model.nav.detailAppTab[ref], "t5")
        // Replacing: the new one opens, closing it returns to Shared, not t5.
        nav.openDetailAppTab("t6", for: ref)
        XCTAssertEqual(model.nav.detailOpenedTab[ref], "t6")
        nav.closeOpenedTab(for: ref)
        XCTAssertNil(model.nav.detailOpenedTab[ref])
        XCTAssertNil(model.nav.detailAppTab[ref])
        XCTAssertEqual(model.nav.tab(for: ref), .files)
        // Opened from a standing pinned tab: closing returns to it.
        nav.setDetailAppTab("t1", for: ref)
        nav.openDetailAppTab("t7", for: ref)
        nav.closeOpenedTab(for: ref)
        XCTAssertEqual(model.nav.detailAppTab[ref], "t1")
        // Closing one not showing keeps what shows.
        nav.openDetailAppTab("t7", for: ref)
        nav.setDetailTab(.notes, for: ref)
        nav.closeOpenedTab(for: ref)
        XCTAssertNil(model.nav.detailOpenedTab[ref])
        XCTAssertEqual(model.nav.tab(for: ref), .notes)
        XCTAssertNil(model.nav.detailAppTab[ref])
    }
}
