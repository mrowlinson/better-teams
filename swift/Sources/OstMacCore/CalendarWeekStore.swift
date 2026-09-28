// CalendarWeekStore.swift — B1 calendar lane: week-grid state + schedule
// + cancel. Mirror of MeetingsViewModel seams: default runners call
// RustCore (blocking FFI) on detached tasks; tests inject mocks.
// `localEdits` (demo hosting) applies schedule/cancel in memory.
// Weeks are cached and (live) the weeks either side prefetched; paging
// to a cached week shows it at once, an uncached one keeps the week on
// screen — header and rows together — behind a spinner
// (`isLoadingWeek`) until the new week lands (CALWEEK, like Shifts LEFT2).
import Combine
import Foundation

/// Week-grid state machine + schedule/cancel flows for one week window.
@MainActor
public final class CalendarWeekStore: ObservableObject {
    /// Sync week fetch (runs off-main). Throws `CoreCallError` on failure.
    public typealias WeekFetcher = @Sendable (Int64) throws -> CalWeekResponse
    public typealias ScheduleRunner = @Sendable (
        String, String, String, String, Bool
    ) throws -> CalEventResult
    public typealias CancelRunner = @Sendable (String) throws -> CalCancelResult

    /// Latest meetings (only meaningful in `.loaded`; stale otherwise).
    @Published public private(set) var meetings: [MeetingItem] = []
    /// Current content state. Starts `.loading`.
    @Published public private(set) var state: MeetingsState = .loading
    /// Week midnight the grid covers (Monday when Monday-first).
    @Published public private(set) var weekStart: Date
    /// Selected grid day (`"yyyy-MM-dd"`); nil = today when in week.
    @Published public var selectedDayKey: String?
    /// Schedule sheet visibility.
    @Published public var showSchedule = false
    /// Schedule POST in flight.
    @Published public private(set) var scheduling = false
    /// Last schedule failure (user-facing). Nil when clear.
    @Published public private(set) var scheduleError: String?
    /// Event id with a cancel in flight (nil when idle).
    @Published public private(set) var cancelingID: String?
    /// Last cancel failure (user-facing). Nil when clear.
    @Published public private(set) var cancelError: String?
    /// A paged-to week is fetching behind the week on screen (header
    /// and rows stay the old week's until it lands).
    @Published public private(set) var isLoadingWeek = false

    /// Seven `"yyyy-MM-dd"` keys for the grid header row.
    public var dayKeys: [String] {
        CalWeek.dayKeys(weekStart: weekStart, calendar: calendar)
    }

    /// Meetings bucketed into the 7 grid columns.
    public var columns: [[MeetingItem]] {
        CalWeek.bucket(meetings, weekStart: weekStart, calendar: calendar)
    }

    /// Rows for the selected day (today when in week and nothing picked).
    public var selectedMeetings: [MeetingItem] {
        let keys = dayKeys
        let key: String?
        if let picked = selectedDayKey, keys.contains(picked) {
            key = picked
        } else {
            let today = dayKeyFormatter.string(from: Date())
            key = keys.contains(today) ? today : keys.first
        }
        guard let key else { return [] }
        return meetings
            .filter { CalWeek.dayKey(of: $0) == key }
            .sorted { ($0.start ?? "~") < ($1.start ?? "~") }
    }

    private let weekFetcher: WeekFetcher
    private let scheduleRunner: ScheduleRunner
    private let cancelRunner: CancelRunner
    private let calendar: Calendar
    private let localEdits: Bool
    private let dayKeyFormatter: DateFormatter
    /// Fetch the weeks either side of the one shown after it lands.
    private let prefetchesAdjacentWeeks: Bool
    /// Weeks fetched this session by week start, with fetch time.
    private var weekCache: [Int64: (response: CalWeekResponse, at: Date)] = [:]
    private var prefetching: Set<Int64> = []
    /// Target week while its fetch runs behind the week on screen;
    /// further ‹ › presses count from it.
    private var pendingWeekStart: Date?
    /// A cached week younger than this shows without a refetch.
    public static let weekFreshness: TimeInterval = 300

