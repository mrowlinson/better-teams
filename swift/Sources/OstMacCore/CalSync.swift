// CalSync.swift — CALENDAR two-way sync engine, BUILD ONLY lane.
//
// Zero live calls by construction: this file contains NO Graph HTTP and NO
// EventKit imports. All I/O flows through the `CalGraphTransport`, `EKSink`
// and `GraphSink` protocols, whose only conformances in this lane are the
// mocks in CalSyncMocks.swift. Live conformances arrive in a later lane
// behind the same guard gates.
//
// SAFETY (binding, test-pinned in CalSyncTests.swift):
//  1. dry-run default ON: plans log every write, execute none. Live
//     execution additionally requires the explicit per-account
//     `liveWritesEnabled` flag.
//  2. Date window enforced in code: default +-30d, HARD MAX 90d radius.
//     A requested radius >90d is REJECTED (never clamped down silently),
//     so no full-history pull is expressible.
//  3. Target-account allowlist holds ONE UPN. Empty/non-matching account
//     refuses ALL ops (both directions).
//  4. Deletion propagation sits behind `deletionPropagationEnabled`,
//     default OFF. Without it, deletes are HELD (logged, never executed,
//     even in live mode).
//
// CONFLICT RULE (lane decision, documented): Teams-wins-with-log. When the
// same event changed on both sides since the last sync, the Graph version
// wins; the local change is dropped and the drop is logged with both
// timestamps. Rationale: the Teams/Graph copy is the shared,
// multi-device source of truth; a one-sided local edit must never
// silently clobber it. The log entry preserves the local payload summary
// for forensics.
import Foundation

// MARK: - Errors

public enum CalSyncError: Error, Equatable, Sendable {
    /// Allowlist holds no UPN: refuse everything.
    case allowlistEmpty
    /// Op account does not match the single allowlisted UPN.
    case allowlistMismatch(expected: String, got: String)
    /// Requested window radius exceeds the hard max. Never clamped.
    case windowTooLarge(requestedDays: Int, maxDays: Int)
    /// Live execution attempted without the explicit enablement flag.
    case liveWritesNotEnabled
}

// MARK: - Config + window

public struct CalSyncConfig: Sendable, Equatable {
    /// Single allowlisted target-account UPN. nil/empty = refuse all ops.
    public var targetUPN: String?
    /// Guard 1: default ON. All writes logged, none executed.
    public var dryRun: Bool = true
    /// Guard 1b: live execution ALSO requires this explicit per-account flag.
    public var liveWritesEnabled: Bool = false
    /// +-day radius. Default 30, hard max 90 (see `maxWindowDays`).
    public var windowDays: Int = CalSyncConfig.defaultWindowDays
    /// Guard 4: delete propagation, default OFF.
    public var deletionPropagationEnabled: Bool = false

    public static let defaultWindowDays = 30
    public static let maxWindowDays = 90

    public init(
        targetUPN: String? = nil,
        dryRun: Bool = true,
        liveWritesEnabled: Bool = false,
        windowDays: Int = CalSyncConfig.defaultWindowDays,
        deletionPropagationEnabled: Bool = false
    ) {
        self.targetUPN = targetUPN
        self.dryRun = dryRun
        self.liveWritesEnabled = liveWritesEnabled
        self.windowDays = windowDays
        self.deletionPropagationEnabled = deletionPropagationEnabled
    }

    /// Guard 2: radius >90 rejected. Radius <1 clamped UP to the default
    /// (logged by the planner) so a zero/negative window can never widen
    /// into an unbounded pull.
    public func validatedWindowRadius() throws -> Int {
        if windowDays > Self.maxWindowDays {
            throw CalSyncError.windowTooLarge(
                requestedDays: windowDays, maxDays: Self.maxWindowDays)
        }
        if windowDays < 1 { return Self.defaultWindowDays }
        return windowDays
    }

    /// Guard 3: the op account must equal the single allowlisted UPN
    /// (case-insensitive, whitespace-trimmed).
    public func authorize(accountUPN: String) throws -> String {
        let want = (targetUPN ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !want.isEmpty else { throw CalSyncError.allowlistEmpty }
        let got = accountUPN.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard got.lowercased() == want.lowercased() else {
            throw CalSyncError.allowlistMismatch(expected: want, got: got)
        }
        return want
    }

    /// Guard 1: true only when dry-run is OFF *and* the explicit live flag
    /// is ON. Every other combination executes nothing.
    public var liveExecutionAllowed: Bool {
        !dryRun && liveWritesEnabled
    }
}

/// Concrete UTC window derived from a validated radius around `now`.
public struct CalSyncWindow: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let radiusDays: Int

