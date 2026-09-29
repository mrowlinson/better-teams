// CalendarWeekModels.swift — B1 calendar lane: week/schedule/cancel wire
// models + pure day bucketing. Events reuse MeetingItem (same core shape
// as the join lane); this file only adds envelopes and grid helpers.
import Foundation

/// `{ok,week_start,days,meetings}` from `ostmac_cal_week`.
public struct CalWeekResponse: Codable, Sendable {
    public let ok: Bool
    public let weekStart: Int64
    public let days: Int
    public let meetings: [MeetingItem]

    enum CodingKeys: String, CodingKey {
        case ok, meetings, days
        case weekStart = "week_start"
    }

    public init(ok: Bool, weekStart: Int64, days: Int, meetings: [MeetingItem]) {
        self.ok = ok
        self.weekStart = weekStart
        self.days = days
        self.meetings = meetings
    }
}

/// `{ok,event}` from `ostmac_cal_schedule`.
public struct CalEventResult: Decodable, Sendable {
    public let ok: Bool
    public let event: MeetingItem

    public init(ok: Bool, event: MeetingItem) {
        self.ok = ok
        self.event = event
    }
}

/// `{ok,id}` from `ostmac_cal_cancel`.
public struct CalCancelResult: Decodable, Sendable {
    public let ok: Bool
    public let id: String

    public init(ok: Bool, id: String) {
        self.ok = ok
        self.id = id
    }
}

/// Pure week-grid helpers over `MeetingItem` rows.
public enum CalWeek {
    /// `"2026-09-28T09:00:00.0000000"` -> `"2026-09-28"`.
    /// Nil when the row is unscheduled.
    public static func dayKey(of meeting: MeetingItem) -> String? {
        guard let start = meeting.start, start.count >= 10 else { return nil }
        return String(start.prefix(10))
    }

    /// `"2026-09-28T09:00:00.0000000"` -> `"09:00"`. Nil when unscheduled.
    public static func dayTime(of meeting: MeetingItem) -> String? {
        guard let start = meeting.start, start.count >= 16 else { return nil }
        return String(start.dropFirst(11).prefix(5))
    }

    /// Midnight starting the week that contains `date` (per the calendar's
    /// `firstWeekday`; pass Monday-first for the grid).
    public static func startOfWeek(
        containing date: Date, calendar: Calendar = .current
    ) -> Date {
        let parts = calendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: parts) ?? calendar.startOfDay(for: date)
    }

    /// Seven `"yyyy-MM-dd"` keys starting at `weekStart` (midnight).
    public static func dayKeys(
        weekStart: Date, calendar: Calendar = .current
    ) -> [String] {
        let fmt = dayFormatter(calendar: calendar)
        let start = calendar.startOfDay(for: weekStart)
        return (0 ..< 7).map { offset in
            fmt.string(from: calendar.date(
                byAdding: .day, value: offset, to: start) ?? start)
        }
    }

    /// Bucket rows into the 7 columns aligned with `dayKeys` (each column
    /// sorted by start, unscheduled rows excluded).
    public static func bucket(
        _ meetings: [MeetingItem], weekStart: Date,
        calendar: Calendar = .current
    ) -> [[MeetingItem]] {
        bucket(meetings, keys: dayKeys(weekStart: weekStart, calendar: calendar))
    }

    /// Bucket rows into one column per `keys` day. An all-day event
    /// lands on every day it covers (`end` is the exclusive midnight);
    /// timed rows on their start day. Each column sorted by start.
    public static func bucket(_ meetings: [MeetingItem], keys: [String]) -> [[MeetingItem]] {
        keys.map { key in
            meetings.filter { occurs($0, on: key) }.sorted {
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                return ($0.start ?? "~") < ($1.start ?? "~")
            }
        }
    }

    /// `meeting` shows on day `key` (`"yyyy-MM-dd"`).
    public static func occurs(_ meeting: MeetingItem, on key: String) -> Bool {
        guard let start = dayKey(of: meeting) else { return false }
        guard meeting.isAllDay, let end = meeting.end, end.count >= 10 else { return start == key }
        let endKey = String(end.prefix(10))
        return key == start || (key > start && key < endKey)
    }

    /// `Date` -> Graph datetime `"yyyy-MM-dd'T'HH:mm:ss"` in `timeZone`.
    public static func graphDateTime(
        _ date: Date, timeZone: TimeZone = .current
    ) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return fmt.string(from: date)
    }

    private static func dayFormatter(calendar: Calendar) -> DateFormatter {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }
}
