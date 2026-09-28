// P2bSearchActivityTests.swift — P2b pure-logic tests (UI-SPEC §5.5,
// §6.1, §11.1): search scope plans, result tags, toolbar search
// placement, Activity filters and headlines.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class P2bSearchActivityTests: XCTestCase {
    func testScopePlans() {
        let all = SearchSectionPlan.plan(.all, inConversation: false)
        XCTAssertEqual(all, SearchSectionPlan(topHits: 5, messages: 5, people: 3, files: 3))
        XCTAssertEqual(SearchSectionPlan.plan(.files, inConversation: false),
                       SearchSectionPlan(topHits: 0, messages: 0, people: 0, files: nil))
        // ⌘F conversation scope: messages only, uncapped, whatever scope.
        for s in SearchScope.allCases {
            XCTAssertEqual(SearchSectionPlan.plan(s, inConversation: true),
                           SearchSectionPlan(topHits: 0, messages: nil, people: 0, files: 0))
        }
        XCTAssertEqual(SearchSectionPlan.take([1, 2, 3], 2), [1, 2])
        XCTAssertEqual(SearchSectionPlan.take([1, 2, 3], nil), [1, 2, 3])
    }

    func testResultTagsRoundTrip() {
        let ids: [SearchResultID] = [.target("19:a@thread"), .message("demo-2:ava-1"), .person("u"), .file("f:1")]
        for id in ids { XCTAssertEqual(SearchResultID(tag: id.tag), id) }
        XCTAssertNil(SearchResultID(tag: "x:1"))
        XCTAssertNil(SearchResultID(tag: "m:"))
    }

    /// The search item ends the toolbar (§5.4) and never sits in an
    /// inspector-tracking region that collapses it to its icon.
    func testSearchEndsDetailRegion() {
        let order = ShellToolbarController.layout(CommandCatalog.toolbarCommands).order
        XCTAssertFalse(order.contains(.inspectorTrackingSeparator))
        XCTAssertEqual(order.last, ShellToolbarController.ident(ShellCommand.search))
        let conn = order.firstIndex(of: ShellToolbarController.ident(ShellCommand.connection))
        XCTAssertNotNil(conn)
        XCTAssertLessThan(conn ?? .max, order.count - 1)
    }

    func testFindShortcutsAreUnique() {
        let keys = CommandCatalog.all.map(\.shortcut).filter { !$0.isEmpty }
        XCTAssertEqual(keys.count, Set(keys).count)
        XCTAssertNotNil(CommandCatalog.command(ShellCommand.find))
    }

    private func item(_ kind: ActivityKind, actor: String = "Alex Kay", chat: String = "Design Sync",
                      reviewed: Bool = false) -> ActivityItem {
        ActivityItem(kind: kind, chatID: "c", messageID: "m", actor: actor, chatName: chat, snippet: "s",
                     at: 1_000, reviewed: reviewed)
    }

    func testActivityFilters() {
        let items = [item(.mention), item(.channelBlast), item(.reply, reviewed: true), item(.reaction),
                     item(.missedCall)]
        func count(_ f: ActivityFilter) -> Int { items.filter(f.keeps).count }
        XCTAssertEqual(count(.all), 5)
        XCTAssertEqual(count(.unread), 4)
        XCTAssertEqual(count(.mentions), 2)
        XCTAssertEqual(count(.replies), 1)
        XCTAssertEqual(count(.reactions), 1)
        XCTAssertEqual(count(.missedCalls), 1)
        XCTAssertEqual(count(.saved), 0)
        XCTAssertEqual(ActivityRowModel.rows(items, saved: [], filter: .all, place: { $0 }).map(\.id),
                       items.map(\.id))
    }

    func testActivityHeadlines() {
        XCTAssertEqual(ActivityRowModel.headline(item(.mention)), "Alex Kay mentioned you in Design Sync")
        XCTAssertEqual(ActivityRowModel.headline(item(.reply, chat: "Alex Kay")), "Alex Kay replied to you")
        XCTAssertEqual(ActivityRowModel.headline(item(.reaction, actor: "")), "Reactions to your message in Design Sync")
        XCTAssertEqual(ActivityRowModel.headline(item(.reaction, actor: "Alex Kay")),
                       "Alex Kay reacted to your message in Design Sync")
        XCTAssertEqual(ActivityRowModel.headline(item(.missedCall, chat: "Alex Kay")), "Missed call from Alex Kay")
        XCTAssertTrue(ActivityRowModel(item(.mention, reviewed: false)).unread)
    }

    /// P2b fixes (D11, D5): the second line never restates the headline
    /// and is absent (no reserved line) when there is nothing to add.
    func testActivitySnippetsNeverRepeatTheHeadline() {
        XCTAssertEqual(ActivityRowModel(item(.missedCall)).snippet, "")
        let reaction = ActivityItem(kind: .reaction, chatID: "c", messageID: "m", chatName: "Design Sync",
                                    snippet: "New reaction ❤️×3 on your message in Design Sync", at: 1)
        XCTAssertEqual(ActivityRowModel(reaction).snippet, "❤️ · 3 reactions")
        XCTAssertEqual(ActivityRowModel.reactionTally("New reaction 👍×1 on your message"), "👍 · 1 reaction")
        XCTAssertEqual(ActivityRowModel(item(.mention)).snippet, "s")
    }

    /// P2b fixes (D2): every demo feed row is the message it opens (same
    /// sender, text and time), and the reply really replies to the owner.
    func testDemoFeedRowsMatchTheirMessages() {
        let store = ActivityStore(defaults: UserDefaults(suiteName: "p2bfix-tests-\(UUID().uuidString)")!)
        store.seedDemo()
        XCTAssertEqual(store.items.count, 10)
        for item in store.items where item.messageID != nil {
            let m = DemoData.messages(for: item.chatID).first { $0.id == item.messageID }
            XCTAssertNotNil(m, item.id)
            guard let m, let d = ISO8601DateFormatter().date(from: m.timestamp) else { continue }
            XCTAssertEqual(item.at, UInt64(d.timeIntervalSince1970), item.id)
            if item.kind == .reaction {
                XCTAssertFalse(m.reactions.isEmpty)
                XCTAssertTrue(m.isOwn)
            } else {
                XCTAssertEqual(item.actor, m.sender)
            }
        }
        let replies = store.items.filter { $0.kind == .reply }
        XCTAssertEqual(replies.count, 2)
        for r in replies {
            let m = DemoData.messages(for: r.chatID).first { $0.id == r.messageID }
            let parent = m?.reply_to.flatMap { p in DemoData.messages(for: r.chatID).first { $0.id == p } }
            XCTAssertEqual(parent?.isOwn, true, "\(r.id) replies to the owner")
        }
    }
}
