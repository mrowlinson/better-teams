// ShiftsWrite.swift — shifts-write lane: change requests + shift
// CRUD + publish over the core FFI (Graph schedule write ops).
//
// Reads stay in ShiftsStore/ShiftsModels. Every op needs the
// delegated `Schedule.ReadWrite.All` scope; without it the core
// answers `{ok:false,error:"scope"}` and the host surfaces the
// scope-pending state (`isScopeError`) instead of raw JSON. Arg
// mistakes are `{ok:false,error:"arg"}` pre-network.
import COstMac
import Foundation

/// One schedule change request (swap/offer/time-off). `kind` is
/// host-stamped (the wire rows carry no set name).
public struct ShiftChangeRequest: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: String
    public let state: String?
    public let senderShiftID: String?
    public let receiverUserID: String?
    public let reasonID: String?
    public let start: String?
    public let end: String?
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case id, state, message, kind
        case senderShiftID = "sender_shift_id"
        case receiverUserID = "receiver_user_id"
        case reasonID = "reason_id"
        case start, end
    }

    public init(
        id: String, kind: String, state: String? = nil,
        senderShiftID: String? = nil, receiverUserID: String? = nil,
        reasonID: String? = nil, start: String? = nil, end: String? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.senderShiftID = senderShiftID
        self.receiverUserID = receiverUserID
        self.reasonID = reasonID
        self.start = start
        self.end = end
        self.message = message
    }

    /// Pending sorts first; the rest keep server order (stable).
    public var isPending: Bool { state?.caseInsensitiveCompare("pending") == .orderedSame }
}

/// `{ok,team_id,kind,requests}` from `ostmac_schedule_requests`.
public struct ShiftRequestsResponse: Decodable, Sendable {
    public let ok: Bool
    public let teamID: String
    public let kind: String
    public let requests: [ShiftRequestRow]

    enum CodingKeys: String, CodingKey {
        case ok
        case teamID = "team_id"
        case kind, requests
    }
}

/// One wire request row (kind stamped by the caller).
public struct ShiftRequestRow: Decodable, Sendable {
    public let id: String
    public let state: String?
    public let senderShiftID: String?
    public let receiverUserID: String?
    public let reasonID: String?
    public let start: String?
    public let end: String?
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case id, state, message
        case senderShiftID = "sender_shift_id"
        case receiverUserID = "receiver_user_id"
        case reasonID = "reason_id"
        case start, end
    }
}

/// `{ok,id}` from the create calls.
public struct ShiftWriteIDResponse: Decodable, Sendable {
    public let ok: Bool
    public let id: String
}

/// True when a core-call failure is the missing-scope refusal (the
/// detail names `Schedule.ReadWrite.All`). Host shows scope-pending.
public func isShiftScopeError(_ error: Error) -> Bool {
    if case CoreCallError.failed(let m) = error {
        return m.contains("Schedule.ReadWrite.All")
    }
    return false
}

/// Write-path seam (same shape as the week fetchers): live closures
/// hit the core FFI above; demo/tests inject in-memory writers.
public struct ShiftsWriter: Sendable {
    public var fetchRequests: @Sendable (String, String) throws -> [ShiftChangeRequest]
    public var swapCreate: @Sendable (String, String, String?, String?) throws -> String
    public var offerCreate: @Sendable (String, String, String?, String?) throws -> String
    public var timeOffRequestCreate: @Sendable (String, String, String, String, String?) throws -> String
    public var decide: @Sendable (String, String, String, Bool, String?) throws -> Void
    public var shiftCreate: @Sendable (String, String?, String, String, String?, String?, String?) throws -> String
    public var shiftUpdate: @Sendable (String, String, String?, String?, String?, String?, String?) throws -> Void
    public var shiftDelete: @Sendable (String, String) throws -> Void
    public var timeOffCreate: @Sendable (String, String, String, String, String) throws -> String
    public var share: @Sendable (String, Bool, String?, String?) throws -> Void

