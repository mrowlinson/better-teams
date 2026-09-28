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

    /// Spin until `cond` holds (mock fetchers resolve in ms; 2s cap).
    private func waitFor(
        _ cond: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0 ..< 100 {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition not met in 2s", file: file, line: line)
    }
}
