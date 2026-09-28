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
            PlannerBucket(bucketId: "demo-bucket-doing", planId: planID, name: "Doing"),
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
        case "demo-plan-sprint": return [
            PlannerTask(
                taskId: "demo-ptask-1", planId: planID,
                bucketId: "demo-bucket-todo", title: "Review empty-states mock",
                percent: 0, priority: 1, due: "2026-10-02T12:00:00Z",
                etag: "W/\"demo-etag-1\"", assignees: ["demo-u-megan"]),
            PlannerTask(
                taskId: "demo-ptask-2", planId: planID,
                bucketId: "demo-bucket-doing", title: "Wire planner FFI",
                percent: 50, etag: "W/\"demo-etag-2\"",
                assignees: ["demo-u-me", "demo-u-tom"]),
            PlannerTask(
                taskId: "demo-ptask-3", planId: planID,
                bucketId: "demo-bucket-done", title: "Ship review deck",
                percent: 100, completed: true, etag: "W/\"demo-etag-3\""),
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
