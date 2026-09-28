// AlignTests.swift — om-align: sidebar reload entry points stay working
// after the window-toolbar Refresh buttons were removed (Retry/resync/
// sign-in callers keep using them).
import XCTest

@testable import OstMacCore

/// Sendable call counter for mock fetchers (detached-task boundary).
private final class CallBox: @unchecked Sendable {
    var count = 0
}

@MainActor
final class AlignTests: XCTestCase {
    func testChatsRefreshReloads() async {
        let calls = CallBox()
        let model = ChatListViewModel(fetcher: { _ in
            calls.count += 1
            return ChatListTests.chatsJSON(
                ChatListTests.chatJSON(
                    id: "8:b", name: "Solo \(calls.count)"))
        })
        await model.load()
        XCTAssertEqual(model.chats.first?.name, "Solo 1")
        model.refresh()
        await waitFor { calls.count == 2 }
        await waitFor { model.chats.first?.name == "Solo 2" }
        XCTAssertEqual(model.state, .loaded)
    }

    func testTeamsRefreshReloads() async {
        let calls = CallBox()
        let model = TeamsViewModel(fetcher: {
            calls.count += 1
            let json = """
                {"ok":true,"teams":[\
                {"id":"team-1","name":"E\(calls.count)","channels":[]}]}
                """
            return try! decodeOrThrow(
                TeamsResponse.self, from: Data(json.utf8))
        })
        await model.load()
        XCTAssertEqual(model.teams.first?.name, "E1")
        model.refresh()
        await waitFor { calls.count == 2 }
        await waitFor { model.teams.first?.name == "E2" }
        XCTAssertEqual(model.state, .loaded)
    }

    func testRemindersRefreshReloads() async {
        let calls = CallBox()
        let tasks = RemindersTests.tasksJSON()
        let model = RemindersViewModel(
            listsFetcher: {
                calls.count += 1
                return RemindersTests.listsJSON()
            },
            tasksFetcher: { _ in tasks })
        await model.load()
        XCTAssertEqual(calls.count, 1)
        model.refresh()
        await waitFor { calls.count == 2 }
        await waitFor { model.state == .loaded }
        XCTAssertEqual(model.selectedListID, "L1")
    }

    func testRemindersRefreshTasksRefetchesSelected() async {
        let calls = CallBox()
        let lists = RemindersTests.listsJSON()
        let model = RemindersViewModel(
            listsFetcher: { lists },
            tasksFetcher: { id in
                calls.count += 1
                return ReminderTasksResponse(
                    ok: true, list_id: id,
                    tasks: [ReminderTask(taskId: "t-\(calls.count)", title: "n")])
            })
        await model.load()
        XCTAssertEqual(model.tasks.first?.taskId, "t-1")
        model.refreshTasks()
        await waitFor { calls.count == 2 }
        await waitFor { model.tasks.first?.taskId == "t-2" }
        XCTAssertFalse(model.tasksLoading)
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