    public init(radiusDays: Int, now: Date = Date()) {
        self.radiusDays = radiusDays
        let day: TimeInterval = 86_400
        start = now.addingTimeInterval(-day * Double(radiusDays))
        end = now.addingTimeInterval(day * Double(radiusDays))
    }
}

// MARK: - Decision log

public struct CalSyncLogEntry: Sendable, Equatable {
    public let at: Date
    public let kind: String
    public let detail: String

    public init(at: Date = Date(), kind: String, detail: String) {
        self.at = at
        self.kind = kind
        self.detail = detail
    }
}

// MARK: - Graph delta-read shapes (transport-agnostic)

/// One event row from a Graph calendar delta feed.
public struct GraphDeltaEvent: Sendable, Equatable {
    public let id: String
    public let subject: String?
    public let start: String?
    public let end: String?
    /// Last-modified marker for conflict comparison (ISO string compare).
    public let updatedAt: String?
    /// Tombstone: the event was deleted on the Graph side.
    public let deleted: Bool

    public init(
        id: String, subject: String? = nil, start: String? = nil,
        end: String? = nil, updatedAt: String? = nil, deleted: Bool = false
    ) {
        self.id = id
        self.subject = subject
        self.start = start
        self.end = end
        self.updatedAt = updatedAt
        self.deleted = deleted
    }
}

/// One page of delta results. `deltaLink` non-nil = sync checkpoint
/// (no more pages); `nextLink` non-nil = fetch another page first.
public struct CalDeltaPage: Sendable, Equatable {
    public let events: [GraphDeltaEvent]
    public let deltaLink: String?
    public let nextLink: String?

    public init(
        events: [GraphDeltaEvent], deltaLink: String? = nil,
        nextLink: String? = nil
    ) {
        self.events = events
        self.deltaLink = deltaLink
        self.nextLink = nextLink
    }

    public var isCheckpoint: Bool { deltaLink != nil }
}

/// Fetches Graph delta pages. ONLY mock conformances exist in this lane.
public protocol CalGraphTransport: Sendable {
    func fetchDelta(
        since deltaLink: String?, window: CalSyncWindow
    ) throws -> CalDeltaPage
}

// MARK: - EventKit-side shapes (EventKit-shaped, never imports EventKit)

/// One local change observed on the EventKit side.
public struct EKEventChange: Sendable, Equatable {
    /// Local store identifier.
    public let localID: String
    /// Graph id when previously synced; nil = locally created.
    public let graphID: String?
    public let subject: String?
    public let start: String?
    public let end: String?
    public let updatedAt: String?
    public let deleted: Bool

    public init(
        localID: String, graphID: String? = nil,
        subject: String? = nil, start: String? = nil,
        end: String? = nil, updatedAt: String? = nil,
        deleted: Bool = false
    ) {
        self.localID = localID
        self.graphID = graphID
        self.subject = subject
        self.start = start
        self.end = end
        self.updatedAt = updatedAt
        self.deleted = deleted
    }
}

/// Write op applied TO the EventKit side (inbound direction).
public enum EKWriteOp: Sendable, Equatable {
    case create(graphID: String, subject: String?, start: String?, end: String?)
    case update(graphID: String, subject: String?, start: String?, end: String?)
    case delete(graphID: String)

    public var graphID: String {
        switch self {
        case let .create(id, _, _, _): return id
        case let .update(id, _, _, _): return id
        case let .delete(id): return id
        }
    }

    public var isDelete: Bool {
        if case .delete = self { return true }
        return false
    }
}

/// Write op applied TO the Graph side (outbound direction).
public enum GraphWriteOp: Sendable, Equatable {
    case create(localID: String, subject: String?, start: String?, end: String?)
    case update(graphID: String, subject: String?, start: String?, end: String?)
    case delete(graphID: String)

    public var isDelete: Bool {
        if case .delete = self { return true }
        return false
    }
}

/// A delete withheld by the delete gate (guard 4).
public struct HeldDelete: Sendable, Equatable {
    /// "inbound" (Graph tombstone) or "outbound" (local delete).
    public let direction: String
    public let graphID: String?
    public let localID: String?
    public let reason: String

    public init(
        direction: String, graphID: String? = nil,
        localID: String? = nil, reason: String
    ) {
        self.direction = direction
        self.graphID = graphID
        self.localID = localID
        self.reason = reason
    }
}

