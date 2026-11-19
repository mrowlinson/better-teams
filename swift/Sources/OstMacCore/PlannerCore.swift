// PlannerCore.swift — om-planner lane: Planner FFI calls.
//
// Separate from RustCore.swift (merge hygiene: this lane's calls live
// in this file). Uses the shared internal `RustCore.call` decoder.
import COstMac
import Foundation

/// Planner core calls. Blocking FFI + network; callers run these off
/// the main thread (see `PlannerViewModel`).
public enum PlannerCore {
    public static func plans(groupID: String) throws -> PlannerPlansResponse {
        try groupID.withCString { ptr in
            try RustCore.call(ostmac_planner_plans(ptr), as: PlannerPlansResponse.self)
        }
    }

    public static func buckets(planID: String) throws -> PlannerBucketsResponse {
        try planID.withCString { ptr in
            try RustCore.call(ostmac_planner_buckets(ptr), as: PlannerBucketsResponse.self)
        }
    }

    public static func tasks(planID: String, limit: Int32 = 100) throws -> PlannerTasksResponse {
        try planID.withCString { ptr in
            try RustCore.call(ostmac_planner_tasks(ptr, limit), as: PlannerTasksResponse.self)
        }
    }

    public static func add(planID: String, bucketID: String, title: String) throws -> PlannerTaskResult {
        try planID.withCString { planPtr in
            try bucketID.withCString { bucketPtr in
                try title.withCString { titlePtr in
                    try RustCore.call(
                        ostmac_planner_add(planPtr, bucketPtr, titlePtr),
                        as: PlannerTaskResult.self)
                }
            }
        }
    }

    public static func done(taskID: String, etag: String) throws -> PlannerTaskResult {
        try taskID.withCString { idPtr in
            try etag.withCString { etagPtr in
                try RustCore.call(
                    ostmac_planner_done(idPtr, etagPtr),
                    as: PlannerTaskResult.self)
            }
        }
    }

    /// Assign (`assign == true`) or unassign one user on one task.
    public static func assign(taskID: String, etag: String, userID: String,
                              assign: Bool) throws -> PlannerTaskResult {
        try taskID.withCString { idPtr in
            try etag.withCString { etagPtr in
                try userID.withCString { userPtr in
                    try RustCore.call(
                        ostmac_planner_assign(idPtr, etagPtr, userPtr, assign ? 1 : 0),
                        as: PlannerTaskResult.self)
                }
            }
        }
    }

    public static func reopen(taskID: String, etag: String) throws -> PlannerTaskResult {
        try taskID.withCString { idPtr in
            try etag.withCString { etagPtr in
                try RustCore.call(
                    ostmac_planner_reopen(idPtr, etagPtr),
                    as: PlannerTaskResult.self)
            }
        }
    }

    /// Set (`on == true`) or clear one label 1-6 on a task.
    public static func labels(taskID: String, etag: String, category: Int, on: Bool) throws -> PlannerTaskResult {
        try taskID.withCString { idPtr in
            try etag.withCString { etagPtr in
                try RustCore.call(
                    ostmac_planner_labels(idPtr, etagPtr, Int32(category), on ? 1 : 0),
                    as: PlannerTaskResult.self)
            }
        }
    }

    /// Rename plan labels from display names by number.
    public static func renameLabels(planID: String, names: [Int: String]) throws -> PlannerPlanResult {
        let obj = Dictionary(uniqueKeysWithValues: names.map { ("\( $0.key)", $0.value) })
        let data = try JSONSerialization.data(withJSONObject: obj)
        let json = String(decoding: data, as: UTF8.self)
        return try planID.withCString { planPtr in
            try json.withCString { jsonPtr in
                try RustCore.call(
                    ostmac_planner_plan_categories(planPtr, jsonPtr),
                    as: PlannerPlanResult.self)
            }
        }
    }

    /// One task's details (checklist, description, references).
    public static func details(taskID: String) throws -> PlannerDetailsResponse {
        try taskID.withCString { ptr in
            try RustCore.call(ostmac_planner_details(ptr), as: PlannerDetailsResponse.self)
        }
    }

    /// Add/update (`remove == false`) or remove one checklist item
    /// (empty `itemID` creates).
    public static func checklist(taskID: String, etag: String, itemID: String, title: String, checked: Bool, remove: Bool) throws {
        try taskID.withCString { idPtr in
            try etag.withCString { etagPtr in
                try itemID.withCString { itemPtr in
                    try title.withCString { titlePtr in
                        try RustCore.callVoid(ostmac_planner_checklist(
                            idPtr, etagPtr, itemPtr, titlePtr,
                            checked ? 1 : 0, remove ? 1 : 0))
                    }
                }
            }
        }
    }

    /// Set a task's description.
    public static func description(taskID: String, etag: String, description: String) throws {
        try taskID.withCString { idPtr in
            try etag.withCString { etagPtr in
                try description.withCString { descPtr in
                    try RustCore.callVoid(ostmac_planner_description(idPtr, etagPtr, descPtr))
                }
            }
        }
    }

    /// Attach (`attach == true`) or detach one URL reference.
    public static func reference(taskID: String, etag: String, url: String, alias: String, attach: Bool) throws {
        try taskID.withCString { idPtr in
            try etag.withCString { etagPtr in
                try url.withCString { urlPtr in
                    try alias.withCString { aliasPtr in
                        try RustCore.callVoid(ostmac_planner_reference(
                            idPtr, etagPtr, urlPtr, aliasPtr, attach ? 1 : 0))
                    }
                }
            }
        }
    }

    /// Delete one task.
    public static func deleteTask(taskID: String, etag: String) throws {
        try taskID.withCString { idPtr in
            try etag.withCString { etagPtr in
                try RustCore.callVoid(ostmac_planner_task_delete(idPtr, etagPtr))
            }
        }
    }

    /// Create one plan under a group (team).
    public static func createPlan(groupID: String, title: String) throws -> PlannerPlanResult {
        try groupID.withCString { groupPtr in
            try title.withCString { titlePtr in
                try RustCore.call(
                    ostmac_planner_plan_create(groupPtr, titlePtr),
                    as: PlannerPlanResult.self)
            }
        }
    }

    /// Delete one plan.
    public static func deletePlan(planID: String) throws {
        try planID.withCString { ptr in
            try RustCore.callVoid(ostmac_planner_plan_delete(ptr))
        }
    }

    /// Create one bucket in a plan.
    public static func createBucket(planID: String, name: String) throws -> PlannerBucketResult {
        try planID.withCString { planPtr in
            try name.withCString { namePtr in
                try RustCore.call(
                    ostmac_planner_bucket_create(planPtr, namePtr),
                    as: PlannerBucketResult.self)
            }
        }
    }

    /// Post one Planner comment (group thread reply).
    public static func comment(groupID: String, threadID: String, text: String) throws {
        try groupID.withCString { groupPtr in
            try threadID.withCString { threadPtr in
                try text.withCString { textPtr in
                    try RustCore.callVoid(ostmac_planner_comment(groupPtr, threadPtr, textPtr))
                }
            }
        }
    }

    /// Read a plan thread's posts (Planner comments).
    public static func comments(groupID: String, threadID: String) throws -> PlannerCommentsResponse {
        try groupID.withCString { groupPtr in
            try threadID.withCString { threadPtr in
                try RustCore.call(
                    ostmac_planner_comments(groupPtr, threadPtr),
                    as: PlannerCommentsResponse.self)
            }
        }
    }
}
