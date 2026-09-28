// P4bNativeAppsTests.swift — P4b pins (UI-SPEC §6.7): the Planner
// checkbox completes and reopens, Shifts week navigation fetches the
// week on screen, the Notes Append field appends, and the empty states
// state the condition in §6.7's copy. P4B-LEFT: Planner assignees, To Do
// list selection, Recaps merge.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class P4bNativeAppsTests: XCTestCase {
    private func waitUntil(_ cond: () -> Bool) async {
        for _ in 0 ..< 300 where !cond() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Checkbox toggles complete → reopen; a list-selected plan from
    /// another team loads its own board.
    func testPlannerTaskToggle() async {
        let vm = PlannerViewModel(
            teamsFetcher: { DemoData.teamsResponse() },
            plansFetcher: { PlannerDemo.plansResponse(for: $0) },
            bucketsFetcher: { PlannerDemo.bucketsResponse(for: $0) },
            tasksFetcher: { PlannerDemo.tasksResponse(for: $0) },
            localEdits: true)
        await vm.load()
        XCTAssertEqual(vm.plansByTeam["demo-team-eng"]?.count, 2)
        XCTAssertEqual(vm.plansByTeam["demo-team-design"]?.count, 1)
        guard let task = vm.tasks.first(where: { $0.taskId == "demo-ptask-1" }) else {
            return XCTFail("demo board not loaded")
        }
        XCTAssertFalse(task.completed)
        PlannerSection.toggle(task, vm)
        let done = vm.tasks.first { $0.taskId == "demo-ptask-1" }
        XCTAssertEqual(done?.completed, true)
        PlannerSection.toggle(done!, vm)
        XCTAssertEqual(vm.tasks.first { $0.taskId == "demo-ptask-1" }?.completed, false)

        vm.show(planID: "demo-plan-rebrand")
        await waitUntil { vm.tasks.contains { $0.taskId == "demo-ptask-5" } }
        XCTAssertEqual(vm.selectedTeamID, "demo-team-design")
        XCTAssertEqual(vm.buckets.map(\.name), ["Ideas", "Final"])
    }

    /// ‹ › fetch the week on screen (the server filters to it); Today
    /// returns. Rows = people with roster names, time off as rows.
    func testShiftsWeekNavigation() async {
        let asked = WeekLog()
        let store = ShiftsStore(range: { id, start in
                                    asked.append(start)
                                    return ShiftsDemo.response(teamID: id)
                                },
                                members: { DemoTeams.roster(teamID: $0) })
        store.setTeams([ShiftTeam(id: "demo-team-eng", name: "Engineering")])
        store.open(teamID: "demo-team-eng")
        await waitUntil { store.state == .loaded && !store.memberNames.isEmpty }
        guard let week = store.week else { return XCTFail("no week") }
        let rows = ShiftsRow.rows(week: week, reasons: store.reasons, names: store.memberNames)
        XCTAssertEqual(rows.filter { !$0.isTimeOff }.map(\.name),
                       ["Ava Lindqvist", "Megan Harper", "Paula Norris", "Tom Becker"])
        XCTAssertEqual(rows.filter(\.isTimeOff).map(\.name), ["Ava Lindqvist", "Paula Norris"])
        XCTAssertEqual(rows.first { $0.id == "demo-u-megan" }?.days[0].first?.label, "Front Desk")
        XCTAssertEqual(rows.first { $0.id == "off:demo-u-ava" }?.days[3].first?.label, "Vacation")

        let start = store.weekStart
        XCTAssertEqual(asked.all, [start])
        store.showWeek(offset: 1)
        let next = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: start)
        XCTAssertEqual(store.weekStart, next)
        XCTAssertFalse(store.isCurrentWeek)
        await waitUntil { store.state != .loading }
        XCTAssertEqual(asked.all.last, next) // refetched for the new week
        XCTAssertTrue(store.week.map {
            ShiftsRow.rows(week: $0, reasons: store.reasons, names: store.memberNames).isEmpty
        } ?? false) // pane: No Shifts This Week
        store.showCurrentWeek()
        XCTAssertEqual(store.weekStart, start)
        await waitUntil { store.state != .loading }
        XCTAssertEqual(store.state, .loaded)
        let (lo, hi) = ShiftsStore.rangeBounds(weekStart: start)
        XCTAssertTrue(lo.hasSuffix("Z") && hi.hasSuffix("Z") && lo < hi)
    }

    /// Assignees show by roster name; Assign To adds and removes (demo
    /// edits stay in memory).
    func testPlannerAssignees() async {
        let vm = PlannerViewModel(
            teamsFetcher: { DemoData.teamsResponse() },
            plansFetcher: { PlannerDemo.plansResponse(for: $0) },
            bucketsFetcher: { PlannerDemo.bucketsResponse(for: $0) },
            tasksFetcher: { PlannerDemo.tasksResponse(for: $0) },
            membersFetcher: { DemoTeams.roster(teamID: $0) },
            localEdits: true)
        await vm.load()
        await waitUntil { !vm.members.isEmpty }
        guard let task = vm.tasks.first(where: { $0.taskId == "demo-ptask-2" }) else {
            return XCTFail("demo board not loaded")
        }
        XCTAssertEqual(PlannerFormat.assignees(task, vm).map(\.name), ["Me", "Tom Becker"])
        XCTAssertEqual(PlannerFormat.assigneeSummary(["Me", "Tom Becker"]), "Me +1")
        vm.assign(taskID: "demo-ptask-2", userID: "demo-u-ava", assigned: true)
        vm.assign(taskID: "demo-ptask-2", userID: "demo-u-me", assigned: false)
        let edited = vm.tasks.first { $0.taskId == "demo-ptask-2" }!
        XCTAssertEqual(PlannerFormat.assignees(edited, vm).map(\.name), ["Tom Becker", "Ava Lindqvist"])
    }

    /// To Do keeps the list-pane selection across a reload; Recaps
    /// merge a recording and its transcript into one meeting row.
    func testToDoSelectionAndRecapsMerge() async {
        let todo = RemindersViewModel(
            listsFetcher: { DemoData.remindersResponse() },
            tasksFetcher: { DemoData.reminderTasksResponse(for: $0) },
            localEdits: true)
        await todo.load()
        todo.show(listID: "demo-list-groceries")
        await todo.load()
        XCTAssertEqual(todo.selectedListID, "demo-list-groceries")
        XCTAssertEqual(todo.tasks.map(\.taskId), ["demo-task-4", "demo-task-5"])

        let recs = [RecordingItem(id: "r1", name: "Sync-20260924.mp4", created: "2026-09-24T10:00:00Z"),
                    RecordingItem(id: "r2", name: "Retro-20260920.mp4", created: "2026-09-20T10:00:00Z")]
        let trs = [TranscriptItem(id: "t1", name: "Sync-20260924.vtt"),
                   TranscriptItem(id: "t9", name: "Standup-20260926.vtt", created: "2026-09-26T09:00:00Z")]
        let recaps = Recap.merge(recordings: recs, transcripts: trs)
        XCTAssertEqual(recaps.map(\.id), ["t9", "r1", "r2"])
        XCTAssertEqual(recaps[1].transcript?.id, "t1")
        XCTAssertEqual(recaps[1].kind, "Recording and Transcript")
        XCTAssertNil(recaps[2].transcript)
        XCTAssertNil(recaps[0].recording)
    }

    /// Append adds a paragraph to the open page; blank drafts cannot append.
    func testNotesAppend() {
        DemoData.resetDemoAppends()
        defer { DemoData.resetDemoAppends() }
        let store = NotesStore()
        store.showDemo()
        XCTAssertEqual(store.selectedPageID, "demo-page-kickoff")
        XCTAssertFalse(NotesAppendBar.canAppend("   ", appending: false))
        XCTAssertFalse(NotesAppendBar.canAppend("Follow up", appending: true))
        XCTAssertTrue(NotesAppendBar.canAppend("Follow up", appending: false))
        store.append(text: "Follow up with design")
        XCTAssertTrue(store.page?.html.contains("<p>Follow up with design</p>") ?? false)
        XCTAssertEqual(NotesPaneState.resolve(
            store.state, notebooks: store.notebooks.count, sections: store.sections.count,
            pages: store.pages.count, hasPage: store.page != nil, sectionSelected: true,
            forced: nil, offline: false), .page)
    }

    /// §6.7 empty copy; titles state the condition (empty, error, offline).
    func testEmptyStateCopy() {
        XCTAssertEqual(ShiftsPaneState.resolve(.unavailable("x"), hasTeams: true, forced: nil, offline: false),
                       .notSetUp)
        XCTAssertEqual(ShiftsPaneState.resolve(.empty, hasTeams: false, forced: nil, offline: false), .notSetUp)
        XCTAssertEqual(ShiftsPaneState.resolve(.loaded, hasTeams: true, forced: .empty, offline: false), .notSetUp)
        XCTAssertEqual(ShiftsPaneState.notSetUpTitle, "Shifts isn\u{2019}t set up for your teams")
        XCTAssertEqual(PlannerListState.resolve(.loaded, planCount: 0, plansError: nil, forced: nil, offline: false),
                       .empty)
        XCTAssertEqual(PlannerListState.emptyTitle, "No Plans")
        XCTAssertEqual(PlannerListState.resolve(.error("boom"), planCount: 0, plansError: nil, forced: nil,
                                                offline: true),
                       .error(title: "You\u{2019}re Offline", message: PlannerListState.offlineMessage))
        XCTAssertEqual(PlannerBoardState.resolve(planSelected: false, showing: false, loading: false, error: nil,
                                                 bucketCount: 0, taskCount: 0, offline: false), .noSelection)
        XCTAssertEqual(PlannerBoardState.noSelectionTitle, "No Plan Selected")
    }
}

/// Week starts a range fetcher was asked for (fetchers run off-main).
private final class WeekLog: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [Date] = []
    func append(_ d: Date) { lock.lock(); starts.append(d); lock.unlock() }
    var all: [Date] { lock.lock(); defer { lock.unlock() }; return starts }
}
