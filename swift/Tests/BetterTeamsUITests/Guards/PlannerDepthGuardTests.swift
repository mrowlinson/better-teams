// PlannerDepthGuardTests — plannerdepth lane: the depth surfaces stay
// wired. SwiftUI draws without AppKit nodes under xctest, so these
// drive the logic each control is bound to (the same statics and View
// Model methods the views call). Nothing is shown on screen.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class PlannerDepthGuardTests: XCTestCase {
    // MARK: Board / Charts / Schedule switcher

    func testBoardViewCasesAndTitles() {
        XCTAssertEqual(PlannerBoardView.allCases, [.board, .charts, .schedule])
        XCTAssertEqual(PlannerBoardView.board.title, "Board")
        XCTAssertEqual(PlannerBoardView.charts.title, "Charts")
        XCTAssertEqual(PlannerBoardView.schedule.title, "Schedule")
    }

    func testLabelPaletteDistinctAndNamed() {
        let colors = (1...6).map { PlannerFormat.labelColor($0) }
        XCTAssertEqual(Set(colors.map(\.description)).count, 6, "one color per label")
        let plan = PlannerPlan(planId: "P", title: "Sprint", categories: [1: "Design"])
        let task = PlannerTask(taskId: "T", title: "x", labels: [1, 4])
        XCTAssertEqual(PlannerFormat.labelNames(task, plan: plan), ["Design", "Label 4"])
        XCTAssertEqual(PlannerFormat.labelNames(task, plan: nil), ["Label 1", "Label 4"])
    }

    // MARK: Charts rows bind label names from the plan

    func testChartsRowNamesComeFromPlan() {
        let plan = PlannerPlan(planId: "P1", title: "Sprint", categories: [2: "Beta"])
        let tasks = [PlannerTask(taskId: "a", planId: "P1", bucketId: "B1", title: "A", labels: [2])]
        let (rows, _) = PlannerViewModel.chartRows(tasks, plan: plan)
        XCTAssertEqual(rows.map(\.name), ["Beta"])
        let (fallback, _) = PlannerViewModel.chartRows(tasks, plan: nil)
        XCTAssertEqual(fallback.map(\.name), ["Label 2"])
    }

    // MARK: Schedule groups never silently drop tasks

    func testScheduleGroupsCoverEveryTask() {
        let tasks = PlannerDemo.tasks(for: "demo-plan-sprint")
        let groups = PlannerViewModel.scheduleGroups(tasks, now: Date())
        XCTAssertEqual(groups.flatMap(\.tasks).count, tasks.count)
        XCTAssertTrue(groups.map(\.title).contains("No due date"))
    }

    // MARK: Commands stay registered (menu-bar parity)

    func testDepthCommandsRegistered() {
        let ids = PlannerCommands.all.map(\.id)
        XCTAssertTrue(ids.contains(PlannerCommands.toggleComplete))
        XCTAssertTrue(ids.contains(PlannerCommands.newPlan))
        XCTAssertFalse(ids.map(\.rawValue).contains(PlannerCommands.newPlanSheet),
                       "sheet names are not menu commands")
    }

    // MARK: Inspector delete keeps selection consistent

    nonisolated static func teamsJSON() -> TeamsResponse {
        let json = """
            {"ok":true,"teams":[{"id":"G1","name":"Engineering","channels":[]}]}
            """
        return try! decodeOrThrow(TeamsResponse.self, from: Data(json.utf8))
    }

    nonisolated static func boardJSON() -> (PlannerPlansResponse, PlannerBucketsResponse, PlannerTasksResponse) {
        let plans = """
            {"ok":true,"group_id":"G1","plans":[{"id":"P1","title":"Sprint"}]}
            """
        let buckets = """
            {"ok":true,"plan_id":"P1","buckets":[{"id":"B1","plan_id":"P1","name":"To do"}]}
            """
        let tasks = """
            {"ok":true,"plan_id":"P1","tasks":[\
            {"id":"T1","plan_id":"P1","bucket_id":"B1","title":"x",\
            "percent":0,"completed":false,"etag":"W/\\"e\\""}]}
            """
        return (
            try! decodeOrThrow(PlannerPlansResponse.self, from: Data(plans.utf8)),
            try! decodeOrThrow(PlannerBucketsResponse.self, from: Data(buckets.utf8)),
            try! decodeOrThrow(PlannerTasksResponse.self, from: Data(tasks.utf8)))
    }

    func testDeleteTaskDropsDetailsCache() async {
        let board = Self.boardJSON()
        let model = PlannerViewModel(
            teamsFetcher: { Self.teamsJSON() },
            plansFetcher: { _ in board.0 },
            bucketsFetcher: { _ in board.1 },
            tasksFetcher: { _ in board.2 },
            localEdits: true)
        await model.load()
        model.loadDetails(taskID: "T1")
        XCTAssertNotNil(model.detailsByTask["T1"])
        model.deleteTask(taskID: "T1")
        XCTAssertNil(model.detailsByTask["T1"])
        XCTAssertFalse(model.tasks.contains { $0.taskId == "T1" })
    }
}
