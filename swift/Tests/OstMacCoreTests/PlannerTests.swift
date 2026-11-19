// PlannerTests.swift — om-planner lane: wire decode, ViewModel, filter.
import XCTest

@testable import OstMacCore

@MainActor
final class PlannerTests: XCTestCase {
    // MARK: - Fixtures

    nonisolated static func teamsJSON() -> TeamsResponse {
        let json = """
            {"ok":true,"teams":[\
            {"id":"G1","name":"Engineering","channels":[]},\
            {"id":"G2","name":"Design","channels":[]}]}
            """
        return try! decodeOrThrow(TeamsResponse.self, from: Data(json.utf8))
    }

    nonisolated static func plansJSON() -> PlannerPlansResponse {
        let json = """
            {"ok":true,"group_id":"G1","plans":[\
            {"id":"P1","title":"Sprint 12"},\
            {"id":"P2","title":"Tech debt"}]}
            """
        return try! decodeOrThrow(PlannerPlansResponse.self, from: Data(json.utf8))
    }

    nonisolated static func bucketsJSON() -> PlannerBucketsResponse {
        let json = """
            {"ok":true,"plan_id":"P1","buckets":[\
            {"id":"B1","plan_id":"P1","name":"To do"},\
            {"id":"B2","plan_id":"P1","name":"Doing"}]}
            """
        return try! decodeOrThrow(PlannerBucketsResponse.self, from: Data(json.utf8))
    }

    nonisolated static func tasksJSON() -> PlannerTasksResponse {
        let json = """
            {"ok":true,"plan_id":"P1","tasks":[\
            {"id":"T1","plan_id":"P1","bucket_id":"B1","title":"Ship it",\
            "percent":50,"completed":false,"priority":1,\
            "due":"2030-05-04T12:00:00.0000000","etag":"W/\\"e1\\""},\
            {"id":"T2","plan_id":"P1","bucket_id":"B2","title":"Done thing",\
            "percent":100,"completed":true,"priority":null,"due":null,\
            "etag":"W/\\"e2\\""}]}
            """
        return try! decodeOrThrow(PlannerTasksResponse.self, from: Data(json.utf8))
    }

    nonisolated static func taskResultJSON() -> PlannerTaskResult {
        let json = """
            {"ok":true,"task":{"id":"T9","plan_id":"P1","bucket_id":"B1",\
            "title":"New","percent":0,"completed":false,"priority":null,\
            "due":null,"etag":"W/\\"e9\\""}}
            """
        return try! decodeOrThrow(PlannerTaskResult.self, from: Data(json.utf8))
    }

    static func model(
        teams: TeamsResponse? = nil,
        plans: PlannerPlansResponse? = nil,
        buckets: PlannerBucketsResponse? = nil,
        tasks: PlannerTasksResponse? = nil,
        localEdits: Bool = false
    ) -> PlannerViewModel {
        PlannerViewModel(
            teamsFetcher: { teams ?? teamsJSON() },
            plansFetcher: { _ in plans ?? plansJSON() },
            bucketsFetcher: { _ in buckets ?? bucketsJSON() },
            tasksFetcher: { _ in tasks ?? tasksJSON() },
            localEdits: localEdits)
    }

    // MARK: - Wire decode