    public init(
        fetchRequests: @escaping @Sendable (String, String) throws -> [ShiftChangeRequest],
        swapCreate: @escaping @Sendable (String, String, String?, String?) throws -> String,
        offerCreate: @escaping @Sendable (String, String, String?, String?) throws -> String,
        timeOffRequestCreate: @escaping @Sendable (String, String, String, String, String?) throws -> String,
        decide: @escaping @Sendable (String, String, String, Bool, String?) throws -> Void,
        shiftCreate: @escaping @Sendable (String, String?, String, String, String?, String?, String?) throws -> String,
        shiftUpdate: @escaping @Sendable (String, String, String?, String?, String?, String?, String?) throws -> Void,
        shiftDelete: @escaping @Sendable (String, String) throws -> Void,
        timeOffCreate: @escaping @Sendable (String, String, String, String, String) throws -> String,
        share: @escaping @Sendable (String, Bool, String?, String?) throws -> Void
    ) {
        self.fetchRequests = fetchRequests
        self.swapCreate = swapCreate
        self.offerCreate = offerCreate
        self.timeOffRequestCreate = timeOffRequestCreate
        self.decide = decide
        self.shiftCreate = shiftCreate
        self.shiftUpdate = shiftUpdate
        self.shiftDelete = shiftDelete
        self.timeOffCreate = timeOffCreate
        self.share = share
    }

    /// Scope-pending line (never raw JSON): the tenant token lacks
    /// `Schedule.ReadWrite.All` (live 2026-11-19: trial shows the
    /// sibling 403 for every write scope).
    public static let scopePendingMessage =
        "Shifts changes need your admin's approval (Schedule.ReadWrite.All)."

    /// Offline in-memory writer over one demo session: requests flip
    /// state, created shifts/time off land as drafts, share stamps
    /// them shared. Mirrors the live shapes for captures + tests.
    public static func demo(_ session: ShiftsDemoSession) -> ShiftsWriter {
        ShiftsWriter(
            fetchRequests: { _, kind in
                session.withLock { session.requests.filter { $0.kind == kind } }
            },
            swapCreate: { _, sender, receiver, message in
                let id = session.nextRequestID()
                session.withLock {
                    session.requests.append(ShiftChangeRequest(
                        id: id, kind: "swap", state: "pending",
                        senderShiftID: sender, receiverUserID: receiver, message: message))
                }
                return id
            },
            offerCreate: { _, sender, receiver, message in
                let id = session.nextRequestID()
                session.withLock {
                    session.requests.append(ShiftChangeRequest(
                        id: id, kind: "offer", state: "pending",
                        senderShiftID: sender, receiverUserID: receiver, message: message))
                }
                return id
            },
            timeOffRequestCreate: { _, reason, start, end, message in
                let id = session.nextRequestID()
                session.withLock {
                    session.requests.append(ShiftChangeRequest(
                        id: id, kind: "timeoff", state: "pending",
                        reasonID: reason, start: start, end: end, message: message))
                }
                return id
            },
            decide: { _, kind, requestID, approve, _ in
                session.withLock {
                    session.requests = session.requests.map { r in
                        guard r.id == requestID, r.kind == kind else { return r }
                        return ShiftChangeRequest(
                            id: r.id, kind: r.kind, state: approve ? "approved" : "declined",
                            senderShiftID: r.senderShiftID, receiverUserID: r.receiverUserID,
                            reasonID: r.reasonID, start: r.start, end: r.end, message: r.message)
                    }
                }
            },
            shiftCreate: { _, user, start, end, name, theme, notes in
                let id = session.nextShiftID()
                session.withLock {
                    session.extraShifts.append(ShiftItem(
                        id: id, userId: (user?.isEmpty == false) ? user : nil,
                        displayName: name ?? "", start: start, end: end,
                        theme: theme, notes: notes, isDraft: true))
                }
                return id
            },
            shiftUpdate: { _, shiftID, start, end, name, theme, notes in
                session.withLock {
                    let base = session.extraShifts.first { $0.id == shiftID }
                    let cur = base ?? ShiftItem(id: shiftID, displayName: name ?? "")
                    session.shiftOverlay[shiftID] = ShiftItem(
                        id: shiftID, userId: cur.userId,
                        displayName: (name?.isEmpty == false) ? name! : cur.displayName,
                        start: (start?.isEmpty == false) ? start : cur.start,
                        end: (end?.isEmpty == false) ? end : cur.end,
                        theme: (theme?.isEmpty == false) ? theme : cur.theme,
                        notes: (notes?.isEmpty == false) ? notes : cur.notes,
                        isDraft: true)
                }
            },
            shiftDelete: { _, shiftID in
                session.withLock {
                    session.extraShifts.removeAll { $0.id == shiftID }
                    session.shiftOverlay[shiftID] = nil
                }
            },
            timeOffCreate: { _, user, reason, start, end in
                let id = session.nextShiftID()
                session.withLock {
                    session.extraTimeOff.append(TimeOffItem(
                        id: id, userId: (user.isEmpty ? nil : user),
                        reasonId: reason, start: start, end: end, isDraft: true))
                }
                return id
            },
            share: { _, _, _, _ in
                session.withLock { session.shared = true }
            }
        )
    }

