// PlannerModel.swift — Planner selection, pane states and formatting
// (UI-SPEC §6.7, R18). Pure values; the views and the provider share them.
import Foundation
import OstMacCore

/// `app/planner/<plan>/<task>`: the selected plan, then the task the
/// inspector shows.
struct PlannerSelection: Equatable {
    var planID: String?
    var taskID: String?

    init(planID: String? = nil, taskID: String? = nil) {
        self.planID = planID
        self.taskID = taskID
    }

    init(_ s: SectionSelection?) {
        planID = s?.path.first
        taskID = (s?.path.count ?? 0) > 1 ? s?.path[1] : nil
    }

    var selection: SectionSelection? {
        guard let planID else { return nil }
        return SectionSelection(taskID.map { [planID, $0] } ?? [planID])
    }
}

/// What the plans list shows. Titles state the condition (R18).
enum PlannerListState: Equatable {
    case loading
    case error(title: String, message: String)
    case empty
    case plans

    static let emptyTitle = "No Plans"
    static let emptyMessage = "Plans from your teams appear here."
    static let errorTitle = "Couldn\u{2019}t Load Plans"
    static let offlineTitle = "You\u{2019}re Offline"
    static let offlineMessage = "Your plans appear when you\u{2019}re back online."

    /// R12: plans on screen are never replaced by a spinner or error.
    static func resolve(_ state: PlannerState, planCount: Int, plansError: String?,
                        forced: ForcedPaneState?, offline: Bool) -> PlannerListState {
        func failed(_ m: String) -> PlannerListState {
            offline ? .error(title: offlineTitle, message: offlineMessage) : .error(title: errorTitle, message: m)
        }
        switch forced {
        case .loading: return .loading
        case .empty: return .empty
        case .error: return failed("Something went wrong.")
        case nil: break
        }
        if planCount > 0 { return .plans }
        switch state {
        case .loading: return .loading
        case .error(let m): return failed(m)
        case .empty: return .empty
        case .loaded: return plansError.map(failed) ?? .empty
        }
    }

    /// A failed refresh behind the plans on screen (quiet notice).
    @MainActor
    static func failure(_ planner: PlannerViewModel) -> String? {
        if case .error(let m) = planner.state { return m }
        return planner.plansError
    }
}

/// What the plan detail (bucket list) shows.
enum PlannerBoardState: Equatable {
    case noSelection
    case loading
    case error(title: String, message: String)
    case noBuckets
    case board

    static let noSelectionTitle = "No Plan Selected"
    static let errorTitle = "Couldn\u{2019}t Load Tasks"

    static func resolve(planSelected: Bool, showing: Bool, loading: Bool, error: String?,
                        bucketCount: Int, taskCount: Int, offline: Bool) -> PlannerBoardState {
        guard planSelected else { return .noSelection }
        // The view model still holds another plan's board: wait for this one.
        guard showing else { return .loading }
        if bucketCount > 0 || taskCount > 0 { return .board }
        if loading { return .loading }
        if let error {
            return offline
                ? .error(title: PlannerListState.offlineTitle, message: PlannerListState.offlineMessage)
                : .error(title: errorTitle, message: error)
        }
        return .noBuckets
    }
}

enum PlannerFormat {
    /// Graph `dueDateTime` (ISO-8601, UTC) → local date.
    static func dueDate(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }

    /// "Today", "Tomorrow", "Oct 2" (year only when not this year).
    static func due(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: t) {
            return "Tomorrow"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }

    static func isOverdue(_ task: PlannerTask, now: Date, calendar: Calendar = .current) -> Bool {
        guard !task.completed, let d = dueDate(task.due) else { return false }
        return d < calendar.startOfDay(for: now)
    }

    /// Graph priority 0–10: 0–1 Urgent, 2–4 Important, 5–7 Medium, 8–10 Low.
    static func priority(_ p: Int?) -> String {
        switch p ?? 5 {
        case ...1: "Urgent"
        case 2...4: "Important"
        case 5...7: "Medium"
        default: "Low"
        }
    }

    /// Rows flag only the priorities above Medium.
    static func isFlagged(_ p: Int?) -> Bool { (p ?? 5) <= 4 }

    /// Assignees in roster order (ids the roster lacks last, named
    /// "Unknown Person").
    @MainActor
    static func assignees(_ task: PlannerTask, _ planner: PlannerViewModel) -> [PlannerMember] {
        let order = Dictionary(planner.members.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        return task.assignees
            .sorted { (order[$0] ?? Int.max, $0) < (order[$1] ?? Int.max, $1) }
            .map { PlannerMember(id: $0, name: planner.memberName($0)) }
    }

    /// Row summary: "Megan Harper", "Megan Harper +1"; nil when unassigned.
    static func assigneeSummary(_ names: [String]) -> String? {
        guard let first = names.first else { return nil }
        return names.count > 1 ? "\(first) +\(names.count - 1)" : first
    }

    static func progress(_ task: PlannerTask) -> String {
        if task.completed || task.percent >= 100 { return "Completed" }
        return task.percent > 0 ? "In progress" : "Not started"
    }
}
