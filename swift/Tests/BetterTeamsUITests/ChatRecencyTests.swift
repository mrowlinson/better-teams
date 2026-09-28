// ChatRecencyTests.swift — Chat list "Recent" order (UI-SPEC §6.2):
// last activity newest first, stable id tiebreak, undated rows last.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class ChatRecencyTests: XCTestCase {
    private func chat(_ id: String, _ time: String?) -> ChatItem {
        ChatItem(chatId: id, name: id, last_message_time: time)
    }

    func testRecencyOrderNewestFirstStableTiebreakUndatedLast() {
        let input = [
            chat("c", "2026-09-21T16:20:11Z"),
            chat("x", nil),
            chat("b", "2026-09-23T09:15:00.123Z"),
            chat("a", "2026-09-23T09:15:00.123Z"),
            chat("d", "2026-09-23T10:41:00Z"),
            chat("w", "garbage"),
        ]
        let ids = ChatListViewModel.recencyOrdered(input).map(\.id)
        XCTAssertEqual(ids, ["d", "a", "b", "c", "w", "x"])
        XCTAssertEqual(ChatListViewModel.recencyOrdered(input.reversed()).map(\.id), ids)
    }

    func testDemoLoadLeadsWithTodayDescending() async {
        let model = ChatListViewModel(fetcher: { _ in DemoData.chatsResponse() })
        await model.load()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let times = model.chats.compactMap { c in
            c.last_message_time.flatMap { iso.date(from: $0) ?? plain.date(from: $0) }
        }
        XCTAssertEqual(times.count, model.chats.count)
        XCTAssertEqual(times, times.sorted(by: >))
    }
}