// MARK: - Sinks (write targets; mocks only in this lane)

/// Applies ops TO the EventKit side. Mock only in this lane.
public protocol EKSink: Sendable {
    @discardableResult
    func apply(_ ops: [EKWriteOp]) throws -> Int
}

/// Applies ops TO the Graph side. Mock only in this lane.
public protocol GraphSink: Sendable {
    @discardableResult
    func apply(_ ops: [GraphWriteOp]) throws -> Int
}

// MARK: - Plan

/// The planner's output: ops that WOULD run, deletes held, full log.
/// `executed` is always false at plan time; the executor sets the
/// receipt's count after (possibly dry-run) execution.
public struct CalSyncPlan: Sendable, Equatable {
    public let accountUPN: String
    public let window: CalSyncWindow
    public let ekOps: [EKWriteOp]
    public let graphOps: [GraphWriteOp]
    public let heldDeletes: [HeldDelete]
    public let conflictsTeamsWon: [String]
    public let dryRun: Bool
    public let log: [CalSyncLogEntry]

    public init(
        accountUPN: String, window: CalSyncWindow,
        ekOps: [EKWriteOp] = [], graphOps: [GraphWriteOp] = [],
        heldDeletes: [HeldDelete] = [], conflictsTeamsWon: [String] = [],
        dryRun: Bool, log: [CalSyncLogEntry] = []
    ) {
        self.accountUPN = accountUPN
        self.window = window
        self.ekOps = ekOps
        self.graphOps = graphOps
        self.heldDeletes = heldDeletes
        self.conflictsTeamsWon = conflictsTeamsWon
        self.dryRun = dryRun
        self.log = log
    }

    public var pendingWriteCount: Int { ekOps.count + graphOps.count }
}

// MARK: - Planner

public enum CalSyncPlanner {
    /// Inbound: Graph delta page -> EventKit-shaped write ops.
    /// - `knownGraphIDs`: ids already mirrored locally (else CREATE).
    public static func planInbound(
        delta: CalDeltaPage,
        knownGraphIDs: Set<String>,
        config: CalSyncConfig,
        accountUPN: String,
        now: Date = Date()
    ) throws -> CalSyncPlan {
        var log: [CalSyncLogEntry] = []
        func add(_ kind: String, _ detail: String) {
            log.append(CalSyncLogEntry(at: now, kind: kind, detail: detail))
        }

        let who = try config.authorize(accountUPN: accountUPN)
        add("allowlist", "authorized \(who)")
        let radius = try config.validatedWindowRadius()
        if radius != config.windowDays {
            add(
                "window",
                "radius \(config.windowDays) invalid; clamped to default \(radius)")
        } else {
            add("window", "radius +-\(radius)d enforced")
        }
        let window = CalSyncWindow(radiusDays: radius, now: now)

        var ops: [EKWriteOp] = []
        var held: [HeldDelete] = []
        for ev in delta.events {
            if ev.deleted {
                if config.deletionPropagationEnabled {
                    ops.append(.delete(graphID: ev.id))
                    add("delete", "inbound delete planned \(ev.id)")
                } else {
                    held.append(HeldDelete(
                        direction: "inbound", graphID: ev.id,
                        reason: "deletionPropagationEnabled=OFF"))
                    add("delete-held", "inbound delete HELD \(ev.id)")
                }
                continue
            }
            if knownGraphIDs.contains(ev.id) {
                ops.append(.update(
                    graphID: ev.id, subject: ev.subject,
                    start: ev.start, end: ev.end))
                add("map", "inbound update \(ev.id)")
            } else {
                ops.append(.create(
                    graphID: ev.id, subject: ev.subject,
                    start: ev.start, end: ev.end))
                add("map", "inbound create \(ev.id)")
            }
        }
        if config.dryRun {
            add("dry-run", "\(ops.count) EK op(s) logged, 0 executed")
        }
        if let dl = delta.deltaLink {
            add("checkpoint", "deltaLink \(dl)")
        }
        return CalSyncPlan(
            accountUPN: who, window: window, ekOps: ops,
            heldDeletes: held, dryRun: config.dryRun, log: log)
    }

