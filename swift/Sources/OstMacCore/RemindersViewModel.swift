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
/// `localEdits` (demo mode) applies add/complete/reopen to the in-memory rows
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
    @Published public private(set) var tasks: [ReminderTask] = [] {
        didSet { if let id = tasksListID { taskCache[id] = tasks } }
    }
    /// The list `tasks` belongs to (nil before any list's tasks land). A
    /// reload of that list keeps its rows on screen.
    @Published public private(set) var tasksListID: String?
    /// Rows per list seen this session: switching back shows them at
    /// once while the list refreshes behind.
    private var taskCache: [String: [ReminderTask]] = [:]
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
    private let reopenFetcher: DoneFetcher
    private let localEdits: Bool

    public init(
        listsFetcher: @escaping ListsFetcher = { try RustCore.reminders() },
        tasksFetcher: @escaping TasksFetcher = { try RustCore.reminderTasks(listID: $0) },
        addFetcher: @escaping AddFetcher = { try RustCore.reminderAdd(listID: $0, title: $1) },
        doneFetcher: @escaping DoneFetcher = { try RustCore.reminderDone(listID: $0, taskID: $1) },
        reopenFetcher: @escaping DoneFetcher = { try RustCore.reminderReopen(listID: $0, taskID: $1) },
        localEdits: Bool = false
    ) {
        self.listsFetcher = listsFetcher
        self.tasksFetcher = tasksFetcher
        self.addFetcher = addFetcher
        self.doneFetcher = doneFetcher
        self.reopenFetcher = reopenFetcher
        self.localEdits = localEdits
    }

    /// NOLOAD: last-good snapshot store (nil = memory only / demo).
    public var snapshots: SectionCache?
    static let snapshotKey = "todo"

    struct Snapshot: Codable {
        let lists: [ReminderList]
        let tasks: [String: [ReminderTask]]
        let selected: String?
    }

    /// Paint the last good lists + per-list tasks before any fetch.
    @discardableResult
    public func restoreSnapshot() -> Bool {
        guard let snap = snapshots?.load(Snapshot.self, key: Self.snapshotKey),
              !snap.lists.isEmpty else { return false }
        lists = snap.lists
        taskCache = snap.tasks
        selectedListID = snap.lists.first { $0.id == (requestedListID ?? snap.selected) }?.id
            ?? snap.lists.first?.id
        if let id = selectedListID, let rows = snap.tasks[id] {
            tasksListID = id
            tasks = rows
        }
        state = .loaded
        return true
    }

    private func saveSnapshot() {
        guard let snapshots, !lists.isEmpty else { return }
        let known = Set(lists.map(\.id))
        snapshots.save(Snapshot(lists: lists, tasks: taskCache.filter { known.contains($0.key) },
                                selected: selectedListID), key: Self.snapshotKey)
    }

    /// Fetch lists, select the first, fetch its tasks.
    public func load() async {
        state = .loading
        tasksError = nil
        let fetcher = listsFetcher
        do {
            let response = try await Task.blocking {
                try fetcher()
            }.value
            lists = response.lists
            state = response.lists.isEmpty ? .empty : .loaded
            selectedListID = response.lists.first { $0.id == requestedListID }?.id
                ?? response.lists.first?.id
            if let id = selectedListID {
                await loadTasks(listID: id)
            } else {
                tasksListID = nil
                tasks = []
            }
            saveSnapshot()
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
        if let cached = taskCache[listID] {
            tasksListID = listID
            tasks = cached
        }
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
        Task.blocking { [weak self] in
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
    /// the row once). No-op when the row is already done.
    public func complete(taskID: String) {
        setCompleted(true, taskID: taskID)
    }

    /// Reopen a completed task (status back to not started). No-op when
    /// the row is already open.
    public func reopen(taskID: String) {
        setCompleted(false, taskID: taskID)
    }

    private func setCompleted(_ done: Bool, taskID: String) {
        guard let id = selectedListID,
              let idx = tasks.firstIndex(where: { $0.taskId == taskID }),
              tasks[idx].completed != done
        else { return }
        if localEdits {
            let row = tasks[idx]
            tasks[idx] = ReminderTask(
                taskId: row.taskId, title: row.title, status: done ? "completed" : "notStarted",
                importance: row.importance, due: row.due,
                reminder: row.reminder, completed: done)
            return
        }
        let fetcher = done ? doneFetcher : reopenFetcher
        tasksError = nil
        Task.blocking { [weak self] in
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
            let response = try await Task.blocking {
                try fetcher(listID)
            }.value
            // Selection may have moved while fetching; only adopt when fresh.
            if listID == selectedListID {
                tasksListID = listID
                tasks = response.tasks
            } else {
                taskCache[listID] = response.tasks
            }
            saveSnapshot()
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
        FriendlyError.message(for: error)
    }
}