    /// Live core FFI (blocking: call off the main thread).
    public static func live() -> ShiftsWriter {
        ShiftsWriter(
            fetchRequests: { try RustCore.shiftRequests(teamID: $0, kind: $1) },
            swapCreate: { try RustCore.swapCreate(teamID: $0, senderShiftID: $1, receiverUserID: $2, message: $3) },
            offerCreate: { try RustCore.offerCreate(teamID: $0, senderShiftID: $1, receiverUserID: $2, message: $3) },
            timeOffRequestCreate: { try RustCore.timeOffRequestCreate(teamID: $0, reasonID: $1, start: $2, end: $3, message: $4) },
            decide: { try RustCore.shiftRequestDecide(teamID: $0, kind: $1, requestID: $2, approve: $3, message: $4) },
            shiftCreate: { try RustCore.shiftCreate(teamID: $0, userID: $1, start: $2, end: $3, displayName: $4, theme: $5, notes: $6) },
            shiftUpdate: { try RustCore.shiftUpdate(teamID: $0, shiftID: $1, start: $2, end: $3, displayName: $4, theme: $5, notes: $6) },
            shiftDelete: { try RustCore.shiftDelete(teamID: $0, shiftID: $1) },
            timeOffCreate: { try RustCore.timeOffCreate(teamID: $0, userID: $1, reasonID: $2, start: $3, end: $4) },
            share: { try RustCore.scheduleShare(teamID: $0, notifyTeam: $1, start: $2, end: $3) }
        )
    }
}

extension RustCore {
    /// One team's change requests of one kind (`swap`/`offer`/`timeoff`).
    public static func shiftRequests(teamID: String, kind: String) throws -> [ShiftChangeRequest] {
        let resp: ShiftRequestsResponse = try teamID.withCString { t in
            try kind.withCString { k in
                try call(ostmac_schedule_requests(t, k), as: ShiftRequestsResponse.self)
            }
        }
        return resp.requests.map {
            ShiftChangeRequest(
                id: $0.id, kind: kind, state: $0.state,
                senderShiftID: $0.senderShiftID, receiverUserID: $0.receiverUserID,
                reasonID: $0.reasonID, start: $0.start, end: $0.end, message: $0.message)
        }
    }

    /// Create a swap request for one shift. Returns the request id.
    public static func swapCreate(teamID: String, senderShiftID: String,
                                  receiverUserID: String? = nil,
                                  message: String? = nil) throws -> String {
        try teamID.withCString { t in
            try senderShiftID.withCString { s in
                let resp: ShiftWriteIDResponse = try shiftOptionalCString(receiverUserID) { r in
                    try shiftOptionalCString(message) { m in
                        try call(ostmac_schedule_swap_create(t, s, r, m),
                                 as: ShiftWriteIDResponse.self)
                    }
                }
                return resp.id
            }
        }
    }