    /// Outbound: EventKit changes -> Graph write ops.
    public static func planOutbound(
        changes: [EKEventChange],
        config: CalSyncConfig,
        accountUPN: String,
        now: Date = Date()
    ) throws -> CalSyncPlan {
        var log: [CalSyncLogEntry] = []
        func add(_ kind: String, _ detail: String) {
            log.append(CalSyncLogEntry(at: now, kind: kind, detail: detail))
        }

        let who = try config.authorize(accountUPN: accountUPN)
        add("allowlist", "authorized \(who)")
        let radius = try config.validatedWindowRadius()
        if radius != config.windowDays {
            add(
                "window",
                "radius \(config.windowDays) invalid; clamped to default \(radius)")
        } else {
            add("window", "radius +-\(radius)d enforced")
        }
        let window = CalSyncWindow(radiusDays: radius, now: now)

        var ops: [GraphWriteOp] = []
        var held: [HeldDelete] = []
        for ch in changes {
            if ch.deleted {
                guard let gid = ch.graphID else {
                    add(
                        "delete-drop",
                        "local delete \(ch.localID) has no graphID; nothing to propagate")
                    continue
                }
                if config.deletionPropagationEnabled {
                    ops.append(.delete(graphID: gid))
                    add("delete", "outbound delete planned \(gid)")
                } else {
                    held.append(HeldDelete(
                        direction: "outbound", graphID: gid,
                        localID: ch.localID,
                        reason: "deletionPropagationEnabled=OFF"))
                    add("delete-held", "outbound delete HELD \(gid)")
                }
                continue
            }
            if let gid = ch.graphID {
                ops.append(.update(
                    graphID: gid, subject: ch.subject,
                    start: ch.start, end: ch.end))
                add("map", "outbound update \(gid)")
            } else {
                ops.append(.create(
                    localID: ch.localID, subject: ch.subject,
                    start: ch.start, end: ch.end))
                add("map", "outbound create local=\(ch.localID)")
            }
        }
        if config.dryRun {
            add("dry-run", "\(ops.count) Graph op(s) logged, 0 executed")
        }
        return CalSyncPlan(
            accountUPN: who, window: window, graphOps: ops,
            heldDeletes: held, dryRun: config.dryRun, log: log)
    }

    /// Bidirectional: inbound delta + outbound changes in one plan with
    /// conflict resolution. Conflict = same graphID touched on BOTH sides:
    /// Teams-wins-with-log (Graph op kept, local op dropped + logged).
    public static func planBidirectional(
        delta: CalDeltaPage,
        knownGraphIDs: Set<String>,
        localChanges: [EKEventChange],
        config: CalSyncConfig,
        accountUPN: String,
        now: Date = Date()
    ) throws -> CalSyncPlan {
        let inbound = try planInbound(
            delta: delta, knownGraphIDs: knownGraphIDs, config: config,
            accountUPN: accountUPN, now: now)
        let outbound = try planOutbound(
            changes: localChanges, config: config, accountUPN: accountUPN,
            now: now)

        let inboundIDs = Set(delta.events.map(\.id))
        var keptGraphOps: [GraphWriteOp] = []
        var teamsWon: [String] = []
        var log = inbound.log + outbound.log
        for op in outbound.graphOps {
            let gid: String?
            switch op {
            case let .update(id, _, _, _): gid = id
            case let .delete(id): gid = id
            case .create: gid = nil
            }
            if let gid, inboundIDs.contains(gid) {
                teamsWon.append(gid)
                log.append(CalSyncLogEntry(
                    at: now, kind: "conflict-teams-wins",
                    detail: "both sides touched \(gid); local change dropped"))
            } else {
                keptGraphOps.append(op)
            }
        }
        return CalSyncPlan(
            accountUPN: inbound.accountUPN, window: inbound.window,
            ekOps: inbound.ekOps, graphOps: keptGraphOps,
            heldDeletes: inbound.heldDeletes + outbound.heldDeletes,
            conflictsTeamsWon: teamsWon, dryRun: config.dryRun, log: log)
    }
}

// MARK: - Delta apply (pure cache update)

public enum CalDeltaApply {
    /// Fold a delta page into a cached `[MeetingItem]` week list keyed by
    /// id: upsert live rows, drop tombstones. Pure; no I/O.
    public static func apply(
        cached: [MeetingItem], delta: CalDeltaPage
    ) -> (merged: [MeetingItem], applied: Int, dropped: Int) {
        var byID: [String: MeetingItem] = [:]
        for m in cached { byID[m.meetingId] = m }
        var applied = 0
        var dropped = 0
        for ev in delta.events {
            if ev.deleted {
                if byID.removeValue(forKey: ev.id) != nil { dropped += 1 }
                continue
            }
            // A delta event carries subject/start/end only; keep the
            // cached row's join link, organizer identity, and online flag
            // (else every delta-updated row lost Join and Cancel Meeting).
            let old = byID[ev.id]
            byID[ev.id] = MeetingItem(
                meetingId: ev.id, subject: ev.subject ?? "(no subject)",
                start: ev.start, end: ev.end, joinURL: old?.joinURL,
                organizer: old?.organizer, organizerEmail: old?.organizerEmail,
                isOrganizer: old?.isOrganizer ?? false, isOnline: old?.isOnline ?? false,
                categories: old?.categories ?? [])
            applied += 1
        }
        let merged = byID.values.sorted {
            ($0.start ?? "~") < ($1.start ?? "~")
        }
        return (merged, applied, dropped)
    }
}

