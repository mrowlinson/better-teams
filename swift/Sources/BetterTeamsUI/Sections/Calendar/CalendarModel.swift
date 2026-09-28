// CalendarModel.swift — Calendar's pure pieces (UI-SPEC §6.4): the
// selection encoding (view + meeting live in `NavigationModel`, R3),
// the pane-state decision (R12, R18), meeting time formatting, and the
// week grid's lane assignment for overlapping meetings.
import Foundation
import OstMacCore

/// Calendar selection path: `[view]` or `[view, meetingID]`, view =
/// `agenda` | `week`. A bare `[meetingID]` (older state) reads as Agenda.
struct CalendarSelection: Equatable {
    enum View: String { case agenda, week }

    var view: View
    var meetingID: String?

    init(view: View = .agenda, meetingID: String? = nil) {
        self.view = view
        self.meetingID = meetingID
    }

    init(_ sel: SectionSelection?) {
        let p = sel?.path ?? []
        if let first = p.first, let v = View(rawValue: first) {
            view = v
            meetingID = p.count > 1 ? p[1] : nil
        } else {
            view = .agenda
            meetingID = p.first
        }
    }

    var selection: SectionSelection {
        SectionSelection([view.rawValue] + (meetingID.map { [$0] } ?? []))
    }

    /// Evidence alias (`calendar/demo-meeting`, §11.3): the demo week's
    /// first online meeting.
    static let demoMeetingAlias = "demo-meeting"
    static let demoMeetingID = "demo-cal-standup"
}

/// What the Calendar list (Agenda) or grid (Week) shows.
enum CalendarPaneState: Equatable {
    case loading
    case error(title: String, message: String)
    case empty
    case meetings

    static let errorTitle = "Couldn\u{2019}t Load Calendar"

    /// R12: a refresh never replaces meetings on screen with a spinner
    /// or an error; loading/error panes only when there is nothing to
    /// show. `forced` is the evidence `state=` override (demo only).
    static func resolve(_ state: MeetingsState, count: Int, forced: ForcedPaneState?, offline: Bool)
        -> CalendarPaneState
    {
        let offlineMessage = "You\u{2019}re offline."
        switch forced {
        case .loading: return .loading
        case .empty: return .empty
        case .error: return .error(title: errorTitle, message: offline ? offlineMessage : "Something went wrong.")
        case nil: break
        }
        if count > 0 { return .meetings }
        switch state {
        case .loading: return .loading
        case .error(let m): return .error(title: errorTitle, message: offline ? offlineMessage : m)
        case .empty, .loaded: return .empty
        }
    }
}

/// Meeting times. Graph datetimes are local wall-clock strings
/// ("2026-09-28T09:00:00.0000000"); only the first 19 characters count.
enum CalendarFormat {
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s, s.count >= 19 else { return nil }
        return parser.date(from: String(s.prefix(19)))
    }

    static func day(_ key: String) -> Date? { dayParser.date(from: key) }

    /// Minutes after midnight (week grid placement).
    static func minutes(_ s: String?) -> Int? {
        guard let s, s.count >= 16,
              let h = Int(s.dropFirst(11).prefix(2)), let m = Int(s.dropFirst(14).prefix(2)) else { return nil }
        return h * 60 + m
    }

    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    /// "9:00 AM – 9:15 AM" (start only when the end is unknown).
    static func range(_ m: MeetingItem) -> String {
        guard let s = date(m.start) else { return "" }
        guard let e = date(m.end) else { return time(s) }
        return "\(time(s)) \u{2013} \(time(e))"
    }

    /// "Monday, September 28" (or "Today").
    static func dayTitle(_ key: String, now: Date) -> String {
        guard let d = day(key) else { return key }
        if Calendar.current.isDate(d, inSameDayAs: now) { return "Today" }
        return d.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    /// Week subtitle: "Sep 27 – Oct 3".
    static func weekRange(_ start: Date) -> String {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start
        let f = Date.FormatStyle.dateTime.month(.abbreviated).day()
        return "\(start.formatted(f)) \u{2013} \(end.formatted(f))"
    }

    /// Join shows in a row when joinable now: from 10 minutes before the
    /// start until the end (§6.4 ±10 min).
    static func joinableNow(_ m: MeetingItem, now: Date) -> Bool {
        guard m.joinURL?.isEmpty == false, let s = date(m.start) else { return false }
        let e = date(m.end) ?? s.addingTimeInterval(3600)
        return now >= s.addingTimeInterval(-600) && now <= e.addingTimeInterval(600)
    }
}

/// Pure lane assignment for overlapping meetings in one day column:
/// meetings that overlap (transitively) form a cluster; each gets the
/// first free lane, and every meeting in a cluster shares its lane count.
enum WeekGridLanes {
    struct Slot: Equatable {
        var lane: Int
        var lanes: Int
    }

    /// `intervals` = (start, end) minutes, any order; result is aligned.
    static func assign(_ intervals: [(Int, Int)]) -> [Slot] {
        let order = intervals.indices.sorted {
            intervals[$0].0 != intervals[$1].0 ? intervals[$0].0 < intervals[$1].0 : $0 < $1
        }
        var out = [Slot](repeating: Slot(lane: 0, lanes: 1), count: intervals.count)
        var cluster: [Int] = []
        var laneEnds: [Int] = []
        var clusterEnd = Int.min
        func close() {
            for i in cluster { out[i].lanes = max(1, laneEnds.count) }
            cluster = []
            laneEnds = []
        }
        for i in order {
            let (s, e0) = intervals[i]
            let e = max(e0, s + 1)
            if !cluster.isEmpty, s >= clusterEnd { close() }
            if let free = laneEnds.firstIndex(where: { $0 <= s }) {
                laneEnds[free] = e
                out[i].lane = free
            } else {
                laneEnds.append(e)
                out[i].lane = laneEnds.count - 1
            }
            cluster.append(i)
            clusterEnd = cluster.count == 1 ? e : max(clusterEnd, e)
        }
        close()
        return out
    }
}
