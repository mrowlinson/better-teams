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

    func testGroupChatMeetNowCreatesMeetingPostsLinkAndJoins() async {
        let app = AppState(args: ["--demo"])
        let model = WindowModel(graph: app, accountKey: "demo", options: LaunchOptions(args: ["--demo"]))
        let nav = Navigator(model: model)
        model.navigator = nav
        addTeardownBlock { _ = nav }
        app.chats.insertLocally(ChatItem(chatId: "19:peer", name: "Ava Lindqvist"))
        app.chats.insertLocally(ChatItem(chatId: "19:group", name: "Standup", is_group: true))
        nav.select(section: .chat)
        let row = MeetingItem(meetingId: "M1", subject: "Meeting in \u{201C}Standup\u{201D}",
                              joinURL: "https://teams.microsoft.com/l/meetup-join/19:meeting_m1@thread.v2/0",
                              isOrganizer: true, isOnline: true)
        var steps: [String] = []
        let done = expectation(description: "meet now finished")
        let flow = ConversationToolbar.MeetNowFlow(
            create: { steps.append("create:\($0)"); return row },
            createError: { nil },
            post: { chat, text in steps.append("post:\(chat):\(text.contains(row.joinURL!))") },
            join: { steps.append("join:\($0.id)") },
            fallback: { chat, _ in steps.append("fallback:\(chat)") },
            finished: { _ in done.fulfill() })

        nav.select(SectionSelection(id: "19:peer"), in: .chat)
        XCTAssertFalse(ConversationToolbar.meetNow(model, flow: flow), "not in a 1:1 chat")

        nav.select(SectionSelection(id: "19:group"), in: .chat)
        XCTAssertTrue(ConversationToolbar.meetNow(model, flow: flow))
        await fulfillment(of: [done], timeout: TestWait.hangCeiling)
        XCTAssertEqual(steps, ["create:Meeting in \u{201C}Standup\u{201D}", "post:19:group:true", "join:M1"],
                       "a real meeting: created, its link posted to the chat, then joined")
        XCTAssertTrue(ConversationToolbar.items.contains(ChatCommands.meetNow))
    }

    /// Sidebar (R34.1/3/4/5/6): organizer never counted; every bucket on
    /// its own labelled row; attendee names + "+N others" + roles; the
    /// Tracking "Sent on" line.
    func testSidebarCountsExcludeOrganizerAndSummarizeAttendees() {
        let gate = DemoGate.launch(args: ["--demo"])!
        let rows = CalendarDemo.week(gate, start: Int64(CalWeek.startOfWeek(containing: DemoClock.now).timeIntervalSince1970)).meetings
        let roadmap = rows.first { $0.id == "demo-cal-roadmap" }!
        XCTAssertEqual(CalendarDetailsText.bucketLine(roadmap),
                       "Accepted: 2 \u{00B7} Tentative: 0 \u{00B7} Declined: 1 \u{00B7} Didn\u{2019}t respond: 2")
        XCTAssertEqual(CalendarDetailsText.attendeeLine(roadmap), "Megan Harper; Tom Becker; Ava Lindqvist +2 others")
        XCTAssertEqual(CalendarDetailsText.roleLine(roadmap), "4 required, 1 optional")
        XCTAssertEqual(CalendarDetailsText.unbroken("Accepted: 2 \u{00B7} Didn\u{2019}t respond: 2"),
                       "Accepted:\u{00A0}2 \u{00B7} Didn\u{2019}t\u{00A0}respond:\u{00A0}2", "breaks only at the dots")
        let standup = rows.first { $0.id == "demo-cal-standup" }!
        XCTAssertEqual(standup.tally.accepted, 2, "me + Tom; the organizer is not an attendee")
        XCTAssertEqual(CalendarEventInfo.groups(standup.invitees).first?.header, "Accepted: 2")
        XCTAssertEqual(CalendarDetailsText.counts(standup), "Accepted 2, Tentative 1, Didn\u{2019}t respond 1")
        XCTAssertNotNil(CalendarDetailsText.sentOn(standup)?.range(of: #"^Sent on \w+day, \d+/\d+/\d{4} at \d+:\d{2}"#,
                                                                    options: .regularExpression))
        XCTAssertEqual(CalendarDetailsText.youResponded(.accepted), "You responded \u{201C}Accept\u{201D}")
        let patch = CalendarDetailsText.roomPatch(roadmap, name: "Room 5", address: "r5@contoso.example")
        XCTAssertEqual(patch.location, "Board Room; Room 5")
        XCTAssertEqual(patch.attendees?.last?.type, "resource")
        XCTAssertFalse(patch.attendees?.contains { $0.response == .organizer } ?? true)
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
