// RemindersViewModel.swift — loads To Do lists/tasks via ostmac-core.
import Combine
import Foundation

/// Lists content state (mirrors TeamsState).
public enum RemindersState: Equatable, Sendable {
    /// Fetch in flight.
    case loading
    /// Non-empty list in `lists`.
    case loaded
    /// Fetch succeeded with zero lists.
    case empty
    /// Fetch failed; associated user-facing message.
    case error(String)
}

/// Loads the To Do lists off the main thread, owns list selection and the
/// selected list's tasks. Default fetchers call `RustCore.reminder*`
/// (blocking FFI + network) on detached tasks. Tests inject mock fetchers.
/// `localEdits` (demo mode) applies add/complete to the in-memory rows
/// instead of calling core, so `--demo` stays fully offline.
@MainActor
public final class RemindersViewModel: ObservableObject {
    /// Sync fetch (runs off-main). Throws `CoreCallError` on core failure.
    public typealias ListsFetcher = @Sendable () throws -> RemindersResponse
    public typealias TasksFetcher = @Sendable (String) throws -> ReminderTasksResponse
    public typealias AddFetcher = @Sendable (String, String) throws -> ReminderTaskResult
    public typealias DoneFetcher = @Sendable (String, String) throws -> ReminderTaskResult

    /// Latest lists (only meaningful in `.loaded`; stale otherwise).
    @Published public private(set) var lists: [ReminderList] = []
    /// Current lists state. Starts `.loading`.
    @Published public private(set) var state: RemindersState = .loading
    /// Selected list id (first list after load; nil when empty).
    @Published public private(set) var selectedListID: String?
    /// Tasks of the selected list.
    @Published public private(set) var tasks: [ReminderTask] = []
    /// Tasks fetch in flight.
    @Published public private(set) var tasksLoading = false
    /// Last tasks/add/complete failure (user-facing); nil when clear.
    @Published public private(set) var tasksError: String?
    /// List the list pane selected (`show(listID:)`). A (re)load keeps
    /// it instead of falling back to the first list.
    public private(set) var requestedListID: String?

    private let listsFetcher: ListsFetcher
    private let tasksFetcher: TasksFetcher
    private let addFetcher: AddFetcher
    private let doneFetcher: DoneFetcher
    private let localEdits: Bool

    public init(
        listsFetcher: @escaping ListsFetcher = { try RustCore.reminders() },
        tasksFetcher: @escaping TasksFetcher = { try RustCore.reminderTasks(listID: $0) },
        addFetcher: @escaping AddFetcher = { try RustCore.reminderAdd(listID: $0, title: $1) },
        doneFetcher: @escaping DoneFetcher = { try RustCore.reminderDone(listID: $0, taskID: $1) },
        localEdits: Bool = false
    ) {
        self.listsFetcher = listsFetcher
        self.tasksFetcher = tasksFetcher
        self.addFetcher = addFetcher
        self.doneFetcher = doneFetcher
        self.localEdits = localEdits
    }

    /// Fetch lists, select the first, fetch its tasks.
    public func load() async {
        state = .loading
        tasksError = nil
        let fetcher = listsFetcher
        do {
            let response = try await Task.detached {
                try fetcher()
            }.value
            lists = response.lists
            state = response.lists.isEmpty ? .empty : .loaded
            selectedListID = response.lists.first { $0.id == requestedListID }?.id
                ?? response.lists.first?.id
            if let id = selectedListID {
                await loadTasks(listID: id)
            } else {
                tasks = []
            }
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Fire-and-forget reload (error-state Retry, sign-in).
    public func refresh() {
        Task { await load() }
    }

    /// Select another list and fetch its tasks.
    public func select(listID: String) {
        guard listID != selectedListID else { return }
        selectedListID = listID
        Task { await loadTasks(listID: listID) }
    }

    /// Show one list's tasks (list pane selection). Nil clears the
    /// request only. Repeats are no-ops.
    public func show(listID: String?) {
        requestedListID = listID
        guard let listID else { return }
        select(listID: listID)
    }

    /// Refresh the selected list's tasks.
    public func refreshTasks() {
        guard let id = selectedListID else { return }
        Task { await loadTasks(listID: id) }
    }

    /// Open tasks, newest last (Graph returns oldest-first already; this
    /// only drops completed rows when `hideDone` is set).
    public nonisolated static func visible(_ tasks: [ReminderTask], hideDone: Bool) -> [ReminderTask] {
        hideDone ? tasks.filter { !$0.completed } : tasks
    }

    /// Add a task to the selected list. Empty titles are ignored.
    public func add(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = selectedListID else { return }
        if localEdits {
            tasks.append(ReminderTask(
                taskId: "demo-task-local-\(tasks.count + 1)", title: trimmed))
            tasksError = nil
            return
        }
        let fetcher = addFetcher
        tasksError = nil
        Task.detached { [weak self] in
            do {
                let created = try fetcher(id, trimmed)
                await MainActor.run { [weak self] in
                    self?.tasks.append(created.task)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.tasksError = Self.message(for: error)
                }
            }
        }
    }

    /// Mark a task completed (idempotent on the server; locally it flips
    /// the row once). No-op when the row is already done or demo-local.
    public func complete(taskID: String) {
        guard let id = selectedListID,
              let idx = tasks.firstIndex(where: { $0.taskId == taskID }),
              !tasks[idx].completed
        else { return }
        if localEdits {
            let row = tasks[idx]
            tasks[idx] = ReminderTask(
                taskId: row.taskId, title: row.title, status: "completed",
                importance: row.importance, due: row.due,
                reminder: row.reminder, completed: true)
            return
        }
        let fetcher = doneFetcher
        tasksError = nil
        Task.detached { [weak self] in
            do {
                let updated = try fetcher(id, taskID)
                await MainActor.run { [weak self] in
                    guard let self,
                          let i = self.tasks.firstIndex(where: { $0.taskId == taskID })
                    else { return }
                    self.tasks[i] = updated.task
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.tasksError = Self.message(for: error)
                }
            }
        }
    }

    private func loadTasks(listID: String) async {
        tasksLoading = true
        tasksError = nil
        let fetcher = tasksFetcher
        do {
            let response = try await Task.detached {
                try fetcher(listID)
            }.value
            // Selection may have moved while fetching; only adopt when fresh.
            if listID == selectedListID {
                tasks = response.tasks
            }
        } catch {
            if listID == selectedListID {
                tasksError = Self.message(for: error)
            }
        }
        if listID == selectedListID {
            tasksLoading = false
        }
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}
