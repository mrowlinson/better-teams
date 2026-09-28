// ToDoViews.swift — To Do lists, tasks and pane states (UI-SPEC §6.7,
// §6 row conventions, R18 pane states).
import OstMacCore
import SwiftUI

// MARK: states

/// What the lists pane shows. Titles state the condition (R18).
enum ToDoListState: Equatable {
    case loading
    case error(title: String, message: String)
    case empty
    case lists

    static let emptyTitle = "No Lists"
    static let emptyMessage = "Your To Do lists appear here."
    static let errorTitle = "Couldn\u{2019}t Load Lists"
    static let offlineTitle = "You\u{2019}re Offline"
    static let offlineMessage = "Your lists appear when you\u{2019}re back online."

    /// R12: lists on screen are never replaced by a spinner or error.
    static func resolve(_ state: RemindersState, listCount: Int, forced: ForcedPaneState?,
                        offline: Bool) -> ToDoListState {
        func failed(_ m: String) -> ToDoListState {
            offline ? .error(title: offlineTitle, message: offlineMessage) : .error(title: errorTitle, message: m)
        }
        switch forced {
        case .loading: return .loading
        case .empty: return .empty
        case .error: return failed("Something went wrong.")
        case nil: break
        }
        if listCount > 0 { return .lists }
        switch state {
        case .loading: return .loading
        case .error(let m): return failed(m)
        case .empty, .loaded: return .empty
        }
    }
}

/// What the tasks pane shows.
enum ToDoTasksState: Equatable {
    case noSelection
    case loading
    case error(title: String, message: String)
    case tasks

    static let noSelectionTitle = "No List Selected"
    static let errorTitle = "Couldn\u{2019}t Load Tasks"

    /// The add field stays usable on an empty list, so an empty list is
    /// `.tasks` with a "No Tasks" line, never a blank pane. While a
    /// list's tasks load, the rows on hand may be another list's, so
    /// loading always wins.
    static func resolve(listSelected: Bool, showing: Bool, loading: Bool, error: String?,
                        taskCount: Int, offline: Bool) -> ToDoTasksState {
        guard listSelected else { return .noSelection }
        guard showing, !loading else { return .loading }
        if taskCount == 0, let error {
            return offline
                ? .error(title: ToDoListState.offlineTitle, message: ToDoListState.offlineMessage)
                : .error(title: errorTitle, message: error)
        }
        return .tasks
    }
}

enum ToDoFormat {
    /// Graph To Do `dueDateTime.dateTime` ("2026-09-23T10:00:00.0000000",
    /// zone carried separately): To Do due dates are days, so only the
    /// date part counts, read in the local calendar.
    static func dueDate(_ raw: String?, calendar: Calendar = .current) -> Date? {
        guard let raw, raw.count >= 10 else { return nil }
        let parts = raw.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func isOverdue(_ task: ReminderTask, now: Date, calendar: Calendar = .current) -> Bool {
        guard !task.completed, let d = dueDate(task.due, calendar: calendar) else { return false }
        return d < calendar.startOfDay(for: now)
    }

    static func isImportant(_ task: ReminderTask) -> Bool {
        task.importance.caseInsensitiveCompare("high") == .orderedSame
    }
}

// MARK: lists

struct ToDoListPane: View {
    @ObservedObject var reminders: RemindersViewModel
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            let state = ToDoListState.resolve(
                reminders.state, listCount: reminders.lists.count,
                forced: model.forced(.native(.todo)), offline: model.connection == .offline)
            switch state {
            case .loading: LoadingPane()
            case .error(let title, let message):
                ErrorPane(title: title, message: message) { reminders.refresh() }
            case .empty:
                EmptyPane(ToDoListState.emptyTitle, systemImage: NativeAppID.todo.symbol,
                          message: ToDoListState.emptyMessage)
            case .lists: list(model)
            }
        }
    }

    private func list(_ m: WindowModel) -> some View {
        let selection = Binding<String?>(
            get: { ToDoSection.listID(m) },
            set: { ToDoSection.selectList($0, m) })
        return List(reminders.lists, selection: selection) { list in
            Label(list.name, systemImage: "list.bullet")
                .lineLimit(1)
                .tag(list.listId)
        }
        .listStyle(.inset)
    }
}

