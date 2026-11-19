// ApprovalModels.swift — approvals lane: Teams Approvals (Power
// Automate-backed) item, response and flow-status models.
//
// Data path (R0): the Approvals hub reads the Graph beta Approvals app
// API (`/solutions/approval/approvalItems`, delegated scope
// `ApprovalSolution.ReadWrite`, work/school accounts only, no
// application permission). The backing store is the Power Automate
// approvals connector + the Dataverse `msdyn_flow_approval` table in
// the default environment. Responding posts
// `/solutions/approval/approvalItems/{id}/responses` with
// `{response: "Approve"|"Reject"|custom, comments?}` (scope
// `ApprovalSolution.ReadWrite`, higher
// `ApprovalSolutionResponse.ReadWrite`). Live trial probe 11-19: 401
// "required scope(s) or role(s) not present" — the token lacks the
// scope, so live use needs admin consent (owner OK) and the store
// fails closed with a consent message until then.
import Foundation

/// Approval item state (`approvalItemState`).
public enum ApprovalState: String, Sendable, Equatable {
    case canceled
    case created
    case pending
    case completed
    /// Forward-compat: the service added a state we don't know.
    case unknown

    public init(raw: String?) {
        guard let raw else { self = .unknown; return }
        self = ApprovalState(rawValue: raw) ?? .unknown
    }
}

/// Approval workflow type (`approvalItemType`).
public enum ApprovalWorkflowType: String, Sendable, Equatable {
    case basic
    case basicAwaitAll = "basicAwaitAll"
    case custom
    case customAwaitAll = "customAwaitAll"
    case unknown

    public init(raw: String?) {
        guard let raw else { self = .unknown; return }
        self = ApprovalWorkflowType(rawValue: raw) ?? .unknown
    }
}

/// One approver or the owner (`approvalIdentitySet`: user identity only;
/// device/application sets never appear on approval items).
public struct ApprovalPerson: Sendable, Equatable, Codable {
    public var id: String?
    public var displayName: String

    public init(id: String? = nil, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    private enum OuterKeys: String, CodingKey { case user }
    private enum UserKeys: String, CodingKey { case id, displayName }

    public init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: OuterKeys.self)
        if outer.contains(.user) {
            let user = try outer.nestedContainer(keyedBy: UserKeys.self, forKey: .user)
            id = try user.decodeIfPresent(String.self, forKey: .id)
            displayName = (try user.decodeIfPresent(String.self, forKey: .displayName)) ?? "Unknown Person"
        } else {
            id = nil
            displayName = "Unknown Person"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var outer = encoder.container(keyedBy: OuterKeys.self)
        var user = outer.nestedContainer(keyedBy: UserKeys.self, forKey: .user)
        try user.encodeIfPresent(id, forKey: .id)
        try user.encode(displayName, forKey: .displayName)
    }
}

/// One approval request (`approvalItem`).
public struct ApprovalItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var itemDescription: String?
    public var workflowType: ApprovalWorkflowType
    public var state: ApprovalState
    /// Final result (`"Approved"`/`"Rejected"`/custom), set when completed.
    public var result: String?
    public var createdDateTime: Date?
    public var completedDateTime: Date?
    public var allowCancel: Bool
    public var owner: ApprovalPerson?
    public var approvers: [ApprovalPerson]
    /// Custom response prompts (default: Approve/Reject).
    public var responsePrompts: [String]

    public init(id: String, displayName: String, itemDescription: String? = nil,
                workflowType: ApprovalWorkflowType = .basic, state: ApprovalState = .pending,
                result: String? = nil, createdDateTime: Date? = nil, completedDateTime: Date? = nil,
                allowCancel: Bool = false, owner: ApprovalPerson? = nil,
                approvers: [ApprovalPerson] = [], responsePrompts: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.itemDescription = itemDescription
        self.workflowType = workflowType
        self.state = state
        self.result = result
        self.createdDateTime = createdDateTime
        self.completedDateTime = completedDateTime
        self.allowCancel = allowCancel
        self.owner = owner
        self.approvers = approvers
        self.responsePrompts = responsePrompts
    }

    /// Decided (completed or canceled): actions lock.
    public var isDecided: Bool { state == .completed || state == .canceled }
    /// The owner may cancel: pending and the service allows it.
    public var canCancel: Bool { allowCancel && !isDecided }
}

/// One approver decision (`approvalItemResponse`).
public struct ApprovalItemResponse: Sendable, Equatable, Identifiable {
    public var id: String?
    public var response: String
    public var comments: String?
    public var responder: ApprovalPerson?
    public var createdDateTime: Date?

    public init(id: String? = nil, response: String, comments: String? = nil,
                responder: ApprovalPerson? = nil, createdDateTime: Date? = nil) {
        self.id = id
        self.response = response
        self.comments = comments
        self.responder = responder
        self.createdDateTime = createdDateTime
    }