    /// Create an offer request (give one shift to one member).
    public static func offerCreate(teamID: String, senderShiftID: String,
                                   receiverUserID: String? = nil,
                                   message: String? = nil) throws -> String {
        try teamID.withCString { t in
            try senderShiftID.withCString { s in
                let resp: ShiftWriteIDResponse = try shiftOptionalCString(receiverUserID) { r in
                    try shiftOptionalCString(message) { m in
                        try call(ostmac_schedule_offer_create(t, s, r, m),
                                 as: ShiftWriteIDResponse.self)
                    }
                }
                return resp.id
            }
        }
    }

    /// Create a time-off request for one reason and range.
    public static func timeOffRequestCreate(teamID: String, reasonID: String,
                                            start: String, end: String,
                                            message: String? = nil) throws -> String {
        try teamID.withCString { t in
            try reasonID.withCString { r in
                try start.withCString { s in
                    try end.withCString { e in
                        let resp: ShiftWriteIDResponse = try shiftOptionalCString(message) { m in
                            try call(ostmac_schedule_timeoff_request_create(t, r, s, e, m),
                                     as: ShiftWriteIDResponse.self)
                        }
                        return resp.id
                    }
                }
            }
        }
    }

    /// Approve or decline one change request (manager).
    public static func shiftRequestDecide(teamID: String, kind: String, requestID: String,
                                          approve: Bool,
                                          message: String? = nil) throws {
        struct OkResponse: Decodable { let ok: Bool }
        try teamID.withCString { t in
            try kind.withCString { k in
                try requestID.withCString { r in
                    try shiftOptionalCString(message) { m in
                        let _: OkResponse = try call(
                            ostmac_schedule_request_decide(t, k, r, approve ? 1 : 0, m),
                            as: OkResponse.self)
                    }
                }
            }
        }
    }

    /// Create one draft shift (manager). Nil/blank user = open shift.
    @discardableResult
    public static func shiftCreate(teamID: String, userID: String? = nil,
                                   start: String, end: String,
                                   displayName: String? = nil, theme: String? = nil,
                                   notes: String? = nil) throws -> String {
        try teamID.withCString { t in
            try start.withCString { s in
                try end.withCString { e in
                    let resp: ShiftWriteIDResponse = try shiftOptionalCString(userID) { u in
                        try shiftOptionalCString(displayName) { n in
                            try shiftOptionalCString(theme) { th in
                                try shiftOptionalCString(notes) { no in
                                    try call(ostmac_schedule_shift_create(t, u, s, e, n, th, no),
                                             as: ShiftWriteIDResponse.self)
                                }
                            }
                        }
                    }
                    return resp.id
                }
            }
        }
    }

