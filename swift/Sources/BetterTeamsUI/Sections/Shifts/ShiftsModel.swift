// ShiftsModel.swift — Shifts week table rows and pane states (UI-SPEC
// §6.7, R18). Rows = people, columns = days; time off as its own rows.
import Foundation
import OstMacCore

/// One day column (Monday first).
struct ShiftsDay: Identifiable, Equatable {
    let id: Int
    let date: Date

    static func week(_ start: Date, calendar: Calendar = .current) -> [ShiftsDay] {
        (0 ..< 7).map { ShiftsDay(id: $0, date: calendar.date(byAdding: .day, value: $0, to: start) ?? start) }
    }

    /// "Mon 28".
    var title: String { date.formatted(.dateTime.weekday(.abbreviated).day()) }
}

/// One entry in a day cell: a shift or a time-off span.
struct ShiftsCell: Identifiable, Equatable {
    let id: String
    /// "9:00 AM – 5:00 PM" or "All Day".
    let time: String
    /// Shift label (theme label) or time-off reason.
    let label: String
    let theme: String?
    let isDraft: Bool
    let notes: String?
}

/// One table row: a person's shifts, or a person's time off.
struct ShiftsRow: Identifiable, Equatable {
    /// User id for shift rows, `off:<user id>` for time-off rows.
    let id: String
    let name: String
    let isTimeOff: Bool
    /// 7 day cells, Monday first.
    let days: [[ShiftsCell]]

    static let timeOffPrefix = "off:"
    static let openShiftsName = "Open Shifts"
    static let unknownName = "Team Member"

    static func name(_ userID: String?, _ names: [String: String]) -> String {
        guard let userID, !userID.isEmpty else { return openShiftsName }
        return names[userID] ?? unknownName
    }

    static func rows(week: ShiftWeek, reasons: [TimeOffReason], names: [String: String],
                     calendar: Calendar = .current) -> [ShiftsRow] {
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        var byUser: [String: [[ShiftsCell]]] = [:]
        for (day, shifts) in zip(0 ..< 7, week.columns) {
            for s in shifts {
                let key = s.userId ?? ""
                var days = byUser[key] ?? Array(repeating: [], count: 7)
                let start = ShiftItem.parse(dateTime: s.start)
                let end = ShiftItem.parse(dateTime: s.end)
                let range = [start, end].compactMap { $0?.formatted(time) }.joined(separator: " \u{2013} ")
                days[day].append(ShiftsCell(id: s.id, time: range, label: s.displayName, theme: s.theme,
                                            isDraft: s.isDraft, notes: s.notes))
                byUser[key] = days
            }
        }
        var out = byUser.map { key, days in
            ShiftsRow(id: key.isEmpty ? "open" : key, name: name(key, names), isTimeOff: false, days: days)
        }
        let reasonNames = Dictionary(reasons.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var offByUser: [String: [[ShiftsCell]]] = [:]
        let day0 = calendar.startOfDay(for: week.weekStart)
        for t in week.timeOff where ShiftsStore.overlaps(t, weekStart: day0, calendar: calendar) {
            let key = t.userId ?? ""
            var days = offByUser[key] ?? Array(repeating: [], count: 7)
            let s = ShiftItem.parse(dateTime: t.start) ?? .distantPast
            let e = ShiftItem.parse(dateTime: t.end) ?? .distantFuture
            for d in 0 ..< 7 {
                guard let ds = calendar.date(byAdding: .day, value: d, to: day0),
                      let de = calendar.date(byAdding: .day, value: 1, to: ds),
                      s < de, e > ds else { continue }
                let whole = s <= ds && e >= de
                let range = whole ? "All Day"
                    : "\(max(s, ds).formatted(time)) \u{2013} \(min(e, de).formatted(time))"
                days[d].append(ShiftsCell(id: "\(t.id)-\(d)", time: range,
                                          label: t.reasonId.flatMap { reasonNames[$0] } ?? "Time Off",
                                          theme: nil, isDraft: t.isDraft, notes: nil))
            }
            offByUser[key] = days
        }
        out += offByUser.map { key, days in
            ShiftsRow(id: timeOffPrefix + key, name: name(key, names), isTimeOff: true, days: days)
        }
        return out.sorted {
            $0.isTimeOff != $1.isTimeOff ? !$0.isTimeOff
                : $0.name != $1.name ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.id < $1.id
        }
    }
}

/// What the Shifts pane shows. Titles state the condition (R18).
enum ShiftsPaneState: Equatable {
    case loading
    /// No team has Shifts (or there are no teams): §6.7 empty copy.
    case notSetUp
    /// The team has Shifts; this week has no rows.
    case emptyWeek
    case error(title: String, message: String)
    case week

    static let notSetUpTitle = "Shifts isn\u{2019}t set up for your teams"
    static let notSetUpMessage = "When a team owner sets up Shifts, your schedule appears here."
    static let emptyWeekTitle = "No Shifts This Week"
    static let errorTitle = "Couldn\u{2019}t Load Shifts"
    static let offlineTitle = "You\u{2019}re Offline"
    static let offlineMessage = "The schedule appears when you\u{2019}re back online."

    static func resolve(_ state: ShiftsState, hasTeams: Bool, forced: ForcedPaneState?,
                        offline: Bool) -> ShiftsPaneState {
        func failed(_ m: String) -> ShiftsPaneState {
            offline ? .error(title: offlineTitle, message: offlineMessage) : .error(title: errorTitle, message: m)
        }
        switch forced {
        case .loading: return .loading
        case .empty: return .notSetUp
        case .error: return failed("Something went wrong.")
        case nil: break
        }
        switch state {
        case .idle, .loading: return .loading
        case .loaded: return .week
        case .empty: return hasTeams ? .emptyWeek : .notSetUp
        case .unavailable: return .notSetUp
        case .error(let m): return failed(m)
        }
    }
}
