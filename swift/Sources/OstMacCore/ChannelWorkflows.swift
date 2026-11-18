// ChannelWorkflows.swift — channel-scoped Workflows (FIXPACK-UI R3).
//
// Teams' Workflows are Power Automate flows. This sign-in has no
// Power Automate token, so the live source is `UnavailableWorkflowsAPI`
// (says so, never fakes a list, never writes). The demo source is an
// in-memory fake, which is the only place add / enable / run act. The
// store owns the list state the sheet shows; a real source drops in
// behind `ChannelWorkflowsAPI` without touching the UI.
import Foundation

public struct ChannelWorkflow: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    /// What starts it, e.g. "When a message is posted to this channel".
    public var trigger: String
    public var isEnabled: Bool
    public var lastRun: Date?
    /// nil = never ran.
    public var lastRunSucceeded: Bool?

    public init(id: String, name: String, trigger: String, isEnabled: Bool = true,
                lastRun: Date? = nil, lastRunSucceeded: Bool? = nil) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.isEnabled = isEnabled
        self.lastRun = lastRun
        self.lastRunSucceeded = lastRunSucceeded
    }
}

public struct WorkflowTemplate: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let trigger: String

    public init(id: String, name: String, trigger: String) {
        self.id = id
        self.name = name
        self.trigger = trigger
    }
}

public enum ChannelWorkflowsError: Error, Equatable, Sendable {
    /// This source cannot do it at all (shown as the pane's reason).
    case unsupported(String)
    case failed(String)

    public var message: String {
        switch self {
        case .unsupported(let m), .failed(let m): m
        }
    }
}

public protocol ChannelWorkflowsAPI: Sendable {
    func list(teamID: String, channelID: String) async throws -> [ChannelWorkflow]
    func templates() async throws -> [WorkflowTemplate]
    func add(template: WorkflowTemplate, teamID: String, channelID: String) async throws -> ChannelWorkflow
    func setEnabled(_ enabled: Bool, workflowID: String) async throws -> ChannelWorkflow
    /// Runs it once now; returns the workflow with its new last run.
    func run(workflowID: String) async throws -> ChannelWorkflow
}

/// The live source until a Power Automate token exists: every call says
/// why it cannot. No network, no writes.
public struct UnavailableWorkflowsAPI: ChannelWorkflowsAPI {
    public static let reason = "Workflows are Power Automate flows, and this sign-in can't read them."
    public init() {}
    public func list(teamID: String, channelID: String) async throws -> [ChannelWorkflow] {
        throw ChannelWorkflowsError.unsupported(Self.reason)
    }
    public func templates() async throws -> [WorkflowTemplate] { throw ChannelWorkflowsError.unsupported(Self.reason) }
    public func add(template: WorkflowTemplate, teamID: String, channelID: String) async throws -> ChannelWorkflow {
        throw ChannelWorkflowsError.unsupported(Self.reason)
    }
    public func setEnabled(_ enabled: Bool, workflowID: String) async throws -> ChannelWorkflow {
        throw ChannelWorkflowsError.unsupported(Self.reason)
    }
    public func run(workflowID: String) async throws -> ChannelWorkflow {
        throw ChannelWorkflowsError.unsupported(Self.reason)
    }
}

