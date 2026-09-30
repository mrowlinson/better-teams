// RemindersTests.swift — om-remind lane: wire decode, ViewModel, filter.
import XCTest

@testable import OstMacCore

@MainActor
final class RemindersTests: XCTestCase {
    // MARK: - Fixtures

    nonisolated static func listsJSON() -> RemindersResponse {
        let json = """
            {"ok":true,"lists":[\
            {"id":"L1","name":"Tasks","wellknown":"defaultList"},\
            {"id":"L2","name":"Groceries","wellknown":null}]}
            """
        return try! decodeOrThrow(RemindersResponse.self, from: Data(json.utf8))
    }

    nonisolated static func tasksJSON() -> ReminderTasksResponse {
        let json = """
            {"ok":true,"list_id":"L1","tasks":[\
            {"id":"T1","title":"Buy milk","status":"notStarted",\
            "importance":"high","due":"2030-05-04T12:00:00.0000000",\
            "reminder":null,"completed":false},\
            {"id":"T2","title":"Done thing","status":"completed",\
            "importance":"normal","due":null,"reminder":null,"completed":true}]}
            """
        return try! decodeOrThrow(ReminderTasksResponse.self, from: Data(json.utf8))
    }

    nonisolated static func taskResultJSON() -> ReminderTaskResult {
        let json = """
            {"ok":true,"task":{"id":"T9","title":"New","status":"notStarted",\
            "importance":"normal","due":null,"reminder":null,"completed":false}}
            """
        return try! decodeOrThrow(ReminderTaskResult.self, from: Data(json.utf8))
    }

    // MARK: - Wire decode

