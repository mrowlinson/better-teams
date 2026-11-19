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
        /// The same shift on several days (Monday = 0 … Sunday = 6).
        func week(_ key: String, _ user: String, _ label: String, days: [Int], from: Int, to: Int,
                  theme: String) -> [ShiftItem] {
            let names = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
            return days.map { shift("\(key)-\(names[$0])", user, label, day: $0, from: from, to: to, theme: theme) }
        }
        let groups: [[ShiftItem]] = [
            [
                shift("megan-mon", "demo-u-megan", "Front Desk", day: 0, from: 9, to: 17, theme: "blue",
                      notes: "Open the office and check the mail room."),
            ],
            week("megan", "demo-u-megan", "Front Desk", days: [1, 2, 3, 4], from: 9, to: 17, theme: "blue"),
            week("tom", "demo-u-tom", "Support", days: [0, 1, 3], from: 12, to: 20, theme: "green"),
            [shift("tom-fri", "demo-u-tom", "On Call", day: 4, from: 17, to: 23, theme: "purple",
                   notes: "Pager rotation handover at 17:00.")],
            week("ava", "demo-u-ava", "Warehouse", days: [0, 1], from: 7, to: 15, theme: "yellow"),
            week("paula", "demo-u-paula", "Support", days: [1, 2, 3, 5], from: 12, to: 20, theme: "green"),
            week("luis", "demo-u-luis", "Warehouse", days: [2, 3, 4, 5, 6], from: 7, to: 15, theme: "yellow"),
            week("olivia", "demo-u-olivia", "Front Desk", days: [5, 6], from: 10, to: 18, theme: "blue"),
            [shift("olivia-mon", "demo-u-olivia", "Training", day: 0, from: 13, to: 17, theme: "pink")],
            week("ethan", "demo-u-ethan", "On Call", days: [0, 1, 2, 3], from: 17, to: 23, theme: "purple"),
            week("hannah", "demo-u-hannah", "Support", days: [4, 5, 6], from: 9, to: 17, theme: "green"),
            week("ryan", "demo-u-ryan", "Warehouse", days: [0, 1, 2, 3], from: 15, to: 23, theme: "yellow"),
            week("chloe", "demo-u-chloe", "Front Desk", days: [1, 2, 3, 4], from: 13, to: 21, theme: "blue"),
            [shift("nathan-mon", "demo-u-nathan", "Training", day: 0, from: 9, to: 12, theme: "pink")],
            week("nathan", "demo-u-nathan", "Support", days: [2, 3, 4], from: 8, to: 16, theme: "green"),
            [shift("nathan-sun", "demo-u-nathan", "Support", day: 6, from: 10, to: 14, theme: "green",
                   draft: true)],
        ]
        return ShiftWeekResponse(
            ok: true, team_id: teamID,
            schedule: ShiftSchedule(enabled: true, timeZone: TimeZone.current.identifier),
            shifts: groups.flatMap { $0 },
            timesOff: [
                TimeOffItem(id: "demo-off-ava", userId: "demo-u-ava", reasonId: "demo-reason-vacation",
                            start: stamp(3, 0), end: stamp(6, 0)),
                TimeOffItem(id: "demo-off-paula", userId: "demo-u-paula", reasonId: "demo-reason-sick",
                            start: stamp(0, 0), end: stamp(1, 0)),
                TimeOffItem(id: "demo-off-chloe", userId: "demo-u-chloe", reasonId: "demo-reason-personal",
                            start: stamp(0, 9), end: stamp(0, 13)),
            ],
            reasons: [
                TimeOffReason(id: "demo-reason-vacation", name: "Vacation", code: "V"),
                TimeOffReason(id: "demo-reason-sick", name: "Sick"),
                TimeOffReason(id: "demo-reason-personal", name: "Personal"),
        ])
    }
}

/// Mutable demo Shifts session (offline, in-memory): the demo store's
/// week fetcher and writer share one instance, so request/approve and
/// create/publish flows run end to end in `--demo` and captures.
/// Lock-guarded: writer closures run off the main thread.
public final class ShiftsDemoSession: @unchecked Sendable {
    private let lock = NSLock()
    private var requestSeq = 0
    private var shiftSeq = 0
    /// Requests by kind (seeded with one pending swap + one pending
    /// time-off so the manager queue is never empty in demo).
    public var requests: [ShiftChangeRequest] = [
        ShiftChangeRequest(id: "demo-req-swap-1", kind: "swap", state: "pending",
                           senderShiftID: "demo-shift-tom-fri", receiverUserID: "demo-u-ava",
                           message: "Can you take my Friday on-call?"),
        ShiftChangeRequest(id: "demo-req-off-1", kind: "timeoff", state: "pending",
                           receiverUserID: "demo-u-ava", reasonID: "demo-reason-vacation",
                           start: ShiftsDemo.stamp(10, 0), end: ShiftsDemo.stamp(12, 0),
                           message: "Long weekend"),
    ]
    /// Draft shifts created this session (land in the week grid).
    public var extraShifts: [ShiftItem] = []
    /// Draft time-off created this session.
    public var extraTimeOff: [TimeOffItem] = []
    /// Shift overlay by id (updated draft, or nil = deleted).
    public var shiftOverlay: [String: ShiftItem?] = [:]
    /// Time-off overlay by id (nil = deleted).
    public var timeOffOverlay: [String: TimeOffItem?] = [:]
    /// Share stamps drafts shared (demo publish).
    public var shared = false

    public init() {}

    /// Canned week + session overlays (draft extras stay draft until
    /// `shared` flips them, mirroring publish).
    public func response(teamID: String) -> ShiftWeekResponse {
        lock.lock(); defer { lock.unlock() }
        let base = ShiftsDemo.response(teamID: teamID)
        let shifts = base.shifts.compactMap { s -> ShiftItem? in
            guard let over = shiftOverlay[s.id] else { return self.applyShared(s) }
            return over.map { self.applyShared($0) }
        } + extraShifts.map { applyShared($0) }
        let offs = base.timesOff.compactMap { t -> TimeOffItem? in
            guard let over = timeOffOverlay[t.id] else { return self.applyShared(t) }
            return over.map { self.applyShared($0) }
        } + extraTimeOff.map { applyShared($0) }
        return ShiftWeekResponse(ok: true, team_id: teamID, schedule: base.schedule,
                                 shifts: shifts, timesOff: offs, reasons: base.reasons)
    }

    private func applyShared(_ s: ShiftItem) -> ShiftItem {
        guard shared, s.isDraft else { return s }
        return ShiftItem(id: s.id, userId: s.userId, displayName: s.displayName,
                         start: s.start, end: s.end, theme: s.theme, notes: s.notes, isDraft: false)
    }

    private func applyShared(_ t: TimeOffItem) -> TimeOffItem {
        guard shared, t.isDraft else { return t }
        return TimeOffItem(id: t.id, userId: t.userId, reasonId: t.reasonId,
                           start: t.start, end: t.end, isDraft: false)
    }

    func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    func nextRequestID() -> String {
        withLock {
            requestSeq += 1
            return "demo-req-\(requestSeq)"
        }
    }

    func nextShiftID() -> String {
        withLock {
            shiftSeq += 1
            return "demo-shift-new-\(shiftSeq)"
        }
    }
}