    /// Patch one shift's draft slot (manager). Nil/blank = unchanged.
    public static func shiftUpdate(teamID: String, shiftID: String,
                                   start: String? = nil, end: String? = nil,
                                   displayName: String? = nil, theme: String? = nil,
                                   notes: String? = nil) throws {
        struct OkResponse: Decodable { let ok: Bool }
        try teamID.withCString { t in
            try shiftID.withCString { id in
                try shiftOptionalCString(start) { s in
                    try shiftOptionalCString(end) { e in
                        try shiftOptionalCString(displayName) { n in
                            try shiftOptionalCString(theme) { th in
                                try shiftOptionalCString(notes) { no in
                                    let _: OkResponse = try call(
                                        ostmac_schedule_shift_update(t, id, s, e, n, th, no),
                                        as: OkResponse.self)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Delete one shift (manager).
    public static func shiftDelete(teamID: String, shiftID: String) throws {
        struct OkResponse: Decodable { let ok: Bool }
        try teamID.withCString { t in
            try shiftID.withCString { id in
                let _: OkResponse = try call(ostmac_schedule_shift_delete(t, id),
                                             as: OkResponse.self)
            }
        }
    }

    /// Create one draft time-off instance directly (manager).
    @discardableResult
    public static func timeOffCreate(teamID: String, userID: String,
                                     reasonID: String,
                                     start: String, end: String) throws -> String {
        try teamID.withCString { t in
            try userID.withCString { u in
                try reasonID.withCString { r in
                    try start.withCString { s in
                        try end.withCString { e in
                            let resp: ShiftWriteIDResponse = try call(
                                ostmac_schedule_timeoff_create(t, u, r, s, e),
                                as: ShiftWriteIDResponse.self)
                            return resp.id
                        }
                    }
                }
            }
        }
    }

    /// Publish drafts (manager). Nil bounds share the whole schedule.
    public static func scheduleShare(teamID: String, notifyTeam: Bool,
                                      start: String? = nil,
                                      end: String? = nil) throws {
        struct OkResponse: Decodable { let ok: Bool }
        try teamID.withCString { t in
            try shiftOptionalCString(start) { s in
                try shiftOptionalCString(end) { e in
                    let _: OkResponse = try call(
                        ostmac_schedule_share(t, notifyTeam ? 1 : 0, s, e),
                        as: OkResponse.self)
                }
            }
        }
    }

    /// Optional C string: nil passes null; blank passes through (the
    /// core treats blank as absent too).
    static func shiftOptionalCString<T>(_ value: String?,
                                       _ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
        guard let value else { return try body(nil) }
        return try value.withCString { try body($0) }
    }
}

// MARK: - ShiftsStore write side (manager-gated)

/// Manager gate + requests + write ops. Host-side gate only (the
/// server re-checks): manager ops throw `managerOnly` below for
/// non-managers; member ops (swap/offer/time-off requests) are open
/// to every roster member. Scope failures surface
/// `ShiftsWriter.scopePendingMessage`, never raw JSON.
@MainActor
extension ShiftsStore {
    /// Host-side manager gate: the signed-in user owns this team.
    /// Closed (false) until both the roster and the own id land.
    public var isManager: Bool {
        guard let own = ownUserID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !own.isEmpty
        else { return false }
        return managerUserIDs.contains(own)
    }

    /// Adopt the signed-in user's id (host: whoami at open).
    public func adoptOwn(_ userID: String?) {
        let id = userID?.trimmingCharacters(in: .whitespacesAndNewlines)
        adoptWriteOwn((id?.isEmpty == false) ? id : nil)
    }

    /// Pending requests first (stable within each state).
    public var pendingRequests: [ShiftChangeRequest] { requests.filter(\.isPending) }

    /// True when the week on screen holds unpublished drafts (the
    /// Publish affordance shows for managers only).
    public var hasDrafts: Bool {
        guard let w = week else { return false }
        return w.columns.joined().contains { $0.isDraft } || w.timeOff.contains { $0.isDraft }
    }

    /// True when the requests area earns its space: a queue, a status
    /// line, or a manager drafts banner.
    public var showsRequestsArea: Bool {
        !requests.isEmpty || requestsError != nil || notice != nil || (isManager && hasDrafts)
    }

    /// Reload the selected team's requests (called on open/refresh
    /// and after every successful write). Never blanks the grid.
    public func loadRequests() {
        guard let team = selectedTeamID else { return }
        loadRequests(teamID: team)
    }

    func loadRequests(teamID: String) {
        setRequestsLoading(true)
        let writer = writer
        Task {
            var out: [ShiftChangeRequest] = []
            var scopePending = false
            var failed = false
            for kind in ["swap", "offer", "timeoff"] {
                do {
                    out += try await Task.blocking(operation: { try writer.fetchRequests(teamID, kind) }).value
                } catch {
                    if isShiftScopeError(error) { scopePending = true } else { failed = true }
                }
            }
            guard teamID == self.selectedTeamID else { return }
            if scopePending {
                setRequests([], error: ShiftsWriter.scopePendingMessage)
            } else if failed, out.isEmpty, !self.requests.isEmpty {
                // Transient failure behind a landed list: keep the
                // list, note the staleness inline (never raw JSON).
                setRequestsLoading(false)
                requestsErrorNote("Couldn't refresh change requests.")
            } else if failed {
                setRequests([], error: "Couldn't load change requests.")
            } else {
                setRequests(
                    out.sorted {
                        ($0.isPending ? 0 : 1, $0.kind, $0.id) < ($1.isPending ? 0 : 1, $1.kind, $1.id)
                    },
                    error: nil)
            }
        }
    }

    /// Manager-only guard (host side; the server re-checks).
    private func requireManager() throws {
        if !isManager { throw CoreCallError.failed(ShiftsStore.managerOnlyMessage) }
    }

    private func teamOrThrow() throws -> String {
        guard let team = selectedTeamID, !team.isEmpty else {
            throw CoreCallError.failed("shifts: no team selected")
        }
        return team
    }

    /// Write, then reload requests + the week grid on screen.
    private func didWrite() {
        loadRequests()
        refresh()
    }

    /// Member: swap one shift (optionally to one member).
    @discardableResult
    public func createSwapRequest(shiftID: String, receiverUserID: String? = nil,
                                  message: String? = nil) async throws -> String {
        let team = try teamOrThrow()
        let writer = writer
        let id = try await Task.blocking(operation: {
            try writer.swapCreate(team, shiftID, receiverUserID, message)
        }).value
        didWrite()
        return id
    }

    /// Member: offer one shift to one member.
    @discardableResult
    public func createOfferRequest(shiftID: String, receiverUserID: String? = nil,
                                   message: String? = nil) async throws -> String {
        let team = try teamOrThrow()
        let writer = writer
        let id = try await Task.blocking(operation: {
            try writer.offerCreate(team, shiftID, receiverUserID, message)
        }).value
        didWrite()
        return id
    }

    /// Member: request time off for one reason and range.
    @discardableResult
    public func createTimeOffRequest(reasonID: String, start: String, end: String,
                                     message: String? = nil) async throws -> String {
        let team = try teamOrThrow()
        let writer = writer
        let id = try await Task.blocking(operation: {
            try writer.timeOffRequestCreate(team, reasonID, start, end, message)
        }).value
        didWrite()
        return id
    }

    /// Manager: approve or decline one change request.
    public func decideRequest(_ request: ShiftChangeRequest, approve: Bool,
                              message: String? = nil) async throws {
        try requireManager()
        let team = try teamOrThrow()
        let writer = writer
        try await Task.blocking(operation: {
            try writer.decide(team, request.kind, request.id, approve, message)
        }).value
        didWrite()
    }

    /// Manager: create one draft shift (nil user = open shift).
    @discardableResult
    public func createShift(userID: String? = nil, start: String, end: String,
                            displayName: String? = nil, theme: String? = nil,
                            notes: String? = nil) async throws -> String {
        try requireManager()
        let team = try teamOrThrow()
        let writer = writer
        let id = try await Task.blocking(operation: {
            try writer.shiftCreate(team, userID, start, end, displayName, theme, notes)
        }).value
        didWrite()
        return id
    }

    /// Manager: patch one shift's draft slot.
    public func updateShift(shiftID: String, start: String? = nil, end: String? = nil,
                            displayName: String? = nil, theme: String? = nil,
                            notes: String? = nil) async throws {
        try requireManager()
        let team = try teamOrThrow()
        let writer = writer
        try await Task.blocking(operation: {
            try writer.shiftUpdate(team, shiftID, start, end, displayName, theme, notes)
        }).value
        didWrite()
    }

    /// Manager: delete one shift.
    public func deleteShift(shiftID: String) async throws {
        try requireManager()
        let team = try teamOrThrow()
        let writer = writer
        try await Task.blocking(operation: { try writer.shiftDelete(team, shiftID) }).value
        didWrite()
    }

    /// Manager: create one draft time-off instance directly.
    @discardableResult
    public func createTimeOff(userID: String, reasonID: String,
                              start: String, end: String) async throws -> String {
        try requireManager()
        let team = try teamOrThrow()
        let writer = writer
        let id = try await Task.blocking(operation: {
            try writer.timeOffCreate(team, userID, reasonID, start, end)
        }).value
        didWrite()
        return id
    }

    /// Manager: publish drafts (optionally notifying the team).
    public func publishDrafts(notifyTeam: Bool) async throws {
        try requireManager()
        let team = try teamOrThrow()
        let writer = writer
        try await Task.blocking(operation: { try writer.share(team, notifyTeam, nil, nil) }).value
        didWrite()
    }
}
