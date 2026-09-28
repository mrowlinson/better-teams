// PlannerDemo.swift — om-planner lane: canned boards for `--demo`.
//
// Own file (merge hygiene: no DemoData.swift edit). Team ids match
// `DemoData.teams` so the demo team picker resolves to boards offline.

/// Canned Planner fixtures for `--demo` (offline, in-memory).
public enum PlannerDemo {
    public static func plans(for teamID: String) -> [PlannerPlan] {
        switch teamID {
        case "demo-team-eng": return [
            PlannerPlan(planId: "demo-plan-sprint", title: "Sprint 12"),
            PlannerPlan(planId: "demo-plan-debt", title: "Tech debt"),
        ]
        case "demo-team-design": return [
            PlannerPlan(planId: "demo-plan-rebrand", title: "Rebrand"),
        ]
        default: return []
        }
    }

    public static func plansResponse(for teamID: String) -> PlannerPlansResponse {
        PlannerPlansResponse(ok: true, group_id: teamID, plans: plans(for: teamID))
    }

    public static func buckets(for planID: String) -> [PlannerBucket] {
        switch planID {
        case "demo-plan-sprint": return [
            PlannerBucket(bucketId: "demo-bucket-todo", planId: planID, name: "To do"),
            PlannerBucket(bucketId: "demo-bucket-doing", planId: planID, name: "In progress"),
            PlannerBucket(bucketId: "demo-bucket-review", planId: planID, name: "In review"),
            PlannerBucket(bucketId: "demo-bucket-done", planId: planID, name: "Done"),
        ]
        case "demo-plan-debt": return [
            PlannerBucket(bucketId: "demo-bucket-backlog", planId: planID, name: "Backlog"),
        ]
        case "demo-plan-rebrand": return [
            PlannerBucket(bucketId: "demo-bucket-ideas", planId: planID, name: "Ideas"),
            PlannerBucket(bucketId: "demo-bucket-final", planId: planID, name: "Final"),
        ]
        default: return []
        }
    }

    public static func bucketsResponse(for planID: String) -> PlannerBucketsResponse {
        PlannerBucketsResponse(ok: true, plan_id: planID, buckets: buckets(for: planID))
    }

    public static func tasks(for planID: String) -> [PlannerTask] {
        switch planID {
        case "demo-plan-sprint":
            func task(_ n: Int, _ bucket: String, _ title: String, percent: Int = 0, priority: Int? = nil,
                      due: String? = nil, _ people: [String]) -> PlannerTask {
                PlannerTask(
                    taskId: "demo-ptask-\(n)", planId: planID, bucketId: "demo-bucket-\(bucket)",
                    title: title, percent: percent, completed: percent == 100, priority: priority,
                    due: due.map { "2026-\($0)T12:00:00Z" }, etag: "W/\"demo-etag-\(n)\"",
                    assignees: people.map { "demo-u-\($0)" })
            }
            return [
                task(1, "todo", "Review empty-states mock", priority: 1, due: "10-02", ["megan"]),
                task(6, "todo", "Draft App Store release notes", priority: 5, due: "10-06", ["luis"]),
                task(7, "todo", "Localize onboarding strings", priority: 5, due: "10-08", ["hannah"]),
                task(8, "todo", "Plan beta feedback survey", priority: 9, due: "10-12", ["paula"]),
                task(2, "doing", "Build sign-in error states", percent: 50, ["me", "tom"]),
                task(9, "doing", "Improve search result ranking", percent: 50, priority: 3, due: "10-03",
                     ["ryan"]),
                task(10, "doing", "Refresh onboarding illustrations", percent: 50, due: "10-05", ["ava"]),
                task(11, "review", "Offline drafts for messages", percent: 50, priority: 3, due: "10-01",
                     ["ethan", "tom"]),
                task(12, "review", "Accessibility audit fixes", percent: 50, priority: 1, due: "09-30",
                     ["chloe"]),
                task(3, "done", "Ship review deck", percent: 100, ["megan"]),
                task(13, "done", "Set up crash reporting alerts", percent: 100, ["nathan"]),
                task(14, "done", "Update privacy policy link", percent: 100, ["olivia"]),
            ]
        case "demo-plan-debt": return [
            PlannerTask(
                taskId: "demo-ptask-4", planId: planID,
                bucketId: "demo-bucket-backlog", title: "Retire legacy auth shim",
                etag: "W/\"demo-etag-4\""),
        ]
        case "demo-plan-rebrand": return [
            PlannerTask(
                taskId: "demo-ptask-5", planId: planID,
                bucketId: "demo-bucket-ideas", title: "Mood board v3",
                percent: 50, etag: "W/\"demo-etag-5\""),
        ]
        default: return []
        }
    }

    public static func tasksResponse(for planID: String) -> PlannerTasksResponse {
        PlannerTasksResponse(ok: true, plan_id: planID, tasks: tasks(for: planID))
    }
}
