// StatusMessage.swift — PRESENCE-PLUS: own status-message set/clear.
//
// Read path already exists (`ContactCard.statusMessage`, parsed from the
// unified presence service with expiry honored). This file adds the write:
// Graph POST /me/presence/setStatusMessage (message + optional expiry).
// It needs Presence.ReadWrite, which the Teams token does not carry, so a
// live call 403s and the UI pins the capability reason (never retried).
//
// Clear shape (message null) follows the Graph doc for removing a status
// message; it has never been proven live (same missing scope).
import Foundation

// MARK: - Duration (Teams "Clear after" choices)

// How long a status message stays up (Teams client choices).
public enum StatusMessageDuration: String, CaseIterable, Sendable {
    case oneHour, fourHours, eightHours, today, thisWeek, never

    /// Picker label.
    public var label: String {
        switch self {
        case .oneHour: "1 hour"
        case .fourHours: "4 hours"
        case .eightHours: "8 hours"
        case .today: "Today"
        case .thisWeek: "This week"
        case .never: "Never"
        }
    }

    /// Expiry instant for `now` (nil = no expiry, message stays until cleared).
    public func expiry(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .oneHour: calendar.date(byAdding: .hour, value: 1, to: now)
        case .fourHours: calendar.date(byAdding: .hour, value: 4, to: now)
        case .eightHours: calendar.date(byAdding: .hour, value: 8, to: now)
        case .today: calendar.dateInterval(of: .day, for: now)?.end
        case .thisWeek: calendar.dateInterval(of: .weekOfYear, for: now)?.end
        case .never: nil
        }
    }
}

// MARK: - Draft (message + duration → request body)

// One status-message edit (Teams "Set your status message" sheet).
public struct StatusMessageDraft: Equatable, Sendable {
    /// Teams status messages cap at 280 characters.
    public static let maxLength = 280
    public var message: String
    public var duration: StatusMessageDuration

    public init(message: String, duration: StatusMessageDuration = .oneHour) {
        self.message = message
        self.duration = duration
    }

    public var trimmed: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Settable only with real text inside the length cap (guard-pinned).
    public var isSettable: Bool {
        !trimmed.isEmpty && trimmed.count <= Self.maxLength
    }

    /// POST body (nil when not settable — the client refuses before any
    /// network). No-expiry durations omit expiryDateTime.
    public func body(now: Date = Date(), calendar: Calendar = .current) -> [String: Any]? {
        guard isSettable else { return nil }
        var note: [String: Any] = ["message": ["content": trimmed, "contentType": "text"]]
        if let exp = duration.expiry(now: now, calendar: calendar) {
            note["expiryDateTime"] = Self.zone(exp)
        }
        return ["statusMessage": note]
    }

    /// Clear body: message null (Graph removal shape, live-unproven).
    public static func clearBody() -> [String: Any] {
        ["statusMessage": ["message": NSNull()]]
    }

    private static func zone(_ date: Date) -> [String: String] {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime]
        return ["dateTime": f.string(from: date), "timeZone": "UTC"]
    }
}

// MARK: - Graph client (CalendarHTTP seam; tests inject stubs)

// Set/clear own status message (explicit user action only).
public struct StatusMessageGraph: Sendable {
    static let path = "/me/presence/setStatusMessage"

    /// Transport rides the allowlisted Graph helper (the lint pins every
    /// Graph call site in docs/graph-allowlist.txt): the host is spelled
    /// once in CalendarGraph, never here.
    var graph: CalendarGraph

    init(http: any CalendarHTTP, token: @escaping @Sendable () throws -> String) {
        graph = CalendarGraph(http: http, token: token)
    }

    /// Signed-in profile, URLSession transport.
    public static func production() -> StatusMessageGraph {
        StatusMessageGraph(http: URLSessionCalendarHTTP()) {
            try CoreReads.graphToken(
                profile: CoreLocal.activeProfileID(), code: "statusmsg", ctx: CoreReads.production())
        }
    }

    /// Set (explicit Set action only — the brief authorizes one live
    /// attempt; a 403 records the capability message, never retried).
    public func set(_ draft: StatusMessageDraft) throws {
        guard let json = draft.body() else {
            throw CoreCallError.failed("statusmsg: message is blank or over 280 characters.")
        }
        try mapped { try graph.request("POST", Self.path, json: json) }
    }

    /// Clear (explicit Clear action only; removal shape is live-unproven).
    public func clear() throws {
        try mapped { try graph.request("POST", Self.path, json: StatusMessageDraft.clearBody()) }
    }

    /// A 403 from either direction is the missing-scope capability
    /// message (the token probe showed Presence.ReadWrite absent).
    @discardableResult
    private func mapped(_ work: () throws -> Data) throws -> Data {
        do {
            return try work()
        } catch let e as CoreCallError {
            if case .failed(let msg) = e, msg.contains(" 403") {
                throw CoreCallError.failed("statusmsg: not allowed — Presence.ReadWrite is not granted on this sign-in.")
            }
            throw e
        }
    }
}

// MARK: - Store (Settings section source)

// Own status-message saver (MainActor; blocking calls run off-main via
// the sync HTTP seam, same contract as `CoreReads`).
@MainActor
public final class StatusMessageStore: ObservableObject {
    @Published public private(set) var saving = false
    @Published public private(set) var error: String?
    /// Sticky scope refusal (the UI disables live Set/Clear while set;
    /// editing the message clears it so a granted scope can be retried).
    @Published public private(set) var liveDisabledReason: String?
    /// Last message this store set (local echo; the server echo arrives
    /// via the unified presence refresh the view triggers after a save).
    @Published public private(set) var savedMessage: String?

    private let client: StatusMessageGraph

    /// Nonisolated so views take a default in their (nonisolated) inits
    /// (PresenceStore precedent); all members stay main-actor-isolated.
    public nonisolated init(client: StatusMessageGraph? = nil) {
        self.client = client ?? .production()
    }

    /// Test/demo seam: last message without network.
    public func adopt(_ message: String?) {
        savedMessage = message
        error = nil
    }

    /// Editing restarts the live path (clears a stale scope refusal).
    public func noteEdited() {
        liveDisabledReason = nil
    }

    /// Set (explicit Set action only; 403 pins the live-disabled reason
    /// and keeps the previous message).
    public func save(_ draft: StatusMessageDraft) {
        guard !saving else { return }
        saving = true
        let client = self.client
        Task {
            do {
                try await Task.blocking { try client.set(draft) }.value
                self.savedMessage = draft.trimmed
                self.error = nil
            } catch {
                self.record(error)
            }
            self.saving = false
        }
    }

    /// Clear (explicit Clear action only; same 403 rule).
    public func clear() {
        guard !saving else { return }
        saving = true
        let client = self.client
        Task {
            do {
                try await Task.blocking { try client.clear() }.value
                self.savedMessage = nil
                self.error = nil
            } catch {
                self.record(error)
            }
            self.saving = false
        }
    }

    private func record(_ e: Error) {
        let msg = String(describing: e)
        if msg.contains("not granted") {
            liveDisabledReason = msg
            error = nil
        } else {
            error = msg
        }
    }
}
