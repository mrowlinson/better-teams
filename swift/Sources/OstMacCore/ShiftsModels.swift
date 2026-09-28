// ShiftsModels.swift — om-shifts lane: schedule week models (read-only).
//
// Decodes core `ostmac_schedule_week`: schedule header + shifts +
// time-off instances + reasons. Host buckets shifts into 7 day columns
// and counts approved time-off instances per reason (balances proxy —
// Graph exposes no balances endpoint). No writes exist in this lane.
import Foundation

/// One team's schedule header from core.
public struct ShiftSchedule: Decodable, Sendable, Equatable {
    public let enabled: Bool
    public let timeZone: String?
    public let provisionStatus: String?

    enum CodingKeys: String, CodingKey {
        case enabled
        case timeZone = "time_zone"
        case provisionStatus = "provision_status"
    }

    public init(enabled: Bool, timeZone: String? = nil, provisionStatus: String? = nil) {
        self.enabled = enabled
        self.timeZone = timeZone
        self.provisionStatus = provisionStatus
    }
}

/// One shift row. `start`/`end` are Graph ISO-8601 local datetimes.
public struct ShiftItem: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let userId: String?
    public let displayName: String
    public let start: String?
    public let end: String?
    public let theme: String?
    public let notes: String?
    public let isDraft: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case displayName = "display_name"
        case start, end, theme, notes
        case isDraft = "is_draft"
    }

    public init(
        id: String, userId: String? = nil, displayName: String = "",
        start: String? = nil, end: String? = nil,
        theme: String? = nil, notes: String? = nil, isDraft: Bool = false
    ) {
        self.id = id
        self.userId = userId
        self.displayName = displayName
        self.start = start
        self.end = end
        self.theme = theme
        self.notes = notes
        self.isDraft = isDraft
    }

    /// Parsed start date, or nil when missing/unparseable (row still shows).
    public var startDate: Date? { Self.parse(dateTime: start) }

    public static func parse(dateTime: String?) -> Date? {
        guard let s = dateTime, !s.isEmpty else { return nil }
        if let d = withOffset.date(from: s) { return d }
        return withoutOffset.date(from: s)
    }

    private static let withOffset: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let withoutOffset: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
}

/// One time-off instance.
public struct TimeOffItem: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let userId: String?
    public let reasonId: String?
    public let start: String?
    public let end: String?
    public let isDraft: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case reasonId = "reason_id"
        case start, end
        case isDraft = "is_draft"
    }

    public init(
        id: String, userId: String? = nil, reasonId: String? = nil,
        start: String? = nil, end: String? = nil, isDraft: Bool = false
    ) {
        self.id = id
        self.userId = userId
        self.reasonId = reasonId
        self.start = start
        self.end = end
        self.isDraft = isDraft
    }
}

/// One time-off reason code.
public struct TimeOffReason: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let code: String?

    public init(id: String, name: String, code: String? = nil) {
        self.id = id
        self.name = name
        self.code = code
    }
}

/// Whole week grid in one response (single FFI round-trip).
public struct ShiftWeekResponse: Decodable, Sendable {
    public let ok: Bool
    public let team_id: String?
    public let schedule: ShiftSchedule
    public let shifts: [ShiftItem]
    public let timesOff: [TimeOffItem]
    public let reasons: [TimeOffReason]

    enum CodingKeys: String, CodingKey {
        case ok, team_id, schedule, shifts, reasons
        case timesOff = "times_off"
    }

    /// Host-side construction (demo data, previews, mock fetchers).
    /// Wire decoding is untouched.
    public init(
        ok: Bool, team_id: String? = nil, schedule: ShiftSchedule,
        shifts: [ShiftItem], timesOff: [TimeOffItem], reasons: [TimeOffReason]
    ) {
        self.ok = ok
        self.team_id = team_id
        self.schedule = schedule
        self.shifts = shifts
        self.timesOff = timesOff
        self.reasons = reasons
    }
}

/// One team in the Shifts team picker.
public struct ShiftTeam: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Approved time-off instances grouped by reason (balances proxy).
public struct ShiftBalance: Sendable, Equatable {
    public let reason: TimeOffReason
    public let count: Int

    public init(reason: TimeOffReason, count: Int) {
        self.reason = reason
        self.count = count
    }
}

/// One rendered week: 7 day columns of shifts + the time-off strip.
public struct ShiftWeek: Sendable, Equatable {
    /// Monday (or locale start) 00:00 of the rendered week.
    public let weekStart: Date
    /// 7 columns, Monday-first per `calendar`.
    public let columns: [[ShiftItem]]
    public let timeOff: [TimeOffItem]
    public let balances: [ShiftBalance]

    public init(weekStart: Date, columns: [[ShiftItem]], timeOff: [TimeOffItem], balances: [ShiftBalance]) {
        self.weekStart = weekStart
        self.columns = columns
        self.timeOff = timeOff
        self.balances = balances
    }

    /// Build a week from a response. Shifts whose start falls outside
    /// the 7 days (or is unparseable) are dropped from the grid.
    public static func build(
        from response: ShiftWeekResponse,
        weekStart: Date,
        calendar: Calendar = .current
    ) -> ShiftWeek {
        let day0 = calendar.startOfDay(for: weekStart)
        var columns = Array(repeating: [ShiftItem](), count: 7)
        for shift in response.shifts {
            guard let date = shift.startDate else { continue }
            let day = calendar.dateComponents(
                [.day], from: day0, to: calendar.startOfDay(for: date)).day ?? -1
            guard day >= 0, day < 7 else { continue }
            columns[day].append(shift)
        }
        for i in 0 ..< 7 {
            columns[i].sort { ($0.start ?? "") < ($1.start ?? "") }
        }
        return ShiftWeek(
            weekStart: day0, columns: columns,
            timeOff: response.timesOff,
            balances: balances(reasons: response.reasons, timesOff: response.timesOff))
    }

    /// Count non-draft instances per reason; reasons with zero
    /// instances are omitted.
    public static func balances(
        reasons: [TimeOffReason], timesOff: [TimeOffItem]
    ) -> [ShiftBalance] {
        var counts: [String: Int] = [:]
        for item in timesOff where !item.isDraft {
            guard let rid = item.reasonId else { continue }
            counts[rid, default: 0] += 1
        }
        return reasons.compactMap { reason in
            guard let n = counts[reason.id], n > 0 else { return nil }
            return ShiftBalance(reason: reason, count: n)
        }
    }
}
