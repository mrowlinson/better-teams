// PlannerSection.swift — Planner native app provider (UI-SPEC §6.7).
//
// List: plans grouped by team. Detail: the plan as a List sectioned by
// bucket — checkbox rows (complete / reopen), title, due date, and an
// Add Task field ending each section. Inspector: the selected task. No
// kanban board in v1 (R6). Board loads start from the selection (R24).
import OstMacCore
import SwiftUI

@MainActor
final class PlannerSection: SectionProvider, InspectorCapable {
    let section: SectionID = .native(.planner)
    let title = NativeAppID.planner.title
    let hasInspector = true

    func subtitle(_ m: WindowModel) -> String {
        guard m.forced(section) == nil, let app = m.app, let id = Self.current(m).planID else { return "" }
        return Self.plan(id, app.planner)?.title ?? ""
    }

    func listPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else {
            return AnyView(EmptyPane(PlannerListState.emptyTitle, systemImage: NativeAppID.planner.symbol,
                                     message: PlannerListState.emptyMessage))
        }
        return AnyView(PlannerListPane(planner: app.planner))
    }

    func detailPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else { return AnyView(NoSelectionPane(PlannerBoardState.noSelectionTitle)) }
        return AnyView(PlannerBoardPane(planner: app.planner))
    }

    func inspector(_ m: WindowModel) -> AnyView? {
        guard let app = m.app else { return nil }
        return AnyView(PlannerTaskInspector(planner: app.planner))
    }

    /// `app/planner/<plan>/<task>` (the tail's head is the app id).
    func selection(for route: Route) -> SectionSelection? {
        let rest = Array(route.tail.dropFirst())
        return rest.isEmpty ? nil : SectionSelection(rest)
    }

    func selectionDidChange(_ sel: SectionSelection?, _ m: WindowModel) {
        guard m.forced(section) == nil, let planner = m.app?.planner else { return }
        planner.show(planID: PlannerSelection(sel).planID)
    }

    // MARK: shared helpers

    static func current(_ m: WindowModel) -> PlannerSelection {
        PlannerSelection(m.nav.selection(in: .native(.planner)))
    }

    static func plan(_ id: String, _ planner: PlannerViewModel) -> PlannerPlan? {
        for plans in planner.plansByTeam.values {
            if let p = plans.first(where: { $0.planId == id }) { return p }
        }
        return planner.plans.first { $0.planId == id }
    }

    static func selectPlan(_ id: String?, _ m: WindowModel) {
        var s = current(m)
        guard s.planID != id else { return }
        s = PlannerSelection(planID: id)
        m.navigator?.select(s.selection, in: .native(.planner))
    }

    static func selectTask(_ id: String?, _ m: WindowModel) {
        var s = current(m)
        guard s.planID != nil, s.taskID != id else { return }
        s.taskID = id
        m.navigator?.select(s.selection, in: .native(.planner))
    }

    /// Double-click / Return on a task: select it and show the inspector.
    static func open(_ id: String, _ m: WindowModel) {
        selectTask(id, m)
        if !m.nav.isInspectorVisible(.native(.planner)) { m.navigator?.setInspector(true) }
    }

    /// Checkbox: complete an open task, reopen a completed one.
    static func toggle(_ task: PlannerTask, _ planner: PlannerViewModel) {
        if task.completed {
            planner.reopen(taskID: task.taskId)
        } else {
            planner.complete(taskID: task.taskId)
        }
    }

    /// The selected task, when it is on the board being shown.
    static func selectedTask(_ m: WindowModel) -> PlannerTask? {
        guard m.nav.section == .native(.planner), m.nav.search == nil, let planner = m.app?.planner else {
            return nil
        }
        let s = current(m)
        guard let planID = s.planID, planner.selectedPlanID == planID, let id = s.taskID else { return nil }
        return planner.tasks.first { $0.taskId == id }
    }

    // MARK: commands

    func perform(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool {
        guard c == PlannerCommands.toggleComplete, let planner = m.app?.planner,
              let task = Self.selectedTask(m) else { return false }
        Self.toggle(task, planner)
        return true
    }

    func validate(_ c: CommandID, arg: String?, _ m: WindowModel) -> CommandValidation {
        guard c == PlannerCommands.toggleComplete, let task = Self.selectedTask(m) else { return .disabled }
        return CommandValidation(enabled: true, title: task.completed ? "Mark as Incomplete" : "Mark as Complete")
    }
}
