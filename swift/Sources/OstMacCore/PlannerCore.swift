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
}
