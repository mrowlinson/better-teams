// Guard (regfix-a): the Comfortable/Compact density setting changes what
// is drawn. A message row and a day-separator row measure shorter in
// Compact, and the row-height cache never reuses a Comfortable height.
import XCTest
import AppKit
import SwiftUI

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class DensityGuardTests: XCTestCase {
    private func height<V: View>(_ v: V, _ d: MessageDensity) -> CGFloat {
        let host = NSHostingController(rootView: v.environment(\.messageDensity, d))
        return host.sizeThatFits(in: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)).height
    }

    private var row: MessageRowData {
        let m = ChatMessage(id: "m1", sender: "Megan Harper", timestamp: "2026-09-27T16:02:00Z",
                            content: "hello there", isOwn: false)
        return MessageRowData(message: m, showsHeader: true, send: .none, quote: nil, receipt: .none,
                              translation: nil, isPinned: false, isSaved: false, ownName: nil,
                              chatID: "c", bubble: .other)
    }

    func testMessageRowIsShorterInCompact() {
        let comfortable = height(MessageRowView(row: row, highlighted: false, staticHighlight: false, actions: nil),
                                 .comfortable)
        let compact = height(MessageRowView(row: row, highlighted: false, staticHighlight: false, actions: nil),
                             .compact)
        XCTAssertGreaterThan(comfortable, 0)
        XCTAssertLessThan(compact, comfortable - 4, "Compact must visibly tighten the row")
    }

    func testDaySeparatorRowIsShorterInCompact() {
        let item = TimelineItem.daySeparator(key: "d", label: "Today")
        func h(_ d: MessageDensity) -> CGFloat {
            height(TimelineRowContent(item: item, row: nil, highlighted: false, staticHighlight: false,
                                      actions: nil), d)
        }
        XCTAssertLessThan(h(.compact), h(.comfortable))
    }

    func testHeightCacheSeparatesDensities() {
        let cache = RowHeightCache()
        let a = RowHeightKey(id: "m", revision: 1, width: 500, scale: 1, density: 0)
        let b = RowHeightKey(id: "m", revision: 1, width: 500, scale: 1, density: 1)
        XCTAssertEqual(cache.height(for: a) { 80 }, 80)
        XCTAssertEqual(cache.height(for: b) { 70 }, 70, "Compact re-measures instead of reusing 80")
        cache.retain(width: 500, scale: 1, density: 1)
        XCTAssertNil(cache.cached(a))
        XCTAssertEqual(cache.cached(b), 70)
    }
}