    /// Positive decision: the default "Approve" prompt or the custom
    /// first prompt. Anything else counts as a rejection for flow status.
    public func isApproval(prompts: [String] = []) -> Bool {
        let positive = prompts.first ?? "Approve"
        return response.caseInsensitiveCompare(positive) == .orderedSame
            || response.caseInsensitiveCompare("Approve") == .orderedSame
    }
}

extension ApprovalItem: Decodable {
    private enum Keys: String, CodingKey {
        case id, displayName, description, approvalType, approvers, owner
        case responsePrompts, allowCancel
        case state, result, createdDateTime, completedDateTime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        itemDescription = try c.decodeIfPresent(String.self, forKey: .description)
        workflowType = ApprovalWorkflowType(raw: try c.decodeIfPresent(String.self, forKey: .approvalType))
        state = ApprovalState(raw: try c.decodeIfPresent(String.self, forKey: .state))
        result = try c.decodeIfPresent(String.self, forKey: .result)
        createdDateTime = try c.decodeIfPresent(Date.self, forKey: .createdDateTime)
        completedDateTime = try c.decodeIfPresent(Date.self, forKey: .completedDateTime)
        allowCancel = (try c.decodeIfPresent(Bool.self, forKey: .allowCancel)) ?? false
        owner = try c.decodeIfPresent(ApprovalPerson.self, forKey: .owner)
        approvers = (try c.decodeIfPresent([ApprovalPerson].self, forKey: .approvers)) ?? []
        responsePrompts = (try c.decodeIfPresent([String].self, forKey: .responsePrompts)) ?? []
    }
}

extension ApprovalItemResponse: Decodable {
    private enum Keys: String, CodingKey {
        case id, response, comments, createdDateTime, responder, user
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        response = (try c.decodeIfPresent(String.self, forKey: .response)) ?? ""
        comments = try c.decodeIfPresent(String.self, forKey: .comments)
        createdDateTime = try c.decodeIfPresent(Date.self, forKey: .createdDateTime)
        if c.contains(.responder) {
            responder = try c.decodeIfPresent(ApprovalPerson.self, forKey: .responder)
        } else if c.contains(.user) {
            struct NameBox: Decodable {
                var id: String?
                var displayName: String?
            }
            if let user = try c.decodeIfPresent(NameBox.self, forKey: .user) {
                responder = ApprovalPerson(id: user.id, displayName: user.displayName ?? "Unknown Person")
            } else {
                responder = nil
            }
        } else {
            responder = nil
        }
    }
}

/// Per-approver flow state for the detail pane.
public struct ApproverFlowState: Sendable, Equatable {
    public var person: ApprovalPerson
    public var response: String?
    public var comments: String?
    public var isPositive: Bool
}

/// Flow status: the item's overall state plus one row per approver.
/// Pure (unit-tested); the view renders it verbatim.
public struct ApprovalFlowStatus: Sendable, Equatable {
    public var headline: String
    public var rows: [ApproverFlowState]
    /// Approvers still to decide (empty when decided).
    public var waitingOn: [ApprovalPerson]

    /// Derive from the item and its responses (latest response per
    /// responder wins; matching is by responder display name, then id).
    public static func compute(item: ApprovalItem, responses: [ApprovalItemResponse]) -> ApprovalFlowStatus {
        var latest: [String: ApprovalItemResponse] = [:]
        for r in responses {
            let key = r.responder?.id ?? r.responder?.displayName ?? r.id ?? UUID().uuidString
            latest[key] = r
        }
        func match(_ p: ApprovalPerson) -> ApprovalItemResponse? {
            if let id = p.id, let r = latest[id] { return r }
            return latest[p.displayName]
        }
        let rows = item.approvers.map { person -> ApproverFlowState in
            guard let r = match(person) else {
                return ApproverFlowState(person: person, response: nil, comments: nil, isPositive: false)
            }
            return ApproverFlowState(person: person, response: r.response, comments: r.comments,
                                      isPositive: r.isApproval(prompts: item.responsePrompts))
        }
        switch item.state {
        case .canceled:
            return ApprovalFlowStatus(headline: "Canceled", rows: rows, waitingOn: [])
        case .completed:
            return ApprovalFlowStatus(headline: item.result ?? "Completed", rows: rows, waitingOn: [])
        case .created:
            return ApprovalFlowStatus(headline: "Not started", rows: rows, waitingOn: item.approvers)
        case .pending, .unknown:
            let waiting = rows.filter { $0.response == nil }.map(\.person)
            let decided = rows.count - waiting.count
            let headline: String
            if item.approvers.isEmpty {
                headline = decided > 0 ? "Waiting for the result" : "No approvers assigned"
            } else if waiting.isEmpty {
                headline = "Waiting for the result"
            } else {
                headline = "Waiting on \(waiting.count) of \(item.approvers.count)"
            }
            return ApprovalFlowStatus(headline: headline, rows: rows, waitingOn: waiting)
        }
    }
}
