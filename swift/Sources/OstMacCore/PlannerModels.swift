// PlannerModels.swift — om-planner lane: Planner boards via Graph.
//
// Wire shapes from core `ostmac_planner_*` (snake_case over FFI,
// camelCase in Swift). Mirrors the om-remind To Do models.

/// One Planner board from core `ostmac_planner_plans`:
/// `{"id","title","categories"?,"etag"?}` (`categories` maps
/// `"categoryN"` to its display name).
public struct PlannerPlan: Codable, Sendable, Identifiable, Equatable {
    public var id: String { planId }
    public let planId: String
    public let title: String
    /// Label display names by number (1...6); empty when unnamed.
    public let categories: [Int: String]
    /// `@odata.etag` verbatim (plan DELETE/PATCH send it as `If-Match`).
    public let etag: String

    enum CodingKeys: String, CodingKey {
        case planId = "id"
        case title, categories, etag
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(planId: String, title: String, categories: [Int: String] = [:], etag: String = "") {
        self.planId = planId
        self.title = title
        self.categories = categories
        self.etag = etag
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        planId = try c.decode(String.self, forKey: .planId)
        title = try c.decode(String.self, forKey: .title)
        let raw = try c.decodeIfPresent([String: String].self, forKey: .categories) ?? [:]
        var cats: [Int: String] = [:]
        for (k, v) in raw {
            if let n = Int(k.replacingOccurrences(of: "category", with: "")), (1...6).contains(n) {
                cats[n] = v
            }
        }
        categories = cats
        etag = try c.decodeIfPresent(String.self, forKey: .etag) ?? ""
    }

    /// Display name for a label number, else "Label N".
    public func labelName(_ n: Int) -> String {
        categories[n] ?? "Label \(n)"
    }
}

public struct PlannerPlansResponse: Decodable, Sendable {
    public let ok: Bool
    public let group_id: String?
    public let plans: [PlannerPlan]
}

/// One board column from core `ostmac_planner_buckets`:
/// `{"id","plan_id","name"}`.
public struct PlannerBucket: Codable, Sendable, Identifiable, Equatable {
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
/// "assignees","labels"?,"thread"?}` (assignees = user ids, labels =
/// applied category numbers; absent reads as none).
public struct PlannerTask: Codable, Sendable, Identifiable, Equatable {
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
    /// `@odata.etag` verbatim; complete/reopen/assign/labels send it back as `If-Match`.
    public let etag: String
    /// Assigned user ids (sorted by core); empty when unassigned.
    public let assignees: [String]
    /// Applied label numbers (1...6, sorted by core); empty when unlabeled.
    public let labels: [Int]
    /// Group conversation thread backing Planner comments; empty until
    /// the first comment exists.
    public let threadID: String

    enum CodingKeys: String, CodingKey {
        case taskId = "id"
        case planId = "plan_id"
        case bucketId = "bucket_id"
        case title, percent, completed, priority, due, etag, assignees, labels
        case threadID = "thread"
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
        labels = try c.decodeIfPresent([Int].self, forKey: .labels) ?? []
        threadID = try c.decodeIfPresent(String.self, forKey: .threadID) ?? ""
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(
        taskId: String, planId: String = "", bucketId: String = "",
        title: String, percent: Int = 0, completed: Bool = false,
        priority: Int? = nil, due: String? = nil, etag: String = "",
        assignees: [String] = [], labels: [Int] = [], threadID: String = ""
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
        self.labels = labels
        self.threadID = threadID
    }

    /// Same task with other assignees (demo edits).
    public func with(assignees: [String]) -> PlannerTask {
        PlannerTask(taskId: taskId, planId: planId, bucketId: bucketId, title: title,
                    percent: percent, completed: completed, priority: priority, due: due,
                    etag: etag, assignees: assignees, labels: labels, threadID: threadID)
    }

    /// Same task with other labels (demo edits).
    public func with(labels: [Int]) -> PlannerTask {
        PlannerTask(taskId: taskId, planId: planId, bucketId: bucketId, title: title,
                    percent: percent, completed: completed, priority: priority, due: due,
                    etag: etag, assignees: assignees, labels: labels.sorted(), threadID: threadID)
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

/// One checklist item on task details from core `ostmac_planner_details`:
/// `{"id","title","checked"}`.
public struct PlannerChecklistItem: Codable, Sendable, Identifiable, Equatable {
    public var id: String { itemId }
    public let itemId: String
    public let title: String
    public let checked: Bool

    enum CodingKeys: String, CodingKey {
        case itemId = "id"
        case title, checked
    }

    public init(itemId: String, title: String, checked: Bool) {
        self.itemId = itemId
        self.title = title
        self.checked = checked
    }
}

/// One external reference on task details: `{"url","alias"}`.
public struct PlannerReference: Codable, Sendable, Identifiable, Equatable {
    public var id: String { url }
    public let url: String
    public let alias: String

    public init(url: String, alias: String) {
        self.url = url
        self.alias = alias
    }
}

/// Task details from core `ostmac_planner_details`:
/// `{ok,task_id,details:{etag,description,preview?,checklist,references}}`.
public struct PlannerTaskDetails: Codable, Sendable, Equatable {
    public let etag: String
    public let description: String
    public let preview: String?
    public let checklist: [PlannerChecklistItem]
    public let references: [PlannerReference]

    public init(
        etag: String = "", description: String = "", preview: String? = nil,
        checklist: [PlannerChecklistItem] = [], references: [PlannerReference] = []
    ) {
        self.etag = etag
        self.description = description
        self.preview = preview
        self.checklist = checklist
        self.references = references
    }
}

public struct PlannerDetailsResponse: Decodable, Sendable {
    public let ok: Bool
    public let task_id: String?
    public let details: PlannerTaskDetails

    public init(ok: Bool, task_id: String? = nil, details: PlannerTaskDetails = .init()) {
        self.ok = ok
        self.task_id = task_id
        self.details = details
    }
}

/// One plan-thread post (a Planner comment) from core
/// `ostmac_planner_comments`: `{id,kind?,content,received?}`.
public struct PlannerComment: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: String?
    public let content: String
    public let received: String?

    public init(id: String, kind: String? = nil, content: String, received: String? = nil) {
        self.id = id
        self.kind = kind
        self.content = content
        self.received = received
    }

    /// Plain-text rendering (server may send html).
    public var text: String {
        guard let kind, kind.lowercased() == "html" else { return content }
        var out = ""
        var inTag = false
        for ch in content {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { out.append(ch) }
        }
        return out
    }
}

public struct PlannerCommentsResponse: Decodable, Sendable {
    public let ok: Bool
    public let group_id: String?
    public let thread_id: String?
    public let posts: [PlannerComment]
}

/// `{ok,plan}` from `ostmac_planner_plan_create` /
/// `ostmac_planner_plan_categories`.
public struct PlannerPlanResult: Decodable, Sendable {
    public let ok: Bool
    public let plan: PlannerPlan
}

/// `{ok,bucket}` from `ostmac_planner_bucket_create`.
public struct PlannerBucketResult: Decodable, Sendable {
    public let ok: Bool
    public let bucket: PlannerBucket
}
