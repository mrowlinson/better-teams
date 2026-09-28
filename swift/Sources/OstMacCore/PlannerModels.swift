// PlannerModels.swift — om-planner lane: Planner boards via Graph.
//
// Wire shapes from core `ostmac_planner_*` (snake_case over FFI,
// camelCase in Swift). Mirrors the om-remind To Do models.

/// One Planner board from core `ostmac_planner_plans`:
/// `{"id","title"}`.
public struct PlannerPlan: Decodable, Sendable, Identifiable, Equatable {
    public var id: String { planId }
    public let planId: String
    public let title: String

    enum CodingKeys: String, CodingKey {
        case planId = "id"
        case title
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(planId: String, title: String) {
        self.planId = planId
        self.title = title
    }
}

public struct PlannerPlansResponse: Decodable, Sendable {
    public let ok: Bool
    public let group_id: String?
    public let plans: [PlannerPlan]
}

/// One board column from core `ostmac_planner_buckets`:
/// `{"id","plan_id","name"}`.
public struct PlannerBucket: Decodable, Sendable, Identifiable, Equatable {
    public var id: String { bucketId }
    public let bucketId: String
    public let planId: String
    public let name: String

    enum CodingKeys: String, CodingKey {
        case bucketId = "id"
        case planId = "plan_id"
        case name
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(bucketId: String, planId: String, name: String) {
        self.bucketId = bucketId
        self.planId = planId
        self.name = name
    }
}

public struct PlannerBucketsResponse: Decodable, Sendable {
    public let ok: Bool
    public let plan_id: String?
    public let buckets: [PlannerBucket]
}

/// One Planner task from core `ostmac_planner_tasks`: `{"id","plan_id",
/// "bucket_id","title","percent","completed","priority?","due?","etag",
/// "assignees"}` (assignees = user ids; absent reads as none).
public struct PlannerTask: Decodable, Sendable, Identifiable, Equatable {
    public var id: String { taskId }
    public let taskId: String
    public let planId: String
    public let bucketId: String
    public let title: String
    /// Graph `percentComplete` (0-100).
    public let percent: Int
    public let completed: Bool
    /// Graph priority (0-10) when the server sends one.
    public let priority: Int?
    public let due: String?
    /// `@odata.etag` verbatim; complete/reopen/assign send it back as `If-Match`.
    public let etag: String
    /// Assigned user ids (sorted by core); empty when unassigned.
    public let assignees: [String]

    enum CodingKeys: String, CodingKey {
        case taskId = "id"
        case planId = "plan_id"
        case bucketId = "bucket_id"
        case title, percent, completed, priority, due, etag, assignees
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try c.decode(String.self, forKey: .taskId)
        planId = try c.decode(String.self, forKey: .planId)
        bucketId = try c.decode(String.self, forKey: .bucketId)
        title = try c.decode(String.self, forKey: .title)
        percent = try c.decode(Int.self, forKey: .percent)
        completed = try c.decode(Bool.self, forKey: .completed)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority)
        due = try c.decodeIfPresent(String.self, forKey: .due)
        etag = try c.decode(String.self, forKey: .etag)
        assignees = try c.decodeIfPresent([String].self, forKey: .assignees) ?? []
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(
        taskId: String, planId: String = "", bucketId: String = "",
        title: String, percent: Int = 0, completed: Bool = false,
        priority: Int? = nil, due: String? = nil, etag: String = "",
        assignees: [String] = []
    ) {
        self.taskId = taskId
        self.planId = planId
        self.bucketId = bucketId
        self.title = title
        self.percent = percent
        self.completed = completed
        self.priority = priority
        self.due = due
        self.etag = etag
        self.assignees = assignees
    }

    /// Same task with other assignees (demo edits).
    public func with(assignees: [String]) -> PlannerTask {
        PlannerTask(taskId: taskId, planId: planId, bucketId: bucketId, title: title,
                    percent: percent, completed: completed, priority: priority, due: due,
                    etag: etag, assignees: assignees)
    }

    /// Server stamp shifted to local (ChatMessage rules).
    public var displayDue: String? {
        due.map { ChatMessage.shortTime($0) }
    }
}

public struct PlannerTasksResponse: Decodable, Sendable {
    public let ok: Bool
    public let plan_id: String?
    public let tasks: [PlannerTask]
}

/// `{ok,task}` from `ostmac_planner_add` / `ostmac_planner_done` /
/// `ostmac_planner_reopen`.
public struct PlannerTaskResult: Decodable, Sendable {
    public let ok: Bool
    public let task: PlannerTask
}

/// One person who can be assigned a Planner task (a member of the
/// plan's team): `id` = the Azure AD user id Planner assignments use.
public struct PlannerMember: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
