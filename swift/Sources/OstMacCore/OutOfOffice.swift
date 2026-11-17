// OutOfOffice.swift — OOO-SET (gap C5): schedule out-of-office behind
// the R0 read-only probe. Probe result: the Teams token carries
// MailboxSettings.ReadWrite and GET /me/mailboxSettings returns 200 with
// `automaticRepliesSetting` = {externalAudience, externalReplyMessage,
// internalReplyMessage, scheduledEndDateTime, scheduledStartDateTime,
// status} (notes/probe.log; GETs only, live set+revert never run — the
// SET path below ships without live proof pending owner approval).
//
// Write shape: PATCH /me/mailboxSettings {"automaticRepliesSetting": …}
// (Graph; needs MailboxSettings.ReadWrite — 403 otherwise, surfaced as a
// capability message, never retried). The body carries ONLY
// automaticRepliesSetting: a save never touches timeZone, language,
// workingHours or anything else on the mailbox (guard-pinned).
//
// Display reuse: the current OOO overlay already arrives read-only via
// the unified presence service (`ContactPresence.outOfOffice` /
// `outOfOfficeNote`, shown in the Shell account menu + Settings).
// Duration reuse: `PresenceLockDuration` (untilOff = always on, anything
// else = scheduled start → start+duration).
import Foundation

// MARK: - Setting (Graph `automaticRepliesSetting` shape)

/// Out-of-office state (Graph `automaticRepliesSetting.status`).
public enum OutOfOfficeStatus: String, Equatable, Sendable {
    case disabled, alwaysEnabled, scheduled
}

/// One OOO setting: message + schedule. External replies mirror the
/// internal message with audience contactsOnly (conservative: no
/// auto-replies to strangers; the editor offers one message field).
public struct OutOfOfficeSetting: Equatable, Sendable {
    public var enabled: Bool
    /// Nil start/end = always on (`alwaysEnabled`).
    public var start: Date?
    public var end: Date?
    public var message: String

    public init(enabled: Bool, start: Date? = nil, end: Date? = nil, message: String = "") {
        self.enabled = enabled
        self.start = start
        self.end = end
        self.message = message
    }

    public static let off = OutOfOfficeSetting(enabled: false)

    /// Duration label reusing the lock summary shape
    /// ("Out of Office · 2h 05m left" / "… · until off").
    public func summary(now: Date = Date()) -> String {
        guard enabled else { return "Off" }
        guard let end else { return "Out of Office · until off" }
        let mins = Int(ceil(end.timeIntervalSince(now) / 60))
        if mins <= 0 { return "Out of Office · expired" }
        if mins < 90 { return "Out of Office · \(mins)m left" }
        return "Out of Office · \(mins / 60)h \(String(format: "%02d", mins % 60))m left"
    }

    // MARK: parse (GET /me/mailboxSettings)

    /// Parse the GET reply. Unknown shapes → nil (never a phantom Off
    /// or On); `disabled` or a missing block parses as off.
    public static func parse(_ data: Data) -> OutOfOfficeSetting? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let oof = obj["automaticRepliesSetting"] as? [String: Any] else { return .off }
        let status = (oof["status"] as? String) ?? "disabled"
        guard status != "disabled" else { return .off }
        let message = (oof["internalReplyMessage"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if status == "scheduled" {
            let start = Self.date(oof["scheduledStartDateTime"])
            let end = Self.date(oof["scheduledEndDateTime"])
            return OutOfOfficeSetting(enabled: true, start: start, end: end, message: message)
        }
        guard status == "alwaysEnabled" else { return nil }
        return OutOfOfficeSetting(enabled: true, message: message)
    }

    private static func date(_ raw: Any?) -> Date? {
        guard let dt = raw as? [String: Any],
              let s = dt["dateTime"] as? String, !s.isEmpty
        else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return f.date(from: s)
    }

    // MARK: body (PATCH /me/mailboxSettings)

    /// PATCH body: ONLY automaticRepliesSetting (guard-pinned — a save
    /// never overwrites any other mailbox setting).
    public func patchBody() -> [String: Any] {
        var oof: [String: Any] = [
            "externalAudience": "contactsOnly",
            "internalReplyMessage": message,
            "externalReplyMessage": message,
        ]
        if !enabled {
            oof["status"] = OutOfOfficeStatus.disabled.rawValue
        } else if let start, let end {
            oof["status"] = OutOfOfficeStatus.scheduled.rawValue
            oof["scheduledStartDateTime"] = Self.zone(start)
            oof["scheduledEndDateTime"] = Self.zone(end)
        } else {
            oof["status"] = OutOfOfficeStatus.alwaysEnabled.rawValue
        }
        return ["automaticRepliesSetting": oof]
    }

    private static func zone(_ date: Date) -> [String: String] {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime]
        return ["dateTime": f.string(from: date), "timeZone": "UTC"]
    }

