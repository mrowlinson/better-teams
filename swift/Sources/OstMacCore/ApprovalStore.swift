// ApprovalStore.swift — approvals lane: the approvals list store.
//
// Demo seeds deterministic fixtures offline (`localEdits` applies
// approve/reject/cancel in memory, like Planner). Live wires
// `ApprovalGraph.production().execute` through blocking fetchers; a
// 401/403 lands as the consent message (the app token lacks
// ApprovalSolution.ReadWrite — admin consent is owner action, so lanes
// never obtain it). Tests inject stub fetchers.
import Combine
import Foundation

/// Approvals content state (mirrors PlannerState).
public enum ApprovalsState: Equatable, Sendable {
    /// Fetch in flight.
    case loading
    /// Non-empty `items`.
    case loaded
    /// Fetch succeeded with zero items.
    case empty
    /// Fetch failed; associated user-facing message.
    case error(String)
}

@MainActor
public final class ApprovalStore: ObservableObject {
    public typealias ListFetcher = @Sendable () throws -> Data
    public typealias ResponsesFetcher = @Sendable (String) throws -> Data
    public typealias RespondSender = @Sendable (String, String, String?) throws -> Data
    public typealias CancelSender = @Sendable (String) throws -> Data

    /// Latest items (only meaningful in `.loaded`; stale otherwise).
    @Published public private(set) var items: [ApprovalItem] = []
    /// Current list state. Starts `.loading`.
    @Published public private(set) var state: ApprovalsState = .loading
    /// Responses by item id (loaded on selection).
    @Published public private(set) var responsesByItem: [String: [ApprovalItemResponse]] = [:]
    /// Last approve/reject/cancel failure (user-facing); nil when clear.
    @Published public private(set) var actionError: String?
    /// Response send in flight.
    @Published public private(set) var acting = false

    /// The list's selection (`show(id:)`). A (re)load keeps it.
    public private(set) var selectedID: String?

    private let listFetcher: ListFetcher
    private let responsesFetcher: ResponsesFetcher?
    private let respondSender: RespondSender?
    private let cancelSender: CancelSender?
    private let localEdits: Bool
    private var loadFlight: Task<Void, Never>?

    public init(
        listFetcher: @escaping ListFetcher = { try ApprovalGraph.production().execute(.list) },
        responsesFetcher: ResponsesFetcher? = nil,
        respondSender: RespondSender? = nil,
        cancelSender: CancelSender? = nil,
        localEdits: Bool = false
    ) {
        self.listFetcher = listFetcher
        self.responsesFetcher = responsesFetcher
        self.respondSender = respondSender
        self.cancelSender = cancelSender
        self.localEdits = localEdits
    }

    /// Live store: every leg through the beta Approvals app API.
    /// Until the tenant consents `ApprovalSolution.ReadWrite` these
    /// throw the consent message (the store fails closed, never blank).
    public static func live() -> ApprovalStore {
        ApprovalStore(
            responsesFetcher: { try ApprovalGraph.production().execute(.responses($0)) },
            respondSender: { try ApprovalGraph.production().execute(.respond(id: $0, response: $1, comments: $2)) },
            cancelSender: { try ApprovalGraph.production().execute(.cancel($0)) })
    }

    /// Demo store: deterministic fixtures, all edits in memory.
    public static func demo() -> ApprovalStore {
        ApprovalStore(
            listFetcher: { try ApprovalDemo.listData() },
            responsesFetcher: { try ApprovalDemo.responsesData(for: $0) },
            respondSender: { _, _, _ in Data() },
            cancelSender: { _ in Data() },
            localEdits: true)
    }

    public var selected: ApprovalItem? {
        guard let id = selectedID else { return nil }
        return items.first { $0.id == id }
    }