    func testDecodeLists() {
        let response = Self.listsJSON()
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.lists.count, 2)
        XCTAssertEqual(response.lists[0].id, "L1")
        XCTAssertEqual(response.lists[0].name, "Tasks")
        XCTAssertEqual(response.lists[0].wellknown, "defaultList")
        XCTAssertNil(response.lists[1].wellknown)
    }

    func testDecodeTasks() {
        let response = Self.tasksJSON()
        XCTAssertEqual(response.list_id, "L1")
        XCTAssertEqual(response.tasks.count, 2)
        XCTAssertEqual(response.tasks[0].id, "T1")
        XCTAssertEqual(response.tasks[0].title, "Buy milk")
        XCTAssertEqual(response.tasks[0].status, "notStarted")
        XCTAssertEqual(response.tasks[0].importance, "high")
        XCTAssertFalse(response.tasks[0].completed)
        XCTAssertTrue(response.tasks[1].completed)
        // Routes through ChatMessage rules (local + locale clock; exact
        // pins live in FidTimeTests with explicit zone/locale).
        XCTAssertEqual(
            response.tasks[0].displayDue,
            ChatMessage.shortTime("2030-05-04T12:00:00.0000000"))
        XCTAssertNil(response.tasks[1].displayDue)
    }

    func testDecodeTaskResult() {
        let result = Self.taskResultJSON()
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.task.id, "T9")
        XCTAssertEqual(result.task.title, "New")
    }

    func testErrorEnvelopeThrows() {
        let json = #"{"ok":false,"error":"reminders","detail":"nope"}"#
        XCTAssertThrowsError(
            try decodeOrThrow(RemindersResponse.self, from: Data(json.utf8)))
        XCTAssertThrowsError(
            try decodeOrThrow(ReminderTasksResponse.self, from: Data(json.utf8)))
    }

    // MARK: - ViewModel states

    func testLoadSelectsFirstAndLoadsTasks() async {
        let lists = Self.listsJSON()
        let tasks = Self.tasksJSON()
        let model = RemindersViewModel(
            listsFetcher: { lists },
            tasksFetcher: { _ in tasks })
        XCTAssertEqual(model.state, .loading)
        await model.load()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.lists.count, 2)
        XCTAssertEqual(model.selectedListID, "L1")
        XCTAssertEqual(model.tasks.count, 2)
        XCTAssertFalse(model.tasksLoading)
        XCTAssertNil(model.tasksError)
    }

    func testLoadEmpty() async {
        let model = RemindersViewModel(
            listsFetcher: { RemindersResponse(ok: true, lists: []) },
            tasksFetcher: { id in
                ReminderTasksResponse(ok: true, list_id: id, tasks: [])
            })
        await model.load()
        XCTAssertEqual(model.state, .empty)
        XCTAssertNil(model.selectedListID)
        XCTAssertTrue(model.tasks.isEmpty)
    }

    func testLoadError() async {
        let model = RemindersViewModel(
            listsFetcher: { () -> RemindersResponse in
                throw CoreCallError.failed("boom")
            },
            tasksFetcher: { id in
                ReminderTasksResponse(ok: true, list_id: id, tasks: [])
            })
        await model.load()
        XCTAssertEqual(model.state, .error("boom"))
    }

    func testSelectSwitchesTasks() async {
        let lists = Self.listsJSON()
        let model = RemindersViewModel(
            listsFetcher: { lists },
            tasksFetcher: { id in
                ReminderTasksResponse(
                    ok: true, list_id: id,
                    tasks: [ReminderTask(taskId: "t-\(id)", title: "in \(id)")])
            })
        await model.load()
        XCTAssertEqual(model.selectedListID, "L1")
        XCTAssertEqual(model.tasks.first?.taskId, "t-L1")
        model.select(listID: "L2")
        await waitFor { model.tasks.first?.taskId == "t-L2" }
        XCTAssertEqual(model.selectedListID, "L2")
        XCTAssertFalse(model.tasksLoading)
    }

    func testTasksErrorSurfaces() async {
        let lists = Self.listsJSON()
        let model = RemindersViewModel(
            listsFetcher: { lists },
            tasksFetcher: { _ -> ReminderTasksResponse in
                throw CoreCallError.failed("tasks down")
            })
        await model.load()
        XCTAssertEqual(model.state, .loaded) // lists fine, tasks failed
        XCTAssertEqual(model.tasksError, "tasks down")
        XCTAssertFalse(model.tasksLoading)
    }

    // MARK: - Add / complete (mock fetchers)

    func testAddAppendsCreated() async {
        let model = RemindersViewModel(
            listsFetcher: { Self.listsJSON() },
            tasksFetcher: { _ in Self.tasksJSON() },
            addFetcher: { _, title in
                ReminderTaskResult(
                    ok: true,
                    task: ReminderTask(taskId: "T-new", title: title))
            })
        await model.load()
        XCTAssertEqual(model.tasks.count, 2)
        model.add(title: "  file taxes  ")
        await waitFor { model.tasks.count == 3 }
        XCTAssertEqual(model.tasks.last?.title, "file taxes")
        XCTAssertNil(model.tasksError)
    }

    func testAddEmptyTitleIgnored() async {
        let model = RemindersViewModel(
            listsFetcher: { Self.listsJSON() },
            tasksFetcher: { _ in Self.tasksJSON() },
            addFetcher: { _, _ in Self.taskResultJSON() })
        await model.load()
        model.add(title: "   ")
        XCTAssertEqual(model.tasks.count, 2) // sync no-op, no wait needed
    }

    func testCompleteFlipsRow() async {
        let model = RemindersViewModel(
            listsFetcher: { Self.listsJSON() },
            tasksFetcher: { _ in Self.tasksJSON() },
            doneFetcher: { _, taskID in
                ReminderTaskResult(
                    ok: true,
                    task: ReminderTask(
                        taskId: taskID, title: "Buy milk",
                        status: "completed", completed: true))
            })
        await model.load()
        XCTAssertFalse(model.tasks[0].completed)
        model.complete(taskID: "T1")
        await waitFor { model.tasks[0].completed }
        XCTAssertEqual(model.tasks[0].status, "completed")
        // Already-done row: no fetcher call, no change.
        model.complete(taskID: "T2")
        XCTAssertTrue(model.tasks[1].completed)
    }

    func testCompleteErrorSurfaces() async {
        let model = RemindersViewModel(
            listsFetcher: { Self.listsJSON() },
            tasksFetcher: { _ in Self.tasksJSON() },
            doneFetcher: { _, _ -> ReminderTaskResult in
                throw CoreCallError.failed("patch denied")
            })
        await model.load()
        model.complete(taskID: "T1")
        await waitFor { model.tasksError != nil }
        XCTAssertEqual(model.tasksError, "patch denied")
        XCTAssertFalse(model.tasks[0].completed)
    }

    // MARK: - Local edits (demo mode)

    func testLocalEditsAddAndComplete() async {
        let model = RemindersViewModel(
            listsFetcher: { Self.listsJSON() },
            tasksFetcher: { _ in Self.tasksJSON() },
            localEdits: true)
        await model.load()
        model.add(title: "local task")
        XCTAssertEqual(model.tasks.count, 3) // sync in local mode
        XCTAssertEqual(model.tasks.last?.title, "local task")
        model.complete(taskID: "T1")
        XCTAssertTrue(model.tasks[0].completed)
        XCTAssertEqual(model.tasks[0].status, "completed")
    }

    // MARK: - Filter

    func testVisibleHideDone() {
        let tasks = Self.tasksJSON().tasks
        XCTAssertEqual(RemindersViewModel.visible(tasks, hideDone: false).count, 2)
        let open = RemindersViewModel.visible(tasks, hideDone: true)
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open[0].id, "T1")
    }

    // MARK: - Demo data

    func testDemoRemindersResponse() {
        let response = DemoData.remindersResponse()
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.lists.count, 2)
        for list in response.lists {
            XCTAssertFalse(DemoData.reminderTasks(for: list.id).isEmpty)
        }
        XCTAssertTrue(DemoData.reminderTasks(for: "nope").isEmpty)
        let tasks = DemoData.reminderTasksResponse(for: "demo-list-tasks")
        XCTAssertEqual(tasks.list_id, "demo-list-tasks")
        XCTAssertEqual(tasks.tasks.count, 3)
        // One completed row exercises the done styling + hide filter.
        XCTAssertEqual(tasks.tasks.filter(\.completed).count, 1)
    }

    // MARK: - Helpers

    /// Spin until `cond` holds (mock fetchers resolve in ms; hang-only ceiling).
    private func waitFor(
        _ cond: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        if await TestWait.until(cond) { return }
        XCTFail("timed out waiting for condition", file: file, line: line)
    }
}
