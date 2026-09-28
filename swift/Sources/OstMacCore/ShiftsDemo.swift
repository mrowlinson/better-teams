// ShiftsDemo.swift — canned Shifts week for `--demo` (offline,
// in-memory). Own file (merge hygiene: no DemoData.swift edit). User
// ids match `DemoTeams.roster`, so the people rows resolve to names.
import Foundation

public enum ShiftsDemo {
    /// Monday 00:00 of the current week (nonisolated twin of
    /// `ShiftsStore.currentWeekStart`: runs in the off-main fetcher).
    static func monday(calendar: Calendar = .current) -> Date {
        ShiftsStore.currentWeekStart(calendar: calendar)
    }

    /// Graph-style local wall-clock stamp `dayOffset` days after Monday.
    static func stamp(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0,
                      calendar: Calendar = .current) -> String {
        let base = calendar.date(byAdding: .day, value: dayOffset, to: monday(calendar: calendar)) ?? Date()
        let parts = calendar.dateComponents([.year, .month, .day], from: base)
        let date = calendar.date(from: DateComponents(
            year: parts.year, month: parts.month, day: parts.day, hour: hour, minute: minute)) ?? base
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return fmt.string(from: date)
    }

    public static func response(teamID: String) -> ShiftWeekResponse {
        func shift(_ id: String, _ user: String, _ label: String, day: Int, from: Int, to: Int,
                   theme: String?, notes: String? = nil, draft: Bool = false) -> ShiftItem {
            ShiftItem(id: "demo-shift-\(id)", userId: user, displayName: label,
                      start: stamp(day, from), end: stamp(day, to), theme: theme, notes: notes, isDraft: draft)
        }
        return ShiftWeekResponse(
            ok: true, team_id: teamID,
            schedule: ShiftSchedule(enabled: true, timeZone: TimeZone.current.identifier),
            shifts: [
                shift("megan-mon", "demo-u-megan", "Front Desk", day: 0, from: 9, to: 17, theme: "blue",
                      notes: "Open the office and check the mail room."),
                shift("megan-tue", "demo-u-megan", "Front Desk", day: 1, from: 9, to: 17, theme: "blue"),
                shift("megan-wed", "demo-u-megan", "Front Desk", day: 2, from: 9, to: 17, theme: "blue"),
                shift("tom-mon", "demo-u-tom", "Support", day: 0, from: 12, to: 20, theme: "green"),
                shift("tom-thu", "demo-u-tom", "Support", day: 3, from: 12, to: 20, theme: "green"),
                shift("tom-fri", "demo-u-tom", "On Call", day: 4, from: 17, to: 23, theme: "purple",
                      notes: "Pager rotation handover at 17:00."),
                shift("ava-tue", "demo-u-ava", "Warehouse", day: 1, from: 7, to: 15, theme: "yellow"),
                shift("ava-sat", "demo-u-ava", "Warehouse", day: 5, from: 8, to: 12, theme: "yellow",
                      draft: true),
                shift("paula-wed", "demo-u-paula", "Support", day: 2, from: 12, to: 20, theme: "green"),
            ],
            timesOff: [
                TimeOffItem(id: "demo-off-ava", userId: "demo-u-ava", reasonId: "demo-reason-vacation",
                            start: stamp(3, 0), end: stamp(5, 0)),
                TimeOffItem(id: "demo-off-paula", userId: "demo-u-paula", reasonId: "demo-reason-sick",
                            start: stamp(0, 0), end: stamp(1, 0)),
            ],
            reasons: [
                TimeOffReason(id: "demo-reason-vacation", name: "Vacation", code: "V"),
                TimeOffReason(id: "demo-reason-sick", name: "Sick"),
            ])
    }
}