    public init(
        weekStart: Date = CalWeek.startOfWeek(containing: Date()),
        calendar: Calendar = .current,
        weekFetcher: @escaping WeekFetcher = { try RustCore.calWeek(weekStart: $0) },
        scheduleRunner: @escaping ScheduleRunner = {
            try RustCore.calSchedule(
                subject: $0, start: $1, end: $2, timeZone: $3, online: $4)
        },
        cancelRunner: @escaping CancelRunner = { try RustCore.calCancel(eventID: $0) },
        localEdits: Bool = false,
        prefetchAdjacentWeeks: Bool = false
    ) {
        self.prefetchesAdjacentWeeks = prefetchAdjacentWeeks
        self.weekStart = calendar.startOfDay(for: weekStart)
        self.calendar = calendar
        self.weekFetcher = weekFetcher
        self.scheduleRunner = scheduleRunner
        self.cancelRunner = cancelRunner
        self.localEdits = localEdits
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "yyyy-MM-dd"
        self.dayKeyFormatter = fmt
    }

    /// Bumped by every `load()`; a finishing load applies only while it
    /// is still the newest one (stale-drop for fast week paging).
    private var loadGeneration: UInt64 = 0

    /// Fetch the current week window. A slower earlier load that finishes
    /// after a newer one started (or after the week moved) is dropped, so
    /// it can never overwrite the newer week's meetings or state.
    public func load() async {
        pendingWeekStart = nil
        await fetch(weekStart, behind: false)
    }