    public func flowStatus(for id: String) -> ApprovalFlowStatus? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        return ApprovalFlowStatus.compute(item: item, responses: responsesByItem[id] ?? [])
    }

    /// The list's selection wins; responses load from the selection.
    public func show(id: String?) {
        guard selectedID != id else { return }
        selectedID = id
        actionError = nil
        if let id { loadResponses(for: id) }
    }

    /// Fetch the list (shared in-flight load; every waiter gets it).
    public func load() async {
        if let flight = loadFlight { await flight.value; return }
        let flight = Task<Void, Never> { await self.runLoad() }
        loadFlight = flight
        await flight.value
        loadFlight = nil
    }

    private func runLoad() async {
        state = .loading
        let fetcher = listFetcher
        do {
            let data = try await Task.blocking { try fetcher() }.value
            let items = try Self.decodeList(data)
            self.items = items
            state = items.isEmpty ? .empty : .loaded
            if selectedID == nil { selectedID = items.first?.id }
            if let id = selectedID, responsesByItem[id] == nil { loadResponses(for: id) }
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Fire-and-forget reload (toolbar Refresh, error-state Retry).
    public func refresh() {
        Task { await load() }
    }

    /// Load one item's responses (detail flow status).
    public func loadResponses(for id: String) {
        guard let fetcher = responsesFetcher else { return }
        Task {
            do {
                let data = try await Task.blocking { try fetcher(id) }.value
                responsesByItem[id] = try Self.decodeResponses(data)
            } catch {
                actionError = Self.message(for: error)
            }
        }
    }

    /// Approve or reject the item (optional comment). Demo applies the
    /// decision in memory; live posts the response, then reloads.
    public func respond(id: String, response: String, comments: String? = nil) {
        guard !acting, let index = items.firstIndex(where: { $0.id == id }),
              !items[index].isDecided else { return }
        acting = true
        actionError = nil
        Task {
            defer { acting = false }
            do {
                if localEdits {
                    applyLocalResponse(id: id, response: response, comments: comments)
                } else {
                    guard let sender = respondSender else {
                        actionError = "approvals: responding is unavailable (no transport)."
                        return
                    }
                    let captured = (id, response, comments)
                    _ = try await Task.blocking {
                        try sender(captured.0, captured.1, captured.2)
                    }.value
                    applyLocalResponse(id: id, response: response, comments: comments)
                }
            } catch {
                actionError = Self.message(for: error)
            }
        }
    }

    /// Cancel the item (owner only; the service enforces ownership).
    public func cancel(id: String) {
        guard !acting, let index = items.firstIndex(where: { $0.id == id }),
              items[index].canCancel else { return }
        acting = true
        actionError = nil
        Task {
            defer { acting = false }
            do {
                if !localEdits {
                    guard let sender = cancelSender else {
                        actionError = "approvals: cancel is unavailable (no transport)."
                        return
                    }
                    _ = try await Task.blocking { try sender(id) }.value
                }
                if let i = items.firstIndex(where: { $0.id == id }) {
                    items[i].state = .canceled
                }
            } catch {
                actionError = Self.message(for: error)
            }
        }
    }

    private func applyLocalResponse(id: String, response: String, comments: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let decision = ApprovalItemResponse(
            response: response, comments: comments,
            responder: ApprovalPerson(displayName: "You"), createdDateTime: Date())
        var list = responsesByItem[id] ?? []
        list.append(decision)
        responsesByItem[id] = list
        if items[index].workflowType == .basicAwaitAll || items[index].workflowType == .customAwaitAll {
            // Everyone must decide: complete only when no approver is waiting.
            let status = ApprovalFlowStatus.compute(item: items[index], responses: list)
            if status.waitingOn.isEmpty {
                items[index].state = .completed
                items[index].result = decision.isApproval(prompts: items[index].responsePrompts)
                    ? "Approved" : "Rejected"
                items[index].completedDateTime = Date()
            }
        } else {
            items[index].state = .completed
            items[index].result = decision.isApproval(prompts: items[index].responsePrompts)
                ? "Approved" : "Rejected"
            items[index].completedDateTime = Date()
        }
    }

    // MARK: decoding

    struct ListBox: Decodable {
        var items: [ApprovalItem]
        init(from decoder: Decoder) throws {
            // Collection GET returns `{"value":[...]}`; single-item GET
            // returns the object. SingleValue gives both shapes one shot.
            let single = try decoder.singleValueContainer()
            if let box = try? single.decode(ValueBox.self) {
                items = box.value ?? []
            } else {
                items = [try single.decode(ApprovalItem.self)]
            }
        }
        struct ValueBox: Decodable {
            var value: [ApprovalItem]?
        }
    }

    struct ResponsesBox: Decodable {
        var value: [ApprovalItemResponse]
    }

    static func decodeList(_ data: Data) throws -> [ApprovalItem] {
        try ApprovalGraph.decoder().decode(ListBox.self, from: data).items
    }

    static func decodeResponses(_ data: Data) throws -> [ApprovalItemResponse] {
        (try? ApprovalGraph.decoder().decode(ResponsesBox.self, from: data))?.value ?? []
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return "approvals: \(error.localizedDescription)"
    }
}
