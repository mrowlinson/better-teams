// PlannerViews.swift — Planner list, board and task inspector
// (UI-SPEC §6.7, §6 row conventions, R18 pane states).
import OstMacCore
import SwiftUI

// MARK: plans list

/// Plans grouped by team (§6.7), one `Section` per team with plans.
struct PlannerListPane: View {
    @ObservedObject var planner: PlannerViewModel
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            let groups = Self.groups(planner)
            let state = PlannerListState.resolve(
                planner.state, planCount: groups.reduce(0) { $0 + $1.plans.count },
                plansError: planner.plansError, forced: model.forced(.native(.planner)),
                offline: model.connection == .offline)
            switch state {
            case .loading: LoadingPane("Loading Plans\u{2026}")
            case .error(let title, let message):
                ErrorPane(title: title, message: message) { planner.refresh() }
            case .empty:
                EmptyPane(PlannerListState.emptyTitle, systemImage: NativeAppID.planner.symbol,
                          message: PlannerListState.emptyMessage)
            case .plans:
                // R12: a refresh runs behind the plans on screen.
                list(groups, model)
                    .refreshStatus(planner.state == .loading, failure: PlannerListState.failure(planner),
                                   label: "Updating Plans", retry: { planner.refresh() })
            }
        }
    }

    struct Group: Identifiable {
        let id: String
        let name: String
        let plans: [PlannerPlan]
    }

    /// Teams in list order, each with its plans; teams without plans drop.
    static func groups(_ planner: PlannerViewModel) -> [Group] {
        planner.teams.compactMap { team in
            guard let plans = planner.plansByTeam[team.teamId], !plans.isEmpty else { return nil }
            return Group(id: team.teamId, name: team.name, plans: plans)
        }
    }

    private func list(_ groups: [Group], _ m: WindowModel) -> some View {
        let selection = Binding<String?>(
            get: { PlannerSection.current(m).planID },
            set: { PlannerSection.selectPlan($0, m) })
        return List(selection: selection) {
            ForEach(groups) { group in
                Section(group.name) {
                    ForEach(group.plans) { plan in
                        Label(plan.title, systemImage: NativeAppID.planner.symbol)
                            .lineLimit(1)
                            .tag(plan.planId)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

// MARK: board

/// The selected plan as a List sectioned by bucket (§6.7): task rows,
/// then an Add Task field ending each section. Tasks in no known bucket
/// follow in Other Tasks (never silently dropped).
struct PlannerBoardPane: View {
    @ObservedObject var planner: PlannerViewModel
    @Environment(\.windowModel) private var model
    @State private var drafts: [String: String] = [:]

    var body: some View {
        if let model {
            let planID = model.forced(.native(.planner)) == nil ? PlannerSection.current(model).planID : nil
            let showing = planID != nil && planner.selectedPlanID == planID
            let state = PlannerBoardState.resolve(
                planSelected: planID != nil, showing: showing, loading: planner.boardLoading,
                error: planner.boardError, bucketCount: planner.buckets.count, taskCount: planner.tasks.count,
                offline: model.connection == .offline)
            switch state {
            case .noSelection: NoSelectionPane(PlannerBoardState.noSelectionTitle)
            case .loading: LoadingPane("Loading Board\u{2026}")
            case .error(let title, let message):
                ErrorPane(title: title, message: message) { planner.refreshBoard() }
            case .noBuckets:
                EmptyPane("No Buckets", systemImage: NativeAppID.planner.symbol,
                          message: "Add buckets to this plan in Planner to add tasks here.")
            case .board:
                board(model)
                    .refreshStatus(planner.boardLoading, failure: planner.boardError,
                                   label: "Updating Board", retry: { planner.refreshBoard() })
            }
        }
    }

    private func board(_ m: WindowModel) -> some View {
        let now = RelativeClock.shared.now
        let orphans = PlannerViewModel.orphaned(planner.tasks, buckets: planner.buckets)
        let selection = Binding<String?>(
            get: { PlannerSection.current(m).taskID },
            set: { PlannerSection.selectTask($0, m) })
        return List(selection: selection) {
            ForEach(planner.buckets) { bucket in
                Section(bucket.name) {
                    ForEach(PlannerViewModel.visible(planner.tasks, bucketID: bucket.bucketId, hideDone: false)) { task in
                        PlannerTaskRow(task: task, now: now, assignees: PlannerFormat.assignees(task, planner).map(\.name)) {
                            PlannerSection.toggle(task, planner)
                        }
                        .tag(task.taskId)
                    }
                    AddTaskField(text: draft(bucket.bucketId)) {
                        planner.add(bucketID: bucket.bucketId, title: drafts[bucket.bucketId] ?? "")
                        drafts[bucket.bucketId] = ""
                    }
                }
            }
            if !orphans.isEmpty {
                Section("Other Tasks") {
                    ForEach(orphans) { task in
                        PlannerTaskRow(task: task, now: now, assignees: PlannerFormat.assignees(task, planner).map(\.name)) {
                            PlannerSection.toggle(task, planner)
                        }
                        .tag(task.taskId)
                    }
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let task = planner.tasks.first(where: { $0.taskId == id }) {
                Button(task.completed ? "Mark as Incomplete" : "Mark as Complete") {
                    PlannerSection.toggle(task, planner)
                }
                AssignMenu(task: task, planner: planner)
            }
        } primaryAction: { ids in
            if let id = ids.first { PlannerSection.open(id, m) }
        }
    }

    private func draft(_ bucketID: String) -> Binding<String> {
        Binding(get: { drafts[bucketID] ?? "" }, set: { drafts[bucketID] = $0 })
    }
}

/// Task row (§6.7): checkbox (complete / reopen), title, due date; a
/// priority mark for Urgent and Important.
struct PlannerTaskRow: View {
    let task: PlannerTask
    let now: Date
    /// Assignee names, roster order of the task's ids.
    let assignees: [String]
    let toggle: () -> Void
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(isOn: Binding(get: { task.completed }, set: { _ in toggle() })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(task.completed ? "Completed" : "Not completed")
            if PlannerFormat.isFlagged(task.priority) {
                Image(systemName: "exclamationmark")
                    .font(AppFont.bodyEmphasized(scale))
                    .foregroundStyle(.red)
                    .accessibilityLabel(PlannerFormat.priority(task.priority))
            }
            Text(task.title)
                .font(AppFont.body(scale))
                .foregroundStyle(task.completed ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let who = PlannerFormat.assigneeSummary(assignees) {
                Label(who, systemImage: assignees.count > 1 ? "person.2" : "person")
                    .font(AppFont.subheadline(scale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(assignees.joined(separator: ", "))
                    .accessibilityLabel("Assigned to \(assignees.joined(separator: ", "))")
            }
            if let due = PlannerFormat.dueDate(task.due) {
                Text(PlannerFormat.due(due, now: now))
                    .font(AppFont.subheadline(scale))
                    .monospacedDigit()
                    .foregroundStyle(PlannerFormat.isOverdue(task, now: now) ? AnyShapeStyle(.red)
                                                                              : AnyShapeStyle(.secondary))
                    .accessibilityLabel("Due \(PlannerFormat.due(due, now: now))")
            }
        }
        .padding(.vertical, 2)
    }
}

/// Assign To menu (context menu and inspector): one checkable item per
/// member of the plan's team; choosing one assigns or unassigns.
struct AssignMenu: View {
    let task: PlannerTask
    @ObservedObject var planner: PlannerViewModel

    var body: some View {
        Menu("Assign To") {
            if planner.members.isEmpty {
                Text("No Team Members")
            }
            ForEach(planner.members) { member in
                Toggle(member.name, isOn: Binding(
                    get: { task.assignees.contains(member.id) },
                    set: { planner.assign(taskID: task.taskId, userID: member.id, assigned: $0) }))
            }
        }
    }
}

/// "Add Task" field ending a bucket section; Return adds.
struct AddTaskField: View {
    @Binding var text: String
    let submit: () -> Void
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Add Task", text: $text)
                .textFieldStyle(.plain)
                .font(AppFont.body(scale))
                .onSubmit(submit)
        }
        .padding(.vertical, 2)
    }
}

// MARK: inspector

/// The selected task (§6.7 inspector): title, plan and bucket, progress,
/// priority, due date; Mark as Complete / Incomplete.
struct PlannerTaskInspector: View {
    @ObservedObject var planner: PlannerViewModel
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        if let model, let task = PlannerSection.selectedTask(model) {
            detail(task)
        } else {
            NoSelectionPane("No Task Selected")
        }
    }

    private func detail(_ task: PlannerTask) -> some View {
        let now = RelativeClock.shared.now
        return Form {
            Section {
                Text(task.title)
                    .font(AppFont.title3(scale))
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            }
            Section {
                if let plan = PlannerSection.plan(task.planId, planner) {
                    LabeledContent("Plan", value: plan.title)
                }
                if let bucket = planner.buckets.first(where: { $0.bucketId == task.bucketId }) {
                    LabeledContent("Bucket", value: bucket.name)
                }
                LabeledContent("Progress", value: PlannerFormat.progress(task))
                LabeledContent("Priority", value: PlannerFormat.priority(task.priority))
                LabeledContent("Due", value: PlannerFormat.dueDate(task.due).map {
                    $0.formatted(date: .abbreviated, time: .omitted)
                } ?? "None")
                if PlannerFormat.isOverdue(task, now: now) {
                    Label("Overdue", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                }
            }
            Section("Assigned To") {
                let people = PlannerFormat.assignees(task, planner)
                if people.isEmpty {
                    Text("Unassigned").foregroundStyle(.secondary)
                }
                ForEach(people) { person in
                    Label(person.name, systemImage: "person")
                }
                AssignMenu(task: task, planner: planner)
                    .fixedSize()
            }
            Section {
                Button(task.completed ? "Mark as Incomplete" : "Mark as Complete") {
                    PlannerSection.toggle(task, planner)
                }
            }
        }
        .formStyle(.grouped)
    }
}
