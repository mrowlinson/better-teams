// ActSearchTests.swift — ACTSEARCH lane pins (UI-SPEC §5.5, §6.1):
// the ⌘F scope bar fits the list pane, find in a conversation is case-
// and diacritic-insensitive and scoped to that conversation, Activity's
// filter and Mark All as Read validate off with no items (online search
// mixes on-device hits back in: MessageSearchOfflineTests).
import AppKit
import SwiftUI
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class ActSearchTests: XCTestCase {
    /// Segments never shrink below their labels: the bar takes small
    /// segments, then mini, then a menu, so no segment is ever wider
    /// than the pane. Wide = small segments (control); the default pane
    /// (276 pt inside margins) = mini for four scopes; the fifth,
    /// conversation segment there = menu (no segmented view).
    func testScopeBarFitsListPane() {
        let four = SearchModel()
        let five = SearchModel()
        five.prepare(conversation: SearchConversationScope(id: "c", name: "Ava Lindqvist"))
        let wide = Self.segmentWidths(four, width: 800)
        XCTAssertEqual(wide.count, 1, "control: segments when wide")
        XCTAssertGreaterThan(wide.first ?? 0, 276, "small segments overflow the default pane")
        XCTAssertEqual(Self.segmentWidths(four, width: 276).count, 1, "four scopes: mini segments fit")
        XCTAssertEqual(Self.segmentWidths(five, width: 800).count, 1, "control: five segments when wide")
        XCTAssertEqual(Self.segmentWidths(five, width: 276, expectSegments: false), [], "five scopes: menu, nothing clipped")
        XCTAssertEqual(Self.segmentWidths(five, width: 236, expectSegments: false), [])
    }

    /// Widths of the segmented controls the bar draws at `width`, each
    /// checked to lie inside it.
    private static func segmentWidths(_ search: SearchModel, width: CGFloat, expectSegments: Bool = true) -> [Int] {
        let host = NSHostingView(rootView: SearchScopeBar(search: search).frame(width: width))
        // Platform controls materialize only inside a window (offscreen,
        // never ordered front).
        let window = OffscreenWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        if expectSegments {
            XCTAssertTrue(TestWait.spinUntil { host.layoutSubtreeIfNeeded(); return !segments(in: host).isEmpty },
                          "segmented control never materialized at \(width)")
        } else {
            // Negative window: the bar collapses to a menu, so there is no
            // positive signal to wait on (cannot be made load-proof).
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        host.layoutSubtreeIfNeeded()
        return segments(in: host).map { v in
            let r = v.convert(v.bounds, to: host)
            XCTAssertGreaterThanOrEqual(r.minX, 0, "segments clipped left at \(width)")
            XCTAssertLessThanOrEqual(r.maxX, width, "segments clipped right at \(width)")
            return Int(r.width.rounded())
        }
    }

    private static func segments(in v: NSView) -> [NSView] {
        let n = String(describing: type(of: v))
        if n.contains("PlatformViewHost"), n.contains("Segmented"), v.bounds.width > 0 { return [v] }
        return v.subviews.flatMap { segments(in: $0) }
    }

    /// "the" finds "The …" and "cafe" finds "Café" in the scoped chat,
    /// even when newer messages elsewhere fill a global result window.
    func testFindInConversationIgnoresCaseAndDiacritics() {
        let local = LocalSearchStore()
        let busy = (0..<40).map {
            ChatMessage(id: "b\($0)", sender: "Tom", timestamp: "2026-09-23T10:\(String(format: "%02d", $0)):00Z",
                        content: "the build is green")
        }
        local.index(chatID: "busy", messages: busy)
        local.index(chatID: "ava", messages: [
            ChatMessage(id: "a1", sender: "Ava", timestamp: "2026-09-22T08:44:51Z",
                        content: "Sure — looking now. The illustration is great."),
            ChatMessage(id: "a2", sender: "Ava", timestamp: "2026-09-22T08:45:40Z",
                        content: "Meet at the Café later?"),
            ChatMessage(id: "a3", sender: "Ava", timestamp: "2026-09-22T08:46:00Z", content: "Nothing here."),
        ])
        XCTAssertEqual(local.hits(matching: "the", inChat: "ava").map(\.messageID), ["a2", "a1"])
        XCTAssertEqual(local.hits(matching: "cafe", inChat: "ava").map(\.messageID), ["a2"])
        XCTAssertEqual(local.hits(matching: "THE", inChat: "busy").count, 40)
        XCTAssertTrue(local.hits(matching: "zzqx", inChat: "ava").isEmpty)

        // Server hits in the chat and on-device matches merge once each.
        let a1 = local.hits(matching: "illustration", inChat: "ava")
        let merged = SearchModel.conversationHits(server: a1, local: local.hits(matching: "the", inChat: "ava"))
        XCTAssertEqual(merged.map(\.messageID), ["a2", "a1"])
    }

    /// Filter and Mark All as Read validate off when the feed lists
    /// nothing (forced empty); on with the demo feed (control). The
    /// inspector (conversation info, §5.3) needs a conversation item.
    func testActivityToolbarOffWithNoItems() {
        defer { RichMediaCache.memoryOnly = false }
        let app = AppState(args: ["--demo"])
        let m = WindowModel(graph: app, accountKey: "demo", options: LaunchOptions(args: ["--demo"]))
        let nav = Navigator(model: m)
        m.navigator = nav
        addTeardownBlock { _ = nav }
        nav.select(section: .activity)
        let a = ActivitySection()

        XCTAssertTrue(a.validate(ActivityCommands.filter, arg: nil, m).enabled, "control: demo feed")
        XCTAssertTrue(a.validate(ActivityCommands.markAllRead, arg: nil, m).enabled, "control: demo unread")

        m.setForced(.empty, for: .activity)
        XCTAssertFalse(a.validate(ActivityCommands.filter, arg: nil, m).enabled)
        XCTAssertFalse(a.validate(ActivityCommands.markAllRead, arg: nil, m).enabled)
        XCTAssertTrue(a.submenuItems(ActivityCommands.filter, m).allSatisfy { !$0.enabled })

        XCTAssertFalse(a.hasInspector(for: nil))
        XCTAssertFalse(a.hasInspector(for: SectionSelection(id: "missedCall:-:call-1")))
        XCTAssertTrue(a.hasInspector(for: SectionSelection(id: "mention:19:c@thread.v2:m1")))
    }
}
