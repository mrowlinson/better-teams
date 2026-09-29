// CalendarLaneTests.swift — CALENDAR lane pins: group-chat Meet now
// starts a meeting on the chat's thread (every member invited) and is
// off in 1:1 chats; the calendar view switcher reads old state and
// every Teams view; the popover time line for all-day events.
import AppKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class CalendarLaneTests: XCTestCase {
    private func makeModel() -> WindowModel {
        let chats = ChatListViewModel(fetcher: { _ in ChatsResponse(ok: true, chats: []) })
        let graph = AccountWindowGraph(account: AccountRecord(id: "calendar-test", displayName: "Test"), chats: chats)
        let model = WindowModel(graph: graph, accountKey: "calendar-test", options: LaunchOptions(args: ["--evidence"]))
        let nav = Navigator(model: model)
        model.navigator = nav
        addTeardownBlock { _ = nav }
        return model
    }

    func testGroupChatMeetNowStartsMeetingOnThread() {
        let model = makeModel()
        CallSettings.shared.useVolatileStorage(.separateWindow)
        defer { CallSettings.shared.useVolatileStorage() }
        model.graph.chats.insertLocally(ChatItem(chatId: "19:peer", name: "Ava Lindqvist"))
        model.graph.chats.insertLocally(ChatItem(chatId: "19:group", name: "Standup", is_group: true))
        model.navigator?.select(section: .chat)

        model.navigator?.select(SectionSelection(id: "19:peer"), in: .chat)
        XCTAssertNil(ConversationToolbar.meetNow(model, show: false, store: CallStore(demo: true)), "not in a 1:1 chat")

        model.navigator?.select(SectionSelection(id: "19:group"), in: .chat)
        let store = CallStore(demo: true)
        let s = ConversationToolbar.meetNow(model, show: false, store: store)
        XCTAssertEqual(s?.kind, .person(name: "Standup", thread: "19:group"))
        XCTAssertEqual(s?.group, true)
        XCTAssertEqual(s?.video, false)
        XCTAssertEqual(store.lastAction, "demo:place-live", "the call goes to the thread: every member is invited")
        XCTAssertTrue(ConversationToolbar.items.contains(ChatCommands.meetNow))
        s?.leave()
    }

    func testViewSelectionReadsEveryTeamsView() {
        XCTAssertEqual(CalendarSelection(SectionSelection(["agenda", "m1"])).view, .list)
        XCTAssertEqual(CalendarSelection(SectionSelection(["agenda", "m1"])).meetingID, "m1")
        for v in CalendarSelection.View.allCases {
            XCTAssertEqual(CalendarSelection(CalendarSelection(view: v, meetingID: "x").selection).view, v)
        }
        XCTAssertEqual(CalendarSelection.View.allCases.map(\.title), ["Day", "Work week", "Week", "Month", "List"])
    }

    func testAllDayTimeLineHasNoClockTimes() {
        let m = MeetingItem(meetingId: "a", subject: "Offsite", start: "2026-09-29T00:00:00",
                            end: "2026-09-30T00:00:00", isAllDay: true)
        XCTAssertTrue(CalendarFormat.when(m).hasSuffix("(All day)"))
        XCTAssertFalse(CalendarFormat.when(m).contains("AM"))
        XCTAssertEqual(CalendarFormat.range(m), "All day")
    }
}