// MARK: - Executor (dry-run gate lives here)

public struct CalSyncReceipt: Sendable, Equatable {
    public let executedEK: Int
    public let executedGraph: Int
    public let wouldExecuteEK: Int
    public let wouldExecuteGraph: Int
    public let heldDeletes: Int
    public let dryRun: Bool
    public let log: [CalSyncLogEntry]

    public var executedTotal: Int { executedEK + executedGraph }
}

public enum CalSyncExecutor {
    /// Execute a plan against the sinks. Dry-run (or missing live flag):
    /// zero sink calls, counts reported as would-execute. Live: requires
    /// `config.liveExecutionAllowed`, else throws `liveWritesNotEnabled`
    /// WITHOUT touching any sink. Held deletes never execute.
    public static func execute(
        plan: CalSyncPlan,
        config: CalSyncConfig,
        ekSink: EKSink,
        graphSink: GraphSink,
        now: Date = Date()
    ) throws -> CalSyncReceipt {
        var log = plan.log
        if plan.dryRun || !config.liveExecutionAllowed {
            if !plan.dryRun, !config.liveWritesEnabled {
                log.append(CalSyncLogEntry(
                    at: now, kind: "refuse-live",
                    detail: "dryRun=OFF but liveWritesEnabled=OFF; executed 0"))
                throw CalSyncError.liveWritesNotEnabled
            }
            log.append(CalSyncLogEntry(
                at: now, kind: "dry-run",
                detail: "logged \(plan.ekOps.count) EK + " +
                    "\(plan.graphOps.count) Graph op(s); executed 0"))
            return CalSyncReceipt(
                executedEK: 0, executedGraph: 0,
                wouldExecuteEK: plan.ekOps.count,
                wouldExecuteGraph: plan.graphOps.count,
                heldDeletes: plan.heldDeletes.count,
                dryRun: true, log: log)
        }
        let ek = try ekSink.apply(plan.ekOps)
        let gr = try graphSink.apply(plan.graphOps)
        log.append(CalSyncLogEntry(
            at: now, kind: "live",
            detail: "executed \(ek) EK + \(gr) Graph op(s); " +
                "\(plan.heldDeletes.count) delete(s) held"))
        return CalSyncReceipt(
            executedEK: ek, executedGraph: gr,
            wouldExecuteEK: 0, wouldExecuteGraph: 0,
            heldDeletes: plan.heldDeletes.count,
            dryRun: false, log: log)
    }
}

// MARK: - Diagnostics hook (engine API only; no UI in this lane)

/// Snapshot for Diagnostics surfaces. Pure value; the view layer reads it.
public struct CalSyncDiagnostics: Sendable, Equatable {
    public let targetUPNSet: Bool
    public let dryRun: Bool
    public let liveWritesEnabled: Bool
    public let windowDays: Int
    public let deletionPropagationEnabled: Bool
    public let lastPlanWrites: Int
    public let lastPlanHeldDeletes: Int
    public let lastPlanConflicts: Int
    public let logTail: [String]

    public static func snapshot(
        config: CalSyncConfig, lastPlan: CalSyncPlan?
    ) -> CalSyncDiagnostics {
        CalSyncDiagnostics(
            targetUPNSet: !(config.targetUPN ?? "").isEmpty,
            dryRun: config.dryRun,
            liveWritesEnabled: config.liveWritesEnabled,
            windowDays: config.windowDays,
            deletionPropagationEnabled: config.deletionPropagationEnabled,
            lastPlanWrites: lastPlan?.pendingWriteCount ?? 0,
            lastPlanHeldDeletes: lastPlan?.heldDeletes.count ?? 0,
            lastPlanConflicts: lastPlan?.conflictsTeamsWon.count ?? 0,
            logTail: (lastPlan?.log.suffix(10) ?? []).map {
                "[\($0.kind)] \($0.detail)"
            })
    }
}
