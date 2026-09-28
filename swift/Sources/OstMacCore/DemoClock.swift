// DemoClock.swift — the one "now" the canned demo data is stamped from.
//
// Plain `--demo` follows the wall clock. `--demo --evidence` pins it
// (before any demo data is built) to a working-hours moment in the
// current week, so captures show daytime timestamps, a mid-morning
// calendar and a weekday "today" whenever they are taken.
import Foundation

public enum DemoClock {
    /// Set once at launch (evidence only), before demo data is built.
    public nonisolated(unsafe) private(set) static var pinned: Date?

    /// The demo "now": the pinned evidence moment, else the wall clock.
    public static var now: Date { pinned ?? Date() }

    /// Evidence: freeze demo time at `evidenceMoment(for:)`.
    @discardableResult
    public static func pinForEvidence(realNow: Date = Date(), calendar: Calendar = .current) -> Date {
        let d = evidenceMoment(for: realNow, calendar: calendar)
        pinned = d
        return d
    }

    /// 10:30 AM on `realNow`'s day when it is a weekday; on a weekend,
    /// 10:30 AM on the Friday before.
    public static func evidenceMoment(for realNow: Date, calendar: Calendar = .current) -> Date {
        let weekday = calendar.component(.weekday, from: realNow) // 1 = Sunday … 7 = Saturday
        let back = weekday == 1 ? 2 : weekday == 7 ? 1 : 0
        let day = calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: realNow)) ?? realNow
        return calendar.date(bySettingHour: 10, minute: 30, second: 0, of: day) ?? day
    }

    /// Tests: back to the wall clock.
    public static func unpin() { pinned = nil }
}