/// In-memory fake (demo and tests). Two seeded workflows per channel.
public actor DemoWorkflowsAPI: ChannelWorkflowsAPI {
    private var byChannel: [String: [ChannelWorkflow]] = [:]
    private var channelOf: [String: String] = [:]
    private var counter = 0
    private let now: @Sendable () -> Date
    /// Test hook: the next `run` fails once.
    private var failNextRun = false

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    public static let catalog: [WorkflowTemplate] = [
        WorkflowTemplate(id: "webhook", name: "Post to this channel when a webhook request is received",
                         trigger: "When a webhook request arrives"),
        WorkflowTemplate(id: "daily", name: "Post a reminder to this channel every weekday",
                         trigger: "Every weekday at 9:00 AM"),
        WorkflowTemplate(id: "welcome", name: "Welcome new members to this channel",
                         trigger: "When someone joins the team"),
    ]

    public func failNextRunOnce() { failNextRun = true }

    private func seed(_ channelID: String) {
        guard byChannel[channelID] == nil else { return }
        let a = ChannelWorkflow(id: "demo-wf-\(channelID)-1", name: "Post a reminder to this channel every weekday",
                                trigger: "Every weekday at 9:00 AM", isEnabled: true,
                                lastRun: now().addingTimeInterval(-3_600), lastRunSucceeded: true)
        let b = ChannelWorkflow(id: "demo-wf-\(channelID)-2", name: "Welcome new members to this channel",
                                trigger: "When someone joins the team", isEnabled: false)
        byChannel[channelID] = [a, b]
        channelOf[a.id] = channelID
        channelOf[b.id] = channelID
    }

    public func list(teamID: String, channelID: String) async throws -> [ChannelWorkflow] {
        seed(channelID)
        return byChannel[channelID] ?? []
    }

    public func templates() async throws -> [WorkflowTemplate] { Self.catalog }

    public func add(template: WorkflowTemplate, teamID: String, channelID: String) async throws -> ChannelWorkflow {
        seed(channelID)
        counter += 1
        let w = ChannelWorkflow(id: "demo-wf-new-\(counter)", name: template.name, trigger: template.trigger)
        byChannel[channelID, default: []].append(w)
        channelOf[w.id] = channelID
        return w
    }

    private func update(_ id: String, _ change: (inout ChannelWorkflow) -> Void) throws -> ChannelWorkflow {
        guard let ch = channelOf[id], let i = byChannel[ch]?.firstIndex(where: { $0.id == id }) else {
            throw ChannelWorkflowsError.failed("That workflow no longer exists.")
        }
        change(&byChannel[ch]![i])
        return byChannel[ch]![i]
    }

    public func setEnabled(_ enabled: Bool, workflowID: String) async throws -> ChannelWorkflow {
        try update(workflowID) { $0.isEnabled = enabled }
    }

    public func run(workflowID: String) async throws -> ChannelWorkflow {
        let fail = failNextRun
        failNextRun = false
        let at = now()
        let w = try update(workflowID) {
            $0.lastRun = at
            $0.lastRunSucceeded = !fail
        }
        if fail { throw ChannelWorkflowsError.failed("The workflow didn't finish. Try again.") }
        return w
    }
}

public enum ChannelWorkflowsState: Equatable, Sendable {
    case loading
    case loaded
    /// This source can't do workflows at all; the reason is the pane text.
    case unsupported(String)
    case failed(String)
}

/// The list + actions for one channel's Workflows sheet.
@MainActor
public final class ChannelWorkflowsStore: ObservableObject {
    @Published public private(set) var state: ChannelWorkflowsState = .loading
    @Published public private(set) var workflows: [ChannelWorkflow] = []
    @Published public private(set) var templates: [WorkflowTemplate] = []
    /// Workflow ids with an action in flight (row shows a spinner).
    @Published public private(set) var busy: Set<String> = []
    @Published public private(set) var adding = false
    /// Last action failure (add / toggle / run); the list stays.
    @Published public private(set) var actionError: String?

    public let teamID: String
    public let channelID: String
    private let api: ChannelWorkflowsAPI

    public init(api: ChannelWorkflowsAPI, teamID: String, channelID: String) {
        self.api = api
        self.teamID = teamID
        self.channelID = channelID
    }

    /// Whether add / enable / run can work at all.
    public var isSupported: Bool {
        if case .unsupported = state { return false }
        return true
    }

    public func load() async {
        state = .loading
        actionError = nil
        do {
            workflows = try await api.list(teamID: teamID, channelID: channelID)
            templates = (try? await api.templates()) ?? []
            state = .loaded
        } catch let e as ChannelWorkflowsError {
            switch e {
            case .unsupported(let m): state = .unsupported(m)
            case .failed(let m): state = .failed(m)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func add(_ template: WorkflowTemplate) async {
        adding = true
        actionError = nil
        defer { adding = false }
        do {
            workflows.append(try await api.add(template: template, teamID: teamID, channelID: channelID))
        } catch { actionError = Self.text(error) }
    }

    public func setEnabled(_ enabled: Bool, _ id: String) async {
        await act(id) { try await self.api.setEnabled(enabled, workflowID: id) }
    }

    public func run(_ id: String) async {
        await act(id) { try await self.api.run(workflowID: id) }
    }

    private func act(_ id: String, _ op: () async throws -> ChannelWorkflow) async {
        guard !busy.contains(id) else { return }
        busy.insert(id)
        actionError = nil
        defer { busy.remove(id) }
        do {
            let w = try await op()
            if let i = workflows.firstIndex(where: { $0.id == id }) { workflows[i] = w }
        } catch {
            actionError = Self.text(error)
            // A failed run still records its attempt; refresh the row.
            if let fresh = try? await api.list(teamID: teamID, channelID: channelID) { workflows = fresh }
        }
    }

    private static func text(_ e: Error) -> String {
        (e as? ChannelWorkflowsError)?.message ?? e.localizedDescription
    }
}