    private func key(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970) }

    /// Fetch `target`. `behind`: the week on screen (header + rows) stays
    /// until the target lands; otherwise the pane shows `.loading`.
    private func fetch(_ target: Date, behind: Bool) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        if behind { isLoadingWeek = true } else { state = .loading }
        let fetcher = weekFetcher
        let start = key(target)
        let result: Result<CalWeekResponse, Error>
        do {
            result = .success(try await Task.detached { try fetcher(start) }.value)
        } catch {
            result = .failure(error)
        }
        if case .success(let response) = result { weekCache[start] = (response, Date()) }
        guard Self.isCurrent(
            generation: generation, latest: loadGeneration,
            start: start, weekStart: key(pendingWeekStart ?? weekStart))
        else { return }
        pendingWeekStart = nil
        isLoadingWeek = false
        switch result {
        case .success(let response):
            weekStart = target
            meetings = response.meetings
            state = response.meetings.isEmpty ? .empty : .loaded
            prefetch(around: target)
        case .failure(let error):
            state = .error(Self.message(for: error))
        }
    }

    /// Show `target`: cached → at once (refetched behind when stale);
    /// nothing on screen yet → plain load; else fetched behind the week
    /// on screen.
    private func go(to target: Date) {
        if let hit = weekCache[key(target)] {
            loadGeneration &+= 1 // an in-flight fetch for another week no longer applies
            pendingWeekStart = nil
            isLoadingWeek = false
            weekStart = target
            meetings = hit.response.meetings
            state = hit.response.meetings.isEmpty ? .empty : .loaded
            prefetch(around: target)
            if Date().timeIntervalSince(hit.at) > Self.weekFreshness {
                pendingWeekStart = target
                Task { await fetch(target, behind: true) }
            }
            return
        }
        if state == .loading && meetings.isEmpty {
            weekStart = target
            Task { await load() }
        } else {
            pendingWeekStart = target
            Task { await fetch(target, behind: true) }
        }
    }

    /// Fetch the weeks before and after `start` into the cache (quietly;
    /// a failure just leaves the week uncached).
    private func prefetch(around start: Date) {
        guard prefetchesAdjacentWeeks else { return }
        for days in [-7, 7] {
            guard let s = calendar.date(byAdding: .day, value: days, to: start) else { continue }
            let k = key(s)
            guard weekCache[k] == nil, prefetching.insert(k).inserted else { continue }
            let fetcher = weekFetcher
            Task {
                let resp = try? await Task.detached { try fetcher(k) }.value
                prefetching.remove(k)
                if let resp, weekCache[k] == nil { weekCache[k] = (resp, Date()) }
            }
        }
    }

    /// Drop the shown week's cache entry after a local schedule/cancel.
    private func invalidateShownWeek() {
        weekCache[key(weekStart)] = nil
    }

    /// Pure stale-drop rule: a load result applies only when it is the
    /// newest load and was fetched for the week currently shown.
    nonisolated static func isCurrent(
        generation: UInt64, latest: UInt64, start: Int64, weekStart: Int64
    ) -> Bool {
        generation == latest && start == weekStart
    }

    /// Fire-and-forget reload (error-state Retry, week paging).
    public func refresh() {
        Task { await load() }
    }

    /// Shift the window one week back and reload.
    public func prevWeek() {
        shiftWeek(by: -7)
    }

    /// Shift the window one week forward and reload.
    public func nextWeek() {
        shiftWeek(by: 7)
    }

    /// Jump to the week containing `date` (Today) and reload; no-op when
    /// that week is already shown.
    public func showWeek(containing date: Date) {
        let start = calendar.startOfDay(for: CalWeek.startOfWeek(containing: date, calendar: calendar))
        guard start != (pendingWeekStart ?? weekStart) else { return }
        go(to: start)
    }

    private func shiftWeek(by days: Int) {
        let from = pendingWeekStart ?? weekStart
        guard let target = calendar.date(byAdding: .day, value: days, to: from) else { return }
        go(to: target)
    }

    /// Schedule one meeting (`start`/`end` are Graph datetimes). Empty
    /// subjects and inverted ranges fail locally; on success the created
    /// event appends and the sheet closes.
    public func schedule(subject: String, start: String, end: String, online: Bool) {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            scheduleError = "Subject is required"
            return
        }
        guard end > start else {
            scheduleError = "End must be after start"
            return
        }
        if localEdits {
            meetings.append(MeetingItem(
                meetingId: "demo-cal-local-\(meetings.count + 1)",
                subject: trimmed, start: start, end: end,
                isOrganizer: true, isOnline: online))
            scheduleError = nil
            showSchedule = false
            if state == .empty { state = .loaded }
            invalidateShownWeek()
            return
        }
        let runner = scheduleRunner
        let timeZone = TimeZone.current.identifier
        scheduleError = nil
        scheduling = true
        Task.detached { [weak self] in
            do {
                let created = try runner(trimmed, start, end, timeZone, online)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.meetings.append(created.event)
                    self.invalidateShownWeek()
                    self.scheduling = false
                    self.showSchedule = false
                    if self.state == .empty { self.state = .loaded }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.scheduling = false
                    self?.scheduleError = Self.message(for: error)
                }
            }
        }
    }

    /// Dismiss the schedule sheet and clear its error.
    public func dismissSchedule() {
        showSchedule = false
        scheduleError = nil
    }

    /// Cancel one meeting. On success the row drops; on failure the row
    /// stays and `cancelError` surfaces. No-op while a cancel runs.
    public func cancel(eventID: String) {
        guard cancelingID == nil else { return }
        if localEdits {
            meetings.removeAll { $0.id == eventID }
            invalidateShownWeek()
            cancelError = nil
            if meetings.isEmpty { state = .empty }
            return
        }
        let runner = cancelRunner
        cancelError = nil
        cancelingID = eventID
        Task.detached { [weak self] in
            do {
                _ = try runner(eventID)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.meetings.removeAll { $0.id == eventID }
                    self.invalidateShownWeek()
                    self.cancelingID = nil
                    if self.meetings.isEmpty { self.state = .empty }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.cancelingID = nil
                    self?.cancelError = Self.message(for: error)
                }
            }
        }
    }

    nonisolated static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}

/// Calendar labels (fid-lists D25): exact Teams copy, pinned by
/// FidListsTests. Moved from CalendarWeekView.swift (scratch-ui
/// rebuild deleted the view; the label contract stays).
public enum CalendarLabels {
    /// Calendar button + sheet title: Teams "New meeting".
    public static let newMeeting = "New meeting"
}
