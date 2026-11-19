// PlannerViewModelDepth.swift — plannerdepth lane: pure depth helpers.
//
// Board / Charts / Schedule view types and their groupings live here
// (no instance state). The stateful depth API (labels, details,
// comments, delete task, create plan) extends PlannerViewModel in
// PlannerViewModel.swift, next to the state it mutates.
import Combine
import Foundation

/// Board / Charts / Schedule segmented views (§6.7 depth).
public enum PlannerBoardView: String, Sendable, CaseIterable {
    case board
    case charts
    case schedule
}

/// One Charts row: a label's tasks, done first for the progress bar.
public struct PlannerChartRow: Sendable, Equatable {
    public let label: Int
    public let name: String
    public let total: Int
    public let done: Int
}

/// One Schedule group: dated tasks under one heading.
public struct PlannerScheduleGroup: Sendable, Equatable {
    public let title: String
    public let tasks: [PlannerTask]
}

/// Depth fetcher types (labels, details, comments, delete task,
/// create/delete plan). Default implementations call `PlannerCore`;
/// tests inject mocks.
extension PlannerViewModel {
    public typealias LabelsFetcher = @Sendable (String, String, Int, Bool) throws -> PlannerTaskResult
    public typealias RenameFetcher = @Sendable (String, [Int: String]) throws -> PlannerPlanResult
    public typealias DetailsFetcher = @Sendable (String) throws -> PlannerDetailsResponse
    public typealias ChecklistFetcher = @Sendable (String, String, String, String, Bool, Bool) throws -> Void
    public typealias DescriptionFetcher = @Sendable (String, String, String) throws -> Void
    public typealias ReferenceFetcher = @Sendable (String, String, String, String, Bool) throws -> Void
    public typealias DeleteTaskFetcher = @Sendable (String, String) throws -> Void
    public typealias CreatePlanFetcher = @Sendable (String, String) throws -> PlannerPlanResult
    public typealias DeletePlanFetcher = @Sendable (String) throws -> Void
    public typealias CreateBucketFetcher = @Sendable (String, String) throws -> PlannerBucketResult
    public typealias CommentFetcher = @Sendable (String, String, String) throws -> Void
    public typealias CommentsFetcher = @Sendable (String, String) throws -> PlannerCommentsResponse
}

extension PlannerViewModel {
    /// Graph `dueDateTime` (ISO-8601, UTC) → local date. Mirrors the
    /// UI-side `PlannerFormat.dueDate` (that enum lives in BetterTeamsUI;
    /// grouping stays testable in OstMacCore).
    public nonisolated static func depthDueDate(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }

    public nonisolated static func depthIsOverdue(
        _ task: PlannerTask, now: Date, calendar: Calendar = .current
    ) -> Bool {
        guard !task.completed, let d = depthDueDate(task.due) else { return false }
        return d < calendar.startOfDay(for: now)
    }

    /// One row per used label (name from the selected plan), then an
    /// unlabeled row when some task has no label.
    public nonisolated static func chartRows(
        _ tasks: [PlannerTask], plan: PlannerPlan?
    ) -> (rows: [PlannerChartRow], unlabeled: PlannerChartRow?) {
        var rows: [PlannerChartRow] = []
        for n in 1...6 {
            let mine = tasks.filter { $0.labels.contains(n) }
            guard !mine.isEmpty else { continue }
            rows.append(PlannerChartRow(
                label: n, name: plan?.labelName(n) ?? "Label \(n)",
                total: mine.count, done: mine.filter(\.completed).count))
        }
        let bare = tasks.filter { $0.labels.isEmpty }
        let unlabeled = bare.isEmpty ? nil : PlannerChartRow(
            label: 0, name: "No label", total: bare.count, done: bare.filter(\.completed).count)
        return (rows, unlabeled)
    }

    /// Schedule buckets: overdue, today, this week, later, no due date.
    /// Dated groups sort oldest-first; completed tasks stay with their
    /// date (done is a state, not a schedule).
    public nonisolated static func scheduleGroups(
        _ tasks: [PlannerTask], now: Date, calendar: Calendar = .current
    ) -> [PlannerScheduleGroup] {
        var overdue: [PlannerTask] = []
        var today: [PlannerTask] = []
        var week: [PlannerTask] = []
        var later: [PlannerTask] = []
        var none: [PlannerTask] = []
        let startOfToday = calendar.startOfDay(for: now)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: startOfToday) ?? now
        for task in tasks {
            guard let due = depthDueDate(task.due) else {
                none.append(task)
                continue
            }
            if !task.completed, due < startOfToday {
                overdue.append(task)
            } else if calendar.isDate(due, inSameDayAs: now) {
                today.append(task)
            } else if due < weekEnd {
                week.append(task)
            } else {
                later.append(task)
            }
        }
        let byDue: ([PlannerTask]) -> [PlannerTask] = {
            $0.sorted {
                depthDueDate($0.due) ?? .distantFuture
                    < depthDueDate($1.due) ?? .distantFuture
            }
        }
        var out: [PlannerScheduleGroup] = []
        if !overdue.isEmpty { out.append(PlannerScheduleGroup(title: "Overdue", tasks: byDue(overdue))) }
        if !today.isEmpty { out.append(PlannerScheduleGroup(title: "Today", tasks: byDue(today))) }
        if !week.isEmpty { out.append(PlannerScheduleGroup(title: "This week", tasks: byDue(week))) }
        if !later.isEmpty { out.append(PlannerScheduleGroup(title: "Later", tasks: byDue(later))) }
        if !none.isEmpty { out.append(PlannerScheduleGroup(title: "No due date", tasks: none)) }
        return out
    }
}