    func testDecodePlans() {
        let response = Self.plansJSON()
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.group_id, "G1")
        XCTAssertEqual(response.plans.count, 2)
        XCTAssertEqual(response.plans[0].id, "P1")
        XCTAssertEqual(response.plans[0].title, "Sprint 12")
    }

    func testDecodeBuckets() {
        let response = Self.bucketsJSON()
        XCTAssertEqual(response.plan_id, "P1")
        XCTAssertEqual(response.buckets.count, 2)
        XCTAssertEqual(response.buckets[0].id, "B1")
        XCTAssertEqual(response.buckets[0].planId, "P1")
        XCTAssertEqual(response.buckets[0].name, "To do")
    }

    func testDecodeTasks() {
        let response = Self.tasksJSON()
        XCTAssertEqual(response.plan_id, "P1")
        XCTAssertEqual(response.tasks.count, 2)
        XCTAssertEqual(response.tasks[0].id, "T1")
        XCTAssertEqual(response.tasks[0].title, "Ship it")
        XCTAssertEqual(response.tasks[0].bucketId, "B1")
        XCTAssertEqual(response.tasks[0].percent, 50)
        XCTAssertFalse(response.tasks[0].completed)
        XCTAssertEqual(response.tasks[0].priority, 1)
        XCTAssertEqual(response.tasks[0].etag, "W/\"e1\"")
        XCTAssertTrue(response.tasks[1].completed)
        XCTAssertNil(response.tasks[1].priority)
        XCTAssertNil(response.tasks[1].displayDue)
        // Routes through ChatMessage rules (local + locale clock; exact
        // pins live in FidTimeTests with explicit zone/locale).
        XCTAssertEqual(
            response.tasks[0].displayDue,
            ChatMessage.shortTime("2030-05-04T12:00:00.0000000"))
    }

    func testDecodeTaskResult() {
        let result = Self.taskResultJSON()
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.task.id, "T9")
        XCTAssertEqual(result.task.title, "New")
        XCTAssertEqual(result.task.etag, "W/\"e9\"")
    }

    func testErrorEnvelopeThrows() {
        let json = #"{"ok":false,"error":"planner_tasks","detail":"nope"}"#
        XCTAssertThrowsError(
            try decodeOrThrow(PlannerPlansResponse.self, from: Data(json.utf8)))
        XCTAssertThrowsError(
            try decodeOrThrow(PlannerBucketsResponse.self, from: Data(json.utf8)))
        XCTAssertThrowsError(
            try decodeOrThrow(PlannerTasksResponse.self, from: Data(json.utf8)))
    }

    // MARK: - ViewModel states

    func testLoadSelectsFirstTeamPlanAndBoard() async {
        let model = Self.model()
        XCTAssertEqual(model.state, .loading)
        await model.load()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.teams.count, 2)
        XCTAssertEqual(model.selectedTeamID, "G1")
        XCTAssertEqual(model.plans.count, 2)
        XCTAssertEqual(model.selectedPlanID, "P1")
        XCTAssertEqual(model.buckets.count, 2)
        XCTAssertEqual(model.tasks.count, 2)
        XCTAssertFalse(model.boardLoading)
        XCTAssertNil(model.boardError)
    }

    func testLoadEmpty() async {
        let model = PlannerViewModel(
            teamsFetcher: { TeamsResponse(ok: true, teams: []) },
            plansFetcher: { id in
                PlannerPlansResponse(ok: true, group_id: id, plans: [])
            },
            bucketsFetcher: { id in
                PlannerBucketsResponse(ok: true, plan_id: id, buckets: [])
            },
            tasksFetcher: { id in
                PlannerTasksResponse(ok: true, plan_id: id, tasks: [])
            })
        await model.load()
        XCTAssertEqual(model.state, .empty)
        XCTAssertNil(model.selectedTeamID)
        XCTAssertNil(model.selectedPlanID)
        XCTAssertTrue(model.tasks.isEmpty)
    }

    func testLoadError() async {
        let model = PlannerViewModel(
            teamsFetcher: { () -> TeamsResponse in
                throw CoreCallError.failed("boom")
            },
            plansFetcher: { _ in Self.plansJSON() },
            bucketsFetcher: { _ in Self.bucketsJSON() },
            tasksFetcher: { _ in Self.tasksJSON() })
        await model.load()
        XCTAssertEqual(model.state, .error("boom"))
    }

    func testSelectTeamReloadsPlans() async {
        let model = Self.model()
        await model.load()
        XCTAssertEqual(model.selectedTeamID, "G1")
        model.selectTeam(teamID: "G2")
        await waitFor { model.selectedTeamID == "G2" && !model.boardLoading }
        XCTAssertEqual(model.plans.count, 2) // mock returns same plans
        XCTAssertEqual(model.selectedPlanID, "P1")
    }

    func testSelectPlanReloadsBoard() async {
        let model = PlannerViewModel(
            teamsFetcher: { Self.teamsJSON() },
            plansFetcher: { _ in Self.plansJSON() },
            bucketsFetcher: { id in
                PlannerBucketsResponse(
                    ok: true, plan_id: id,
                    buckets: [PlannerBucket(
                        bucketId: "b-\(id)", planId: id, name: "Col")])
            },
            tasksFetcher: { id in
                PlannerTasksResponse(
                    ok: true, plan_id: id,
                    tasks: [PlannerTask(
                        taskId: "t-\(id)", planId: id,
                        bucketId: "b-\(id)", title: "in \(id)")])
            })
        await model.load()
        XCTAssertEqual(model.selectedPlanID, "P1")
        XCTAssertEqual(model.tasks.first?.taskId, "t-P1")
        model.selectPlan(planID: "P2")
        await waitFor { model.tasks.first?.taskId == "t-P2" }
        XCTAssertEqual(model.selectedPlanID, "P2")
        XCTAssertEqual(model.buckets.first?.bucketId, "b-P2")
        XCTAssertFalse(model.boardLoading)
    }

    func testBoardErrorSurfaces() async {
        let model = PlannerViewModel(
            teamsFetcher: { Self.teamsJSON() },
            plansFetcher: { _ in Self.plansJSON() },
            bucketsFetcher: { _ in Self.bucketsJSON() },
            tasksFetcher: { _ -> PlannerTasksResponse in
                throw CoreCallError.failed("tasks down")
            })
        await model.load()
        XCTAssertEqual(model.state, .loaded) // teams fine, board failed
        XCTAssertEqual(model.boardError, "tasks down")
        XCTAssertFalse(model.boardLoading)
    }

    // MARK: - Add / complete / reopen (mock fetchers)

    func testAddAppendsCreated() async {
        let model = PlannerViewModel(
            teamsFetcher: { Self.teamsJSON() },
            plansFetcher: { _ in Self.plansJSON() },
            bucketsFetcher: { _ in Self.bucketsJSON() },
            tasksFetcher: { _ in Self.tasksJSON() },
            addFetcher: { planID, bucketID, title in
                PlannerTaskResult(
                    ok: true,
                    task: PlannerTask(
                        taskId: "T-new", planId: planID,
                        bucketId: bucketID, title: title))
            })
        await model.load()
        XCTAssertEqual(model.tasks.count, 2)
        model.add(bucketID: "B1", title: "  file taxes  ")
        await waitFor { model.tasks.count == 3 }
        XCTAssertEqual(model.tasks.last?.title, "file taxes")
        XCTAssertEqual(model.tasks.last?.bucketId, "B1")
        XCTAssertNil(model.boardError)
    }

    func testAddEmptyTitleOrUnknownBucketIgnored() async {
        let model = PlannerViewModel(
            teamsFetcher: { Self.teamsJSON() },
            plansFetcher: { _ in Self.plansJSON() },
            bucketsFetcher: { _ in Self.bucketsJSON() },
            tasksFetcher: { _ in Self.tasksJSON() },
            addFetcher: { _, _, _ in Self.taskResultJSON() })
        await model.load()
        model.add(bucketID: "B1", title: "   ")
        model.add(bucketID: "nope", title: "x")
        XCTAssertEqual(model.tasks.count, 2) // sync no-ops, no wait needed
    }

    func testCompleteFlipsRow() async {
        let model = PlannerViewModel(
            teamsFetcher: { Self.teamsJSON() },
            plansFetcher: { _ in Self.plansJSON() },
            bucketsFetcher: { _ in Self.bucketsJSON() },
            tasksFetcher: { _ in Self.tasksJSON() },
            doneFetcher: { taskID, _ in
                PlannerTaskResult(
                    ok: true,
                    task: PlannerTask(
                        taskId: taskID, planId: "P1", bucketId: "B1",
                        title: "Ship it", percent: 100, completed: true))
            })
        await model.load()
        XCTAssertFalse(model.tasks[0].completed)
        model.complete(taskID: "T1")
        await waitFor { model.tasks[0].completed }
        XCTAssertEqual(model.tasks[0].percent, 100)
        // Already-done row: no fetcher call, no change.
        model.complete(taskID: "T2")
        XCTAssertTrue(model.tasks[1].completed)
    }

    func testReopenFlipsRow() async {
        let model = PlannerViewModel(
            teamsFetcher: { Self.teamsJSON() },
            plansFetcher: { _ in Self.plansJSON() },
            bucketsFetcher: { _ in Self.bucketsJSON() },
            tasksFetcher: { _ in Self.tasksJSON() },
            reopenFetcher: { taskID, _ in
                PlannerTaskResult(
                    ok: true,
                    task: PlannerTask(
                        taskId: taskID, planId: "P1", bucketId: "B2",
                        title: "Done thing", percent: 0, completed: false))
            })
        await model.load()
        XCTAssertTrue(model.tasks[1].completed)
        model.reopen(taskID: "T2")
        await waitFor { !model.tasks[1].completed }
        XCTAssertEqual(model.tasks[1].percent, 0)
        // Already-open row: no fetcher call, no change.
        model.reopen(taskID: "T1")
        XCTAssertFalse(model.tasks[0].completed)
    }

    func testSetErrorSurfaces() async {
        let model = PlannerViewModel(
            teamsFetcher: { Self.teamsJSON() },
            plansFetcher: { _ in Self.plansJSON() },
            bucketsFetcher: { _ in Self.bucketsJSON() },
            tasksFetcher: { _ in Self.tasksJSON() },
            doneFetcher: { _, _ -> PlannerTaskResult in
                throw CoreCallError.failed("stale etag")
            })
        await model.load()
        model.complete(taskID: "T1")
        await waitFor { model.boardError != nil }
        XCTAssertEqual(model.boardError, "stale etag")
        XCTAssertFalse(model.tasks[0].completed)
    }

    // MARK: - Local edits (demo mode)

    func testLocalEditsAddCompleteReopen() async {
        let model = Self.model(localEdits: true)
        await model.load()
        model.add(bucketID: "B1", title: "local task")
        XCTAssertEqual(model.tasks.count, 3) // sync in local mode
        XCTAssertEqual(model.tasks.last?.title, "local task")
        model.complete(taskID: "T1")
        XCTAssertTrue(model.tasks[0].completed)
        XCTAssertEqual(model.tasks[0].percent, 100)
        model.reopen(taskID: "T1")
        XCTAssertFalse(model.tasks[0].completed)
        XCTAssertEqual(model.tasks[0].percent, 0)
    }

    // MARK: - Filter

    func testVisibleGroupsByBucketAndHidesDone() {
        let tasks = Self.tasksJSON().tasks
        let b1 = PlannerViewModel.visible(tasks, bucketID: "B1", hideDone: false)
        XCTAssertEqual(b1.count, 1)
        XCTAssertEqual(b1[0].id, "T1")
        let b2open = PlannerViewModel.visible(tasks, bucketID: "B2", hideDone: true)
        XCTAssertTrue(b2open.isEmpty)
        let b2all = PlannerViewModel.visible(tasks, bucketID: "B2", hideDone: false)
        XCTAssertEqual(b2all.count, 1)
        XCTAssertTrue(
            PlannerViewModel.visible(tasks, bucketID: "nope", hideDone: false).isEmpty)
    }

    func testOrphanedFindsUnknownBuckets() {
        let tasks = Self.tasksJSON().tasks
        XCTAssertTrue(
            PlannerViewModel.orphaned(tasks, buckets: Self.bucketsJSON().buckets).isEmpty)
        XCTAssertEqual(
            PlannerViewModel.orphaned(tasks, buckets: []).count, 2)
    }

    // MARK: - Demo data

    func testDemoPlannerBoards() {
        for team in DemoData.teams {
            let plans = PlannerDemo.plansResponse(for: team.teamId)
            XCTAssertFalse(plans.plans.isEmpty)
            for plan in plans.plans {
                XCTAssertFalse(PlannerDemo.buckets(for: plan.planId).isEmpty)
                XCTAssertFalse(PlannerDemo.tasks(for: plan.planId).isEmpty)
            }
        }
        XCTAssertTrue(PlannerDemo.plans(for: "nope").isEmpty)
        XCTAssertTrue(PlannerDemo.buckets(for: "nope").isEmpty)
        XCTAssertTrue(PlannerDemo.tasks(for: "nope").isEmpty)
        // Sprint board: every bucket holds tasks (open / in progress /
        // in review / done), each assigned.
        let tasks = PlannerDemo.tasks(for: "demo-plan-sprint")
        XCTAssertEqual(tasks.count, 12)
        XCTAssertEqual(tasks.filter(\.completed).count, 3)
        XCTAssertTrue(PlannerDemo.buckets(for: "demo-plan-sprint").allSatisfy { b in
            tasks.contains { $0.bucketId == b.bucketId }
        })
        XCTAssertTrue(tasks.allSatisfy { !$0.assignees.isEmpty })
        XCTAssertTrue(tasks.contains { $0.percent == 50 && !$0.completed })
        // Demo rows carry etags so done/reopen round-trip offline.
        XCTAssertTrue(tasks.allSatisfy { !$0.etag.isEmpty })
    }

    // MARK: - Helpers

    /// Wait until `cond` holds (mock fetchers resolve in ms; the ceiling only bounds a hang).
    private func waitFor(
        _ cond: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        if await TestWait.until(interval: 0.02, cond) { return }
        XCTFail("condition not met before the hang ceiling", file: file, line: line)
    }

    // MARK: - Depth decode

    func testDecodeTaskLabelsAndThread() {
        let json = """
            {"ok":true,"plan_id":"P1","tasks":[\
            {"id":"T1","plan_id":"P1","bucket_id":"B1","title":"Labeled",\
            "percent":0,"completed":false,"etag":"W/\\"e\\"",\
            "labels":[1,3],"thread":"thread-9"}]}
            """
        let response = try! decodeOrThrow(PlannerTasksResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.tasks[0].labels, [1, 3])
        XCTAssertEqual(response.tasks[0].threadID, "thread-9")
    }

    func testDecodeTaskWithoutDepthKeys() {
        // Old core JSON (no labels/thread) still decodes.
        let response = Self.tasksJSON()
        XCTAssertTrue(response.tasks.allSatisfy { $0.labels.isEmpty })
        XCTAssertTrue(response.tasks.allSatisfy { $0.threadID.isEmpty })
    }

    func testDecodePlanCategoriesAndEtag() {
        let json = """
            {"ok":true,"group_id":"G1","plans":[\
            {"id":"P1","title":"Sprint","etag":"W/\\"p\\"",\
            "categories":{"category1":"Design","category9":"Out of range"}}]}
            """
        let response = try! decodeOrThrow(PlannerPlansResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.plans[0].categories, [1: "Design"])
        XCTAssertEqual(response.plans[0].etag, "W/\"p\"")
        XCTAssertEqual(response.plans[0].labelName(1), "Design")
        XCTAssertEqual(response.plans[0].labelName(4), "Label 4")
    }

    func testDecodeDetailsCommentsResults() {
        let details = """
            {"ok":true,"task_id":"T1","details":\
            {"etag":"W/\\"d\\"","description":"notes","preview":"checklist",\
            "checklist":[{"id":"c1","title":"A","checked":true}],\
            "references":[{"url":"https://example.com/a","alias":"Spec"}]}}
            """
        let d = try! decodeOrThrow(PlannerDetailsResponse.self, from: Data(details.utf8))
        XCTAssertTrue(d.ok)
        XCTAssertEqual(d.details.etag, "W/\"d\"")
        XCTAssertEqual(d.details.checklist.count, 1)
        XCTAssertEqual(d.details.references.first?.alias, "Spec")
        let comments = """
            {"ok":true,"group_id":"G","thread_id":"th","posts":[\
            {"id":"p1","kind":"Text","content":"hi","received":"2026-10-04T12:00:00Z"}]}
            """
        let c = try! decodeOrThrow(PlannerCommentsResponse.self, from: Data(comments.utf8))
        XCTAssertEqual(c.posts.count, 1)
        XCTAssertEqual(c.posts[0].text, "hi")
        let html = PlannerComment(id: "p2", kind: "html", content: "<p>hey</p>")
        XCTAssertEqual(html.text, "hey")
        let plan = try! decodeOrThrow(PlannerPlanResult.self, from:
            Data("{\"ok\":true,\"plan\":{\"id\":\"P1\",\"title\":\"B\"}}".utf8))
        XCTAssertEqual(plan.plan.planId, "P1")
        let bucket = try! decodeOrThrow(PlannerBucketResult.self, from:
            Data("{\"ok\":true,\"bucket\":{\"id\":\"B1\",\"plan_id\":\"P1\",\"name\":\"To do\"}}".utf8))
        XCTAssertEqual(bucket.bucket.name, "To do")
    }

    // MARK: - Charts / Schedule groupings

    static func labeledTasks() -> ([PlannerTask], PlannerPlan) {
        let plan = PlannerPlan(planId: "P1", title: "Sprint", categories: [1: "Design", 2: "Beta"])
        let tasks = [
            PlannerTask(taskId: "a", planId: "P1", bucketId: "B1", title: "A", labels: [1]),
            PlannerTask(taskId: "b", planId: "P1", bucketId: "B1", title: "B", percent: 100, completed: true, labels: [1, 2]),
            PlannerTask(taskId: "c", planId: "P1", bucketId: "B1", title: "C"),
        ]
        return (tasks, plan)
    }

    func testChartRowsGroupByLabel() {
        let (tasks, plan) = Self.labeledTasks()
        let (rows, unlabeled) = PlannerViewModel.chartRows(tasks, plan: plan)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], PlannerChartRow(label: 1, name: "Design", total: 2, done: 1))
        XCTAssertEqual(rows[1], PlannerChartRow(label: 2, name: "Beta", total: 1, done: 1))
        XCTAssertEqual(unlabeled, PlannerChartRow(label: 0, name: "No label", total: 1, done: 0))
    }

    func testChartRowsEmpty() {
        let (rows, unlabeled) = PlannerViewModel.chartRows([], plan: nil)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertNil(unlabeled)
    }

    func testScheduleGroupsBucketAndSort() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 12))!
        func dated(_ id: String, _ iso: String?, completed: Bool = false) -> PlannerTask {
            PlannerTask(taskId: id, planId: "P1", bucketId: "B1", title: id,
                        percent: completed ? 100 : 0, completed: completed, due: iso)
        }
        let tasks = [
            dated("later", "2026-10-20T12:00:00Z"),
            dated("past", "2026-10-01T12:00:00Z"),
            dated("today", "2026-10-06T12:00:00Z"),
            dated("week", "2026-10-08T12:00:00Z"),
            dated("done-past", "2026-10-01T12:00:00Z", completed: true),
            dated("none", nil),
        ]
        let groups = PlannerViewModel.scheduleGroups(tasks, now: now, calendar: cal)
        XCTAssertEqual(groups.map(\.title), ["Overdue", "Today", "This week", "Later", "No due date"])
        XCTAssertEqual(groups[0].tasks.map(\.taskId), ["past"])
        XCTAssertEqual(groups[1].tasks.map(\.taskId), ["today"])
        // Completed keeps its date (This week sorts oldest first).
        XCTAssertEqual(groups[2].tasks.map(\.taskId), ["done-past", "week"])
        XCTAssertEqual(groups[3].tasks.map(\.taskId), ["later"])
        XCTAssertEqual(groups[4].tasks.map(\.taskId), ["none"])
    }

    // MARK: - Depth ViewModel (localEdits)

    static func depthModel() -> PlannerViewModel {
        PlannerViewModel(
            teamsFetcher: { teamsJSON() },
            plansFetcher: { _ in plansJSON() },
            bucketsFetcher: { _ in bucketsJSON() },
            tasksFetcher: { _ in tasksJSON() },
            localEdits: true)
    }

    func testDepthLabelsLocalEdits() async {
        let model = Self.depthModel()
        await model.load()
        model.setLabel(taskID: "T1", category: 1, on: true)
        XCTAssertEqual(model.tasks[0].labels, [1])
        model.setLabel(taskID: "T1", category: 7, on: true) // out of range: ignored
        model.setLabel(taskID: "T1", category: 1, on: true) // no-op
        XCTAssertEqual(model.tasks[0].labels, [1])
        model.setLabel(taskID: "T1", category: 1, on: false)
        XCTAssertTrue(model.tasks[0].labels.isEmpty)
    }

    func testDepthChecklistLocalEdits() async {
        let model = Self.depthModel()
        await model.load()
        model.loadDetails(taskID: "T9") // unknown fixture: blank details
        XCTAssertTrue(model.detailsByTask["T9"]?.checklist.isEmpty ?? false)
        model.addChecklist(taskID: "T9", title: "  milk  ")
        model.addChecklist(taskID: "T9", title: "   ") // ignored
        XCTAssertEqual(model.detailsByTask["T9"]?.checklist.map(\.title), ["milk"])
        let id = model.detailsByTask["T9"]!.checklist[0].itemId
        model.toggleChecklist(taskID: "T9", itemID: id)
        XCTAssertTrue(model.detailsByTask["T9"]!.checklist[0].checked)
        model.toggleChecklist(taskID: "T9", itemID: id)
        XCTAssertFalse(model.detailsByTask["T9"]!.checklist[0].checked)
        model.removeChecklist(taskID: "T9", itemID: id)
        XCTAssertTrue(model.detailsByTask["T9"]!.checklist.isEmpty ?? false)
    }

    func testDepthDescriptionReferenceLocalEdits() async {
        let model = Self.depthModel()
        await model.load()
        model.loadDetails(taskID: "T1")
        model.setDescription(taskID: "T1", description: "hello")
        XCTAssertEqual(model.detailsByTask["T1"]?.description, "hello")
        model.addReference(taskID: "T1", url: "https://example.com/a", alias: "")
        XCTAssertEqual(model.detailsByTask["T1"]?.references.first?.alias, "https://example.com/a")
        model.addReference(taskID: "T1", url: "  ", alias: "x") // ignored
        XCTAssertEqual(model.detailsByTask["T1"]?.references.count, 1)
        model.removeReference(taskID: "T1", url: "https://example.com/a")
        XCTAssertTrue(model.detailsByTask["T1"]?.references.isEmpty ?? false)
    }

    func testDepthDeleteTaskAndPlanLocalEdits() async {
        let model = Self.depthModel()
        await model.load()
        XCTAssertEqual(model.tasks.count, 2)
        model.deleteTask(taskID: "T1")
        XCTAssertEqual(model.tasks.map(\.taskId), ["T2"])
        model.deleteTask(taskID: "T1") // unknown: ignored
        XCTAssertEqual(model.tasks.count, 1)
        let before = model.plans.count
        model.createPlan(teamID: "G1", title: "  New board  ")
        XCTAssertEqual(model.plans.count, before + 1)
        XCTAssertEqual(model.selectedPlanID, model.plans.last?.planId)
        model.createPlan(teamID: "G1", title: "   ") // ignored
        XCTAssertEqual(model.plans.count, before + 1)
        let created = model.plans.last!.planId
        model.deletePlan(planID: created)
        XCTAssertEqual(model.plans.count, before)
        XCTAssertEqual(model.selectedPlanID, "P1")
        model.deletePlan(planID: "nope") // unknown: ignored
        XCTAssertEqual(model.plans.count, before)
    }

    func testDepthCommentsLocalEdits() async {
        let model = Self.depthModel()
        await model.load()
        // Demo task T1 has no thread: fixture comments keyed by task.
        model.loadDetails(taskID: "T1")
        XCTAssertNotNil(model.commentsByThread["T1"])
        // A threaded task posts into its thread.
        let threaded = PlannerTask(
            taskId: "T1", planId: "P1", bucketId: "B1", title: "Ship it",
            percent: 50, etag: "W/\"e1\"", threadID: "thread-1")
        let threadedModel = PlannerViewModel(
            teamsFetcher: { Self.teamsJSON() },
            plansFetcher: { _ in Self.plansJSON() },
            bucketsFetcher: { _ in Self.bucketsJSON() },
            tasksFetcher: { _ in PlannerTasksResponse(ok: true, plan_id: "P1", tasks: [threaded]) },
            localEdits: true)
        await threadedModel.load()
        threadedModel.loadDetails(taskID: "T1")
        XCTAssertTrue(threadedModel.commentsByThread["thread-1"]?.isEmpty ?? false)
        threadedModel.postComment(taskID: "T1", text: "  looks good  ")
        XCTAssertEqual(threadedModel.commentsByThread["thread-1"]?.map(\.content), ["looks good"])
        threadedModel.postComment(taskID: "T1", text: "   ") // ignored
        XCTAssertEqual(threadedModel.commentsByThread["thread-1"]?.count, 1)
        threadedModel.postComment(taskID: "nope", text: "x") // unknown task: ignored
    }

    // MARK: - Depth ViewModel (mock fetchers)

    func testSetLabelCallsFetcherAndAdopts() async {
        let model = PlannerViewModel(
            teamsFetcher: { Self.teamsJSON() },
            plansFetcher: { _ in Self.plansJSON() },
            bucketsFetcher: { _ in Self.bucketsJSON() },
            tasksFetcher: { _ in Self.tasksJSON() },
            labelsFetcher: { taskID, _, category, on in
                var task = Self.tasksJSON().tasks[0]
                task = PlannerTask(
                    taskId: task.taskId, planId: task.planId, bucketId: task.bucketId,
                    title: task.title, percent: task.percent, completed: task.completed,
                    priority: task.priority, due: task.due, etag: "W/\"e2\"",
                    assignees: task.assignees, labels: on ? [category] : [])
                return PlannerTaskResult(ok: true, task: task)
            })
        await model.load()
        XCTAssertTrue(model.tasks[0].labels.isEmpty)
        model.setLabel(taskID: "T1", category: 2, on: true)
        await waitFor { model.tasks[0].labels == [2] }
        XCTAssertNil(model.boardError)
        model.setLabel(taskID: "T1", category: 2, on: true) // no-op, no refetch
    }

    func testSetLabelErrorSurfaces() async {
        let model = PlannerViewModel(
            teamsFetcher: { Self.teamsJSON() },
            plansFetcher: { _ in Self.plansJSON() },
            bucketsFetcher: { _ in Self.bucketsJSON() },
            tasksFetcher: { _ in Self.tasksJSON() },
            labelsFetcher: { _, _, _, _ in throw CoreCallError.failed("stale etag") })
        await model.load()
        model.setLabel(taskID: "T1", category: 1, on: true)
        await waitFor { model.boardError != nil }
        XCTAssertEqual(model.boardError, "stale etag")
        XCTAssertTrue(model.tasks[0].labels.isEmpty)
    }

    func testDemoFixturesCarryDepth() {
        XCTAssertEqual(PlannerDemo.categories(for: "demo-plan-sprint"), [1: "Design", 2: "Beta", 3: "Docs"])
        XCTAssertTrue(PlannerDemo.categories(for: "nope").isEmpty)
        let sprint = PlannerDemo.tasks(for: "demo-plan-sprint")
        XCTAssertTrue(sprint.contains { $0.labels == [1, 2] })
        XCTAssertTrue(sprint.contains { $0.labels.isEmpty })
        let details = PlannerDemo.details(for: "demo-ptask-2")
        XCTAssertEqual(details.checklist.count, 3)
        XCTAssertFalse(details.description.isEmpty)
        XCTAssertTrue(PlannerDemo.details(for: "nope").checklist.isEmpty)
        XCTAssertEqual(PlannerDemo.comments(for: "demo-ptask-2").count, 2)
        XCTAssertTrue(PlannerDemo.comments(for: "nope").isEmpty)
    }

    // MARK: - Launch-r2 dedup

    /// One load fetches each team's plans once: the selected team's
    /// list is adopted from loadAllPlans, not fetched a second time.
    func testLoadReusesPlansForSelectedTeam() async {
        let teamsFetches = LockedBox(0)
        let plansFetches = LockedBox(0)
        let model = PlannerViewModel(
            teamsFetcher: {
                teamsFetches.mutate { $0 += 1 }
                return Self.teamsJSON()
            },
            plansFetcher: { id in
                plansFetches.mutate { $0 += 1 }
                return PlannerPlansResponse(ok: true, group_id: id, plans: Self.plansJSON().plans)
            },
            bucketsFetcher: { _ in Self.bucketsJSON() },
            tasksFetcher: { _ in Self.tasksJSON() })
        await model.load()
        // Two teams: loadAllPlans fetches both; the selected team's
        // re-fetch is skipped (was N+1 = 3).
        XCTAssertEqual(teamsFetches.value, 1)
        XCTAssertEqual(plansFetches.value, 2)
        XCTAssertEqual(model.selectedTeamID, "G1")
        XCTAssertEqual(model.plans.count, 2)
        XCTAssertEqual(model.selectedPlanID, "P1")
        XCTAssertFalse(model.boardLoading)
    }

    /// Concurrent loads share one fetch (launch + sign-in/account
    /// paths fire together): teams and plans each fetched once.
    func testConcurrentLoadSharesOneFetch() async {
        let teamsFetches = LockedBox(0)
        let model = PlannerViewModel(
            teamsFetcher: {
                teamsFetches.mutate { $0 += 1 }
                Thread.sleep(forTimeInterval: 0.3)
                return Self.teamsJSON()
            },
            plansFetcher: { id in PlannerPlansResponse(ok: true, group_id: id, plans: []) },
            bucketsFetcher: { _ in Self.bucketsJSON() },
            tasksFetcher: { _ in Self.tasksJSON() })
        let loads = (0 ..< 3).map { _ in Task { await model.load() } }
        for load in loads { await load.value }
        XCTAssertEqual(teamsFetches.value, 1)
        XCTAssertEqual(model.state, .loaded)
    }
}