// MARK: tasks

/// The list's tasks (§6.7): add field on top, checkbox rows, Show
/// Completed toggle. Completed tasks hide unless Show Completed is on.
struct ToDoTasksPane: View {
    @ObservedObject var reminders: RemindersViewModel
    @ObservedObject var viewState: ToDoViewState
    @Environment(\.windowModel) private var model
    @State private var draft = ""

    var body: some View {
        if let model {
            let listID = model.forced(.native(.todo)) == nil ? ToDoSection.listID(model) : nil
            let state = ToDoTasksState.resolve(
                listSelected: listID != nil, showing: listID != nil && reminders.selectedListID == listID,
                loading: reminders.tasksLoading, error: reminders.tasksError,
                taskCount: reminders.tasks.count, offline: model.connection == .offline)
            switch state {
            case .noSelection: NoSelectionPane(ToDoTasksState.noSelectionTitle)
            case .loading: LoadingPane()
            case .error(let title, let message):
                ErrorPane(title: title, message: message) { reminders.refreshTasks() }
            case .tasks: tasks
            }
        }
    }

    private var tasks: some View {
        let now = RelativeClock.shared.now
        let rows = RemindersViewModel.visible(reminders.tasks, hideDone: !viewState.showCompleted)
        let hiddenCount = reminders.tasks.count - rows.count
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                AddTaskField(text: $draft) {
                    reminders.add(title: draft)
                    draft = ""
                }
                Toggle("Show Completed", isOn: $viewState.showCompleted)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            if let error = reminders.tasksError {
                // An add / complete failure with rows still on screen (R12).
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            Divider()
            if rows.isEmpty {
                EmptyPane(hiddenCount > 0 ? "No Open Tasks" : "No Tasks", systemImage: NativeAppID.todo.symbol,
                          message: hiddenCount > 0 ? "Completed tasks are hidden." : "Add a task above.")
            } else {
                List(rows) { task in
                    ToDoTaskRow(task: task, now: now) { reminders.complete(taskID: task.taskId) }
                        .contextMenu {
                            Button("Mark as Complete") { reminders.complete(taskID: task.taskId) }
                                .disabled(task.completed)
                        }
                }
                .listStyle(.inset)
            }
        }
    }
}

/// Task row: checkbox (complete), importance mark, title, due date. The
/// service call reopens nothing, so a completed row's box is read-only.
struct ToDoTaskRow: View {
    let task: ReminderTask
    let now: Date
    let complete: () -> Void
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(isOn: Binding(get: { task.completed }, set: { if $0 { complete() } })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(task.completed)
            .accessibilityLabel(task.completed ? "Completed" : "Not completed")
            if ToDoFormat.isImportant(task) {
                Image(systemName: "exclamationmark")
                    .font(AppFont.bodyEmphasized(scale))
                    .foregroundStyle(.red)
                    .accessibilityLabel("Important")
            }
            Text(task.title)
                .font(AppFont.body(scale))
                .foregroundStyle(task.completed ? .secondary : .primary)
                .strikethrough(task.completed)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let due = ToDoFormat.dueDate(task.due) {
                Text(PlannerFormat.due(due, now: now))
                    .font(AppFont.subheadline(scale))
                    .monospacedDigit()
                    .foregroundStyle(ToDoFormat.isOverdue(task, now: now) ? AnyShapeStyle(.red)
                                                                          : AnyShapeStyle(.secondary))
                    .accessibilityLabel("Due \(PlannerFormat.due(due, now: now))")
            }
        }
        .padding(.vertical, 2)
    }
}