    /// Editor → setting: untilOff pins nothing (always on), any other
    /// duration schedules start → start+duration.
    public static func scheduled(
        message: String, start: Date, duration: PresenceLockDuration
    ) -> OutOfOfficeSetting {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let end = duration.expiryDate(now: start) else {
            return OutOfOfficeSetting(enabled: true, message: trimmed)
        }
        return OutOfOfficeSetting(enabled: true, start: start, end: end, message: trimmed)
    }
}

// MARK: - Graph client (CalendarHTTP seam; tests inject stubs)

public struct OutOfOfficeGraph: Sendable {
    static let path = "/me/mailboxSettings"

    /// Transport rides the allowlisted Graph helper (the lint pins every
    /// Graph call site in docs/graph-allowlist.txt): the host is spelled
    /// once in CalendarGraph, never here.
    var graph: CalendarGraph

    init(http: any CalendarHTTP, token: @escaping @Sendable () throws -> String) {
        graph = CalendarGraph(http: http, token: token)
    }

    /// Signed-in profile, URLSession transport.
    public static func production() -> OutOfOfficeGraph {
        OutOfOfficeGraph(http: URLSessionCalendarHTTP()) {
            try CoreReads.graphToken(
                profile: CoreLocal.activeProfileID(), code: "ooo", ctx: CoreReads.production())
        }
    }

    /// Current setting (read-only GET; failures throw user-facing text).
    public func fetch() throws -> OutOfOfficeSetting {
        let data = try mapped { try graph.request("GET", Self.path) }
        guard let setting = OutOfOfficeSetting.parse(data) else {
            throw CoreCallError.failed("ooo: unreadable mailboxSettings reply")
        }
        return setting
    }

    /// Save (explicit user action only — the HARD BAN: no live call in
    /// this lane; production saves need owner approval per set+revert).
    public func save(_ setting: OutOfOfficeSetting) throws {
        try mapped { try graph.request("PATCH", Self.path, json: setting.patchBody()) }
    }

    /// A 403 from either direction is the missing-scope capability
    /// message (the token probe showed ReadWrite granted, so a 403 in
    /// the field means the grant went away).
    @discardableResult
    private func mapped(_ work: () throws -> Data) throws -> Data {
        do {
            return try work()
        } catch let e as CoreCallError {
            if case .failed(let msg) = e, msg.contains(" 403") {
                throw CoreCallError.failed("ooo: not allowed — MailboxSettings.ReadWrite is not granted.")
            }
            throw e
        }
    }
}

// MARK: - Store (Settings section source)

/// Own OOO setting (MainActor; blocking calls run off-main via the
/// sync HTTP seam, same contract as `CoreReads`).
@MainActor
public final class OutOfOfficeStore: ObservableObject {
    @Published public private(set) var setting = OutOfOfficeSetting.off
    @Published public private(set) var loading = false
    @Published public private(set) var error: String?

    private let client: OutOfOfficeGraph

    /// Nonisolated so views can take a default in their (nonisolated)
    /// inits (PresenceStore precedent); all members stay main-actor-isolated.
    public nonisolated init(client: OutOfOfficeGraph? = nil) {
        self.client = client ?? .production()
    }

    /// Test seam: adopt a setting without network.
    public func adopt(_ setting: OutOfOfficeSetting) {
        self.setting = setting
        error = nil
    }

    /// Refresh from the server (read-only GET).
    public func refresh() {
        guard !loading else { return }
        loading = true
        let client = self.client
        Task {
            do {
                let setting = try await Task.blocking { try client.fetch() }.value
                self.setting = setting
                self.error = nil
            } catch {
                self.error = String(describing: error)
            }
            self.loading = false
        }
    }

    /// Save (explicit Set/Turn-off action only; 403 records the
    /// capability message and leaves the previous setting).
    public func save(_ setting: OutOfOfficeSetting) {
        guard !loading else { return }
        loading = true
        let client = self.client
        Task {
            do {
                try await Task.blocking { try client.save(setting) }.value
                self.setting = setting
                self.error = nil
            } catch {
                self.error = String(describing: error)
            }
            self.loading = false
        }
    }
}
