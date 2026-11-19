// PlannerViews.swift — Planner list, board and task inspector
// (UI-SPEC §6.7, §6 row conventions, R18 pane states).
import OstMacCore
import SwiftUI

// MARK: plans list

/// Plans grouped by team (§6.7), one `Section` per team with plans.
struct PlannerListPane: View {
    @ObservedObject var planner: PlannerViewModel
    @Environment(\.windowModel) private var model
    @State private var deleteTarget: PlannerPlan?

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
                            .contextMenu {
                                Button("Delete Plan…", role: .destructive) {
                                    deleteTarget = plan
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.inset)
        .confirmationDialog(
            "Delete this plan?", isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Plan", role: .destructive) {
                if let plan = deleteTarget {
                    planner.deletePlan(planID: plan.planId)
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("“\(deleteTarget?.title ?? "")” and all its tasks will be permanently deleted.")
        }
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
        VStack(spacing: 0) {
            // Depth view switcher + New Plan (inline header: detail panes
            // carry no toolbar, so the Calendar inline pattern is used).
            HStack {
                Picker("View", selection: $planner.boardView) {
                    ForEach(PlannerBoardView.allCases, id: \.self) { view in
                        Text(view.title).tag(view)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                Spacer(minLength: 8)
                Button("New Plan…") {
                    m.presentSheet(SheetRequest(PlannerCommands.newPlanSheet, in: .native(.planner)))
                }
                .disabled(planner.teams.isEmpty)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            switch planner.boardView {
            case .board: bucketList(m)
            case .charts: PlannerChartsPane(planner: planner)
            case .schedule: PlannerSchedulePane(planner: planner, open: { PlannerSection.open($0, m) })
            }
        }
    }

    private func bucketList(_ m: WindowModel) -> some View {
        let now = RelativeClock.shared.now
        let orphans = PlannerViewModel.orphaned(planner.tasks, buckets: planner.buckets)
        let selection = Binding<String?>(
            get: { PlannerSection.current(m).taskID },
            set: { PlannerSection.selectTask($0, m) })
        let plan = planner.selectedPlanID.flatMap { PlannerSection.plan($0, planner) }
        return List(selection: selection) {
            ForEach(planner.buckets) { bucket in
                Section(bucket.name) {
                    ForEach(PlannerViewModel.visible(planner.tasks, bucketID: bucket.bucketId, hideDone: false)) { task in
                        PlannerTaskRow(task: task, now: now, assignees: PlannerFormat.assignees(task, planner).map(\.name), plan: plan) {
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
                        PlannerTaskRow(task: task, now: now, assignees: PlannerFormat.assignees(task, planner).map(\.name), plan: plan) {
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
                LabelsMenu(task: task, plan: plan, planner: planner)
            }
        } primaryAction: { ids in
            if let id = ids.first { PlannerSection.open(id, m) }
        }
    }

    private func draft(_ bucketID: String) -> Binding<String> {
        Binding(get: { drafts[bucketID] ?? "" }, set: { drafts[bucketID] = $0 })
    }
}

extension PlannerBoardView {
    var title: String {
        switch self {
        case .board: "Board"
        case .charts: "Charts"
        case .schedule: "Schedule"
        }
    }
}

// MARK: charts + schedule

/// Charts: one row per used label with a progress bar (§6.7 depth).
struct PlannerChartsPane: View {
    @ObservedObject var planner: PlannerViewModel
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        let plan = planner.selectedPlanID.flatMap { PlannerSection.plan($0, planner) }
        let (rows, unlabeled) = PlannerViewModel.chartRows(planner.tasks, plan: plan)
        List {
            ForEach(rows, id: \.label) { row in
                HStack(spacing: 8) {
                    Circle()
                        .fill(PlannerFormat.labelColor(row.label))
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(row.name)
                        .font(AppFont.body(scale))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(row.done)/\(row.total)")
                        .font(AppFont.subheadline(scale))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityLabel("\(row.done) of \(row.total) complete")
                    ProgressView(value: Double(row.done), total: Double(max(row.total, 1)))
                        .frame(width: 120)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 2)
            }
            if let rest = unlabeled {
                HStack(spacing: 8) {
                    Circle()
                        .stroke(.secondary, lineWidth: 1)
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(rest.name)
                        .font(AppFont.body(scale))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(rest.done)/\(rest.total)")
                        .font(AppFont.subheadline(scale))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset)
    }
}

/// Schedule: dated groups, oldest first (§6.7 depth).
struct PlannerSchedulePane: View {
    @ObservedObject var planner: PlannerViewModel
    let open: (String) -> Void
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        let now = RelativeClock.shared.now
        let groups = PlannerViewModel.scheduleGroups(planner.tasks, now: now)
        List {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.tasks) { task in
                        Button {
                            open(task.taskId)
                        } label: {
                            PlannerTaskRow(
                                task: task, now: now,
                                assignees: PlannerFormat.assignees(task, planner).map(\.name),
                                plan: planner.selectedPlanID.flatMap { PlannerSection.plan($0, planner) }) {
                                PlannerSection.toggle(task, planner)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

/// Task row (§6.7): checkbox (complete / reopen), label dots, title,
/// due date; a priority mark for Urgent and Important.
struct PlannerTaskRow: View {
    let task: PlannerTask
    let now: Date
    /// Assignee names, roster order of the task's ids.
    let assignees: [String]
    /// The task's plan (label display names); nil labels read "Label N".
    var plan: PlannerPlan? = nil
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
            if !task.labels.isEmpty {
                HStack(spacing: 3) {
                    ForEach(task.labels, id: \.self) { label in
                        Circle()
                            .fill(PlannerFormat.labelColor(label))
                            .frame(width: 8, height: 8)
                    }
                }
                .accessibilityLabel("Labels: \(PlannerFormat.labelNames(task, plan: plan).joined(separator: ", "))")
            }
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
    var placeholder: String = "Add Task"
    let submit: () -> Void
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(AppFont.body(scale))
                .onSubmit(submit)
        }
        .padding(.vertical, 2)
    }
}

/// Labels menu (context menu and inspector): one checkable item per
/// label 1-6, named from the plan; choosing one sets or clears it.
struct LabelsMenu: View {
    let task: PlannerTask
    let plan: PlannerPlan?
    @ObservedObject var planner: PlannerViewModel

    var body: some View {
        Menu("Labels") {
            ForEach(1...6, id: \.self) { n in
                Toggle((plan?.labelName(n) ?? "Label \(n)"), isOn: Binding(
                    get: { task.labels.contains(n) },
                    set: { planner.setLabel(taskID: task.taskId, category: n, on: $0) }))
            }
        }
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
            Section("Labels") {
                LabelsMenu(task: task, plan: PlannerSection.plan(task.planId, planner), planner: planner)
                    .fixedSize()
            }
            DetailDescriptionSection(task: task, planner: planner)
            DetailChecklistSection(task: task, planner: planner)
            DetailReferencesSection(task: task, planner: planner)
            DetailCommentsSection(task: task, planner: planner)
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
                DeleteTaskButton(task: task, planner: planner)
            }
        }
        .formStyle(.grouped)
        .onAppear { planner.loadDetails(taskID: task.taskId) }
        .onChange(of: task.taskId) { planner.loadDetails(taskID: task.taskId) }
    }
}

/// Description editor (depth): the cached text, editable in place.
private struct DetailDescriptionSection: View {
    let task: PlannerTask
    @ObservedObject var planner: PlannerViewModel
    @Environment(\.contentTextScale) private var scale
    @State private var draft = ""
    @State private var editing = false

    var body: some View {
        let saved = planner.detailsByTask[task.taskId]?.description ?? ""
        Section("Description") {
            if editing {
                TextEditor(text: $draft)
                    .font(AppFont.body(scale))
                    .frame(minHeight: 60)
                HStack {
                    Button("Cancel") { editing = false }
                    Spacer()
                    Button("Save") {
                        planner.setDescription(taskID: task.taskId, description: draft)
                        editing = false
                    }
                    .disabled(draft == saved)
                }
            } else {
                if saved.isEmpty {
                    Text("No description").foregroundStyle(.secondary)
                } else {
                    Text(saved).textSelection(.enabled)
                }
                Button("Edit Description") {
                    draft = saved
                    editing = true
                }
                .fixedSize()
            }
        }
    }
}

/// Checklist (depth): toggleable items, an add field, swipe-free
/// remove buttons (explicit, HIG).
private struct DetailChecklistSection: View {
    let task: PlannerTask
    @ObservedObject var planner: PlannerViewModel
    @State private var draft = ""

    var body: some View {
        let items = planner.detailsByTask[task.taskId]?.checklist ?? []
        Section("Checklist") {
            if items.isEmpty {
                Text("No checklist items").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                HStack {
                    Toggle(item.title, isOn: Binding(
                        get: { item.checked },
                        set: { _ in planner.toggleChecklist(taskID: task.taskId, itemID: item.itemId) }))
                    .toggleStyle(.checkbox)
                    Spacer()
                    Button {
                        planner.removeChecklist(taskID: task.taskId, itemID: item.itemId)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Remove \(item.title)")
                    }
                    .buttonStyle(.plain)
                }
            }
            AddTaskField(text: $draft, placeholder: "Add Checklist Item") {
                planner.addChecklist(taskID: task.taskId, title: draft)
                draft = ""
            }
        }
    }
}

/// Attachments (depth): links with remove buttons, URL + alias add.
private struct DetailReferencesSection: View {
    let task: PlannerTask
    @ObservedObject var planner: PlannerViewModel
    @State private var url = ""
    @State private var alias = ""

    var body: some View {
        let refs = planner.detailsByTask[task.taskId]?.references ?? []
        Section("Attachments") {
            if refs.isEmpty {
                Text("No attachments").foregroundStyle(.secondary)
            }
            ForEach(refs) { ref in
                HStack {
                    if let link = URL(string: ref.url) {
                        Link(ref.alias.isEmpty ? ref.url : ref.alias, destination: link)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(ref.alias.isEmpty ? ref.url : ref.alias)
                    }
                    Spacer()
                    Button {
                        planner.removeReference(taskID: task.taskId, url: ref.url)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Remove \(ref.alias.isEmpty ? ref.url : ref.alias)")
                    }
                    .buttonStyle(.plain)
                }
            }
            TextField("URL", text: $url)
            TextField("Name (optional)", text: $alias)
            Button("Attach Link") {
                planner.addReference(taskID: task.taskId, url: url, alias: alias)
                url = ""
                alias = ""
            }
            .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

/// Comments (depth): thread posts, then an add field. Tasks minted by
/// the API have no thread until the first UI comment, so that case
/// names itself instead of showing an empty list.
private struct DetailCommentsSection: View {
    let task: PlannerTask
    @ObservedObject var planner: PlannerViewModel
    @Environment(\.contentTextScale) private var scale
    @State private var draft = ""

    var body: some View {
        Section("Comments") {
            if task.threadID.isEmpty {
                Text("No comments yet").foregroundStyle(.secondary)
            } else {
                let posts = planner.commentsByThread[task.threadID] ?? []
                if posts.isEmpty {
                    Text("No comments yet").foregroundStyle(.secondary)
                }
                ForEach(posts) { post in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(post.text)
                            .font(AppFont.body(scale))
                            .textSelection(.enabled)
                        if let received = PlannerFormat.dueDate(post.received) {
                            Text(received.formatted(date: .abbreviated, time: .shortened))
                                .font(AppFont.subheadline(scale))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                AddTaskField(text: $draft, placeholder: "Add Comment") {
                    planner.postComment(taskID: task.taskId, text: draft)
                    draft = ""
                }
            }
        }
    }
}

/// Delete-task button with confirmation (depth).
private struct DeleteTaskButton: View {
    let task: PlannerTask
    @ObservedObject var planner: PlannerViewModel
    @State private var confirming = false

    var body: some View {
        Button("Delete Task", role: .destructive) { confirming = true }
            .confirmationDialog("Delete this task?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Delete Task", role: .destructive) {
                    planner.deleteTask(taskID: task.taskId)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("“\(task.title)” will be permanently deleted.")
            }
    }
}

/// New-plan sheet: team picker + title (depth).
struct NewPlanSheet: View {
    @ObservedObject var planner: PlannerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.contentTextScale) private var scale
    @State private var teamID = ""
    @State private var title = ""

    var body: some View {
        Form {
            Section {
                Picker("Team", selection: $teamID) {
                    ForEach(planner.teams) { team in
                        Text(team.name).tag(team.teamId)
                    }
                }
                TextField("Plan title", text: $title)
                    .font(AppFont.body(scale))
            }
            Section {
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Create Plan") {
                        planner.createPlan(teamID: teamID, title: title)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(teamID.isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 320, minHeight: 200)
        .onAppear { teamID = planner.selectedTeamID ?? planner.teams.first?.teamId ?? "" }
    }
}
