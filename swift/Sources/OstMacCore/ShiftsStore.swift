// ShiftsStore.swift — om-shifts lane: schedule week store (read-only).
//
// Team picker + week grid state over one core call per team. Tests and
// demo inject a mock week fetcher (same seam as ChannelTabsStore).
// The default fetcher hits `ostmac_schedule_range`: the server returns
// only the shifts and time off overlapping the week on screen, so week
// navigation refetches (P4B-LEFT; was the whole schedule, filtered here).
// Weeks are cached per team and the weeks either side prefetched; a
// week change or Retry never blanks the grid: an uncached week keeps
// the grid on screen (`isLoadingWeek`) until it lands (LEFT2).
import COstMac
import Combine
import Foundation

/// Schedule-week content state.
public enum ShiftsState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case empty
    case error(String)
    /// Every picker team 404'd (no Shifts access anywhere): clean
    /// empty state, never raw JSON. The browser shows the team picker
    /// + Retry so the user can switch teams or retry later.
    case unavailable(String)
}

/// Teams answered while the picker is probed for a team with Shifts
/// ("Loading Shifts… 3 of 9 teams").
public struct ShiftsLoadProgress: Equatable, Sendable {
    public let done: Int
    public let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

extension RustCore {
    /// One team's schedule week (blocking FFI + network: call off the
    /// main thread).
    public static func shiftsWeek(teamID: String) throws -> ShiftWeekResponse {
        try teamID.withCString { ptr in
            try call(ostmac_schedule_week(ptr), as: ShiftWeekResponse.self)
        }
    }

    /// One team's schedule for the 7 days from `weekStart` (server-side
    /// range filter; blocking FFI + network: call off the main thread).
    public static func shiftsWeek(teamID: String, weekStart: Date) throws -> ShiftWeekResponse {
        let (start, end) = ShiftsStore.rangeBounds(weekStart: weekStart)
        return try teamID.withCString { t in
            try start.withCString { s in
                try end.withCString { e in
                    try call(ostmac_schedule_range(t, s, e), as: ShiftWeekResponse.self)
                }
            }
        }
    }
}

@MainActor
public final class ShiftsStore: ObservableObject {
    public typealias WeekFetcher = @Sendable (String) throws -> ShiftWeekResponse
    /// (team id, week start) → that week's schedule (server-side range).
    public typealias RangeFetcher = @Sendable (String, Date) throws -> ShiftWeekResponse
    public typealias MembersFetcher = @Sendable (String) throws -> TeamMembersResponse

    @Published public private(set) var teams: [ShiftTeam] = []
    @Published public private(set) var selectedTeamID: String?
    @Published public private(set) var week: ShiftWeek?
    @Published public private(set) var state: ShiftsState = .idle
    /// First day of the week on screen (week navigation, UI-SPEC §6.7).
    @Published public private(set) var weekStart: Date = ShiftsStore.currentWeekStart()
    /// Roster names of the selected team (user id → display name) for
    /// the people rows; empty until the roster lands (rows fall back).
    @Published public private(set) var memberNames: [String: String] = [:]

    /// A week fetch runs behind the grid on screen (week navigation,
    /// Retry): the toolbar shows a small progress indicator; the grid
    /// never blanks.
    @Published public private(set) var isLoadingWeek = false
    /// Last background week fetch failure; the grid on screen stays.
    /// Nil when clear.
    @Published public private(set) var weekError: String?
    /// Picker probe progress while no grid is on screen (nil when not
    /// probing: a single-team fetch, a refresh behind a grid, settled).
    @Published public private(set) var loadProgress: ShiftsLoadProgress?
    /// Picker teams fetched at once while looking for a team with Shifts.
    public static let maxConcurrentTeams = 4

    private let weekFetcher: RangeFetcher
    /// Fetch the weeks either side of the one on screen after it lands
    /// (server-range fetchers only: a whole-schedule fetcher already
    /// holds every week).
    private let prefetchesAdjacentWeeks: Bool
    private let membersFetcher: MembersFetcher?
    /// Weeks fetched this session by team + week start, with fetch time.
    private var weekCache: [String: (response: ShiftWeekResponse, at: Date)] = [:]
    private var prefetching: Set<String> = []
    /// Target week while its fetch runs (the grid on screen stays until
    /// it lands; further ‹ › presses count from it).
    private var pendingWeekStart: Date?
    /// Team whose grid is on screen (nil = nothing shown yet).
    private var gridTeamID: String?
    /// A cached week younger than this shows without a refetch.
    public static let weekFreshness: TimeInterval = 300
    /// The selected team's last response (the week on screen; a whole
    /// schedule for `week:` fetchers). The grid is built from it.
    private var lastResponse: ShiftWeekResponse?
    private var openGeneration = 0

    /// NOLOAD: last-good snapshot store (nil = memory only / demo).
    /// Holds the team picker, cached weeks (this week ± 4, every team
    /// seen) and member names — the signed-in user's own tenant data,
    /// on this Mac only.
    public var snapshots: SectionCache?
    static let snapshotKey = "shifts"
    static let snapshotSpan: TimeInterval = 5 * 7 * 86_400
    private var memberNamesCache: [String: [String: String]] = [:]

    struct CachedWeek: Codable {
        let response: ShiftWeekResponse
        let at: Date
    }

    struct Snapshot: Codable {
        let teams: [ShiftTeam]
        let selectedTeamID: String?
        let weeks: [String: CachedWeek]
        let names: [String: [String: String]]
    }

    /// Load the last good picker + weeks into the session cache (no
    /// state change: the host's seed/open then hits the cache and paints
    /// the grid at once, refreshing behind).
    @discardableResult
    public func restoreSnapshot() -> Bool {
        guard let snap = snapshots?.load(Snapshot.self, key: Self.snapshotKey),
              !snap.teams.isEmpty else { return false }
        for (k, w) in snap.weeks where weekCache[k] == nil {
            weekCache[k] = (w.response, w.at)
        }
        memberNamesCache.merge(snap.names) { cur, _ in cur }
        if teams.isEmpty { teams = snap.teams }
        if selectedTeamID == nil { selectedTeamID = snap.selectedTeamID }
        return true
    }

    /// True when the selected team's shown week is in the cache (the
    /// host can open it before the live teams list lands).
    public var hasCachedWeek: Bool {
        guard let id = selectedTeamID else { return false }
        return weekCache[Self.cacheKey(id, weekStart)] != nil
    }

    private func saveSnapshot() {
        guard let snapshots, !teams.isEmpty else { return }
        let now = Self.currentWeekStart().timeIntervalSince1970
        var weeks: [String: CachedWeek] = [:]
        for (k, w) in weekCache {
            guard let t = k.split(separator: "|").last.flatMap({ TimeInterval(String($0)) }),
                  abs(t - now) <= Self.snapshotSpan else { continue }
            weeks[k] = CachedWeek(response: w.response, at: w.at)
        }
        snapshots.save(Snapshot(teams: teams, selectedTeamID: selectedTeamID, weeks: weeks,
                                names: memberNamesCache), key: Self.snapshotKey)
    }

    /// Host reload for Retry-without-teams (F6): the app sets this to
    /// reload the teams list and re-seed shifts (same hook shape as
    /// `PresenceStore.manualSetHook`). Fired by `refresh()` when no
    /// team is selected; nil = Retry stands down silently.
    public var reloadTeams: (() -> Void)?

    /// Live default: the server returns the week on screen only.
    public nonisolated convenience init(
        range: @escaping RangeFetcher = { try RustCore.shiftsWeek(teamID: $0, weekStart: $1) },
        members: MembersFetcher? = nil
    ) {
        self.init(range: range, members: members, prefetch: true)
    }

    private nonisolated init(range: @escaping RangeFetcher, members: MembersFetcher?, prefetch: Bool) {
        self.weekFetcher = range
        self.membersFetcher = members
        self.prefetchesAdjacentWeeks = prefetch
    }

    /// Whole-schedule fetcher (demo, tests): every week comes from the
    /// same response, filtered to the week on screen.
    public nonisolated convenience init(week: @escaping WeekFetcher, members: MembersFetcher? = nil) {
        self.init(range: { id, _ in try week(id) }, members: members, prefetch: false)
    }

    /// `[weekStart, weekStart + 7 days]` as UTC ISO-8601 strings (the
    /// core range bounds).
    public nonisolated static func rangeBounds(
        weekStart: Date, calendar: Calendar = .current
    ) -> (String, String) {
        let day0 = calendar.startOfDay(for: weekStart)
        let end = calendar.date(byAdding: .day, value: 7, to: day0) ?? day0.addingTimeInterval(7 * 86_400)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return (f.string(from: day0), f.string(from: end))
    }

    /// Move the grid by whole weeks (‹ ›). A cached week shows at once;
    /// otherwise the grid on screen stays until the week lands.
    public func showWeek(offset: Int, calendar: Calendar = .current) {
        guard offset != 0,
              let start = calendar.date(byAdding: .weekOfYear, value: offset, to: pendingWeekStart ?? weekStart)
        else { return }
        go(to: start, calendar: calendar)
    }

    /// Back to the current week (Today).
    public func showCurrentWeek(calendar: Calendar = .current) {
        let start = Self.currentWeekStart(calendar: calendar)
        guard start != (pendingWeekStart ?? weekStart) else { return }
        go(to: start, calendar: calendar)
    }

    private static func cacheKey(_ team: String, _ start: Date) -> String {
        "\(team)|\(Int(start.timeIntervalSince1970))"
    }

    /// Show `start` for the team on screen: from the cache (refetched
    /// behind when stale), else fetched behind the grid on screen. Only
    /// a team with no grid yet shows the loading pane.
    private func go(to start: Date, calendar: Calendar) {
        guard let id = selectedTeamID else { weekStart = start; return }
        switch state {
        case .idle, .unavailable:
            weekStart = start // nothing opened / no team has Shifts
            return
        default: break
        }
        if let hit = weekCache[Self.cacheKey(id, start)] {
            openGeneration += 1 // a fetch for another target no longer applies
            pendingWeekStart = nil
            isLoadingWeek = false
            weekError = nil
            weekStart = start
            lastResponse = hit.response
            rebuild(calendar: calendar)
            prefetch(around: start, team: id, calendar: calendar)
            if Date().timeIntervalSince(hit.at) > Self.weekFreshness { fetchWeek(id, start, calendar: calendar) }
            return
        }
        if gridTeamID == nil {
            weekStart = start
            week = nil
            loadProgress = nil
            state = .loading
        } else {
            pendingWeekStart = start
        }
        fetchWeek(id, start, calendar: calendar)
    }

    /// Fetch one week for the team on screen (no fallthrough to other
    /// teams: the team already answered). Stale completions (another
    /// week or team since) are dropped. A failure with a grid on screen
    /// keeps the grid (`weekError`); without one the pane shows it.
    private func fetchWeek(_ id: String, _ start: Date, calendar: Calendar) {
        openGeneration += 1
        let gen = openGeneration
        isLoadingWeek = true
        let fetcher = weekFetcher
        Task {
            do {
                let resp = try await Task.blocking { try fetcher(id, start) }.value
                weekCache[Self.cacheKey(id, start)] = (resp, Date())
                saveSnapshot()
                guard gen == openGeneration else { return }
                pendingWeekStart = nil
                isLoadingWeek = false
                weekError = nil
                weekStart = start
                lastResponse = resp
                gridTeamID = id
                rebuild(calendar: calendar)
                prefetch(around: start, team: id, calendar: calendar)
            } catch {
                guard gen == openGeneration else { return }
                pendingWeekStart = nil
                isLoadingWeek = false
                if gridTeamID == nil {
                    week = nil
                    lastResponse = nil
                    state = .error(Self.message(for: error))
                } else {
                    weekError = Self.message(for: error)
                }
            }
        }
    }

    /// Fetch the weeks before and after `start` into the cache (quietly;
    /// a failure just leaves the week uncached).
    private func prefetch(around start: Date, team: String, calendar: Calendar) {
        guard prefetchesAdjacentWeeks else { return }
        for offset in [-1, 1] {
            guard let s = calendar.date(byAdding: .weekOfYear, value: offset, to: start) else { continue }
            let key = Self.cacheKey(team, s)
            guard weekCache[key] == nil, prefetching.insert(key).inserted else { continue }
            let fetcher = weekFetcher
            Task {
                if let resp = try? await Task.blocking(operation: { try fetcher(team, s) }).value {
                    weekCache[key] = (resp, Date())
                    saveSnapshot()
                }
                prefetching.remove(key)
            }
        }
    }

    public var isCurrentWeek: Bool { weekStart == Self.currentWeekStart() }

    /// Time-off reasons of the team on screen (time-off row labels).
    public var reasons: [TimeOffReason] { lastResponse?.reasons ?? [] }

    /// True when a time-off instance overlaps the 7 days from `weekStart`
    /// (open-ended or unparseable instances count, so none are hidden).
    public nonisolated static func overlaps(
        _ item: TimeOffItem, weekStart: Date, calendar: Calendar = .current
    ) -> Bool {
        let day0 = calendar.startOfDay(for: weekStart)
        guard let end = calendar.date(byAdding: .day, value: 7, to: day0) else { return true }
        let s = ShiftItem.parse(dateTime: item.start)
        let e = ShiftItem.parse(dateTime: item.end)
        if let s, s >= end { return false }
        if let e, e <= day0 { return false }
        return true
    }

    /// Week grid from the last response at `weekStart`. The state keeps
    /// its response-level meaning (shifts this week or any time off);
    /// the view shows "No Shifts This Week" when the week has no rows.
    private func rebuild(calendar: Calendar = .current) {
        guard let resp = lastResponse else { return }
        let built = ShiftWeek.build(from: resp, weekStart: weekStart, calendar: calendar)
        week = built
        let hasRows = built.columns.contains { !$0.isEmpty } || !built.timeOff.isEmpty
        state = hasRows ? .loaded : .empty
    }

    /// Roster names for the people rows (nil fetcher = none; best effort: a failure keeps
    /// the fallback labels, never an error state).
    private func loadMembers(teamID: String, generation gen: Int) {
        guard let fetcher = membersFetcher else { return }
        Task {
            guard let resp = try? await Task.blocking(operation: { try fetcher(teamID) }).value,
                  gen == openGeneration
            else { return }
            var names: [String: String] = [:]
            for m in resp.members {
                if let id = m.userId, !id.isEmpty { names[id] = m.displayName }
                names[m.id] = m.displayName
            }
            memberNames = names
            memberNamesCache[teamID] = names
            saveSnapshot()
        }
    }

    /// Week start for the grid (Monday 00:00 local by default).
    public nonisolated static func currentWeekStart(calendar: Calendar = .current) -> Date {
        var cal = calendar
        cal.firstWeekday = 2 // Monday
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        return cal.date(from: comps) ?? cal.startOfDay(for: Date())
    }

    /// Seed the team picker (host passes joined teams).
    public func setTeams(_ teams: [ShiftTeam]) {
        self.teams = teams
        if selectedTeamID == nil {
            selectedTeamID = teams.first?.id
        }
    }

    /// Pick a team and fetch its week.
    public func select(teamID: String) {
        selectedTeamID = teamID
        open(teamID: teamID)
    }

    /// One picker team's answer while probing for a week.
    private enum TeamOutcome {
        case week(ShiftWeekResponse)
        /// Shifts not set up / not reachable for this team: a 404 /
        /// TeamNotFound, or a schedule that is not enabled.
        case noShifts
        case failed(Error)
    }

    private static func outcome(_ result: Result<ShiftWeekResponse, Error>) -> TeamOutcome {
        switch result {
        case .success(let resp):
            return resp.schedule.enabled ? .week(resp) : .noShifts
        case .failure(let error):
            return isNotFound(rawMessage(for: error)) ? .noShifts : .failed(error)
        }
    }

    /// Candidate to show: the first (requested first, then picker
    /// order) with a week, once every candidate before it has answered
    /// without one. Nil while an earlier candidate is still loading, so
    /// a later team never flashes up ahead of the requested one.
    private static func firstLanded(_ outcomes: [TeamOutcome?]) -> Int? {
        for (i, outcome) in outcomes.enumerated() {
            guard let outcome else { return nil }
            if case .week = outcome { return i }
        }
        return nil
    }

    /// Blocking core fetch off the main thread (never throws: the
    /// failure travels in the result).
    private nonisolated static func fetchResult(
        _ fetcher: @escaping RangeFetcher, _ team: String, _ start: Date
    ) async -> Result<ShiftWeekResponse, Error> {
        await Task.blocking { Result { try fetcher(team, start) } }.value
    }

    /// Open a team: fetch its week via core, replace the grid. Stale
    /// completions are dropped (fast team-switching lands newest).
    /// Without a grid of this team on screen the requested team and
    /// the rest of the picker are fetched together (at most
    /// `maxConcurrentTeams` at once, `loadProgress` counting answers):
    /// teams without Shifts (404 / TeamNotFound / schedule not enabled)
    /// are skipped, and the first team in order with a week lands as
    /// soon as every team before it has answered. Only when no team
    /// has a week does the pane fail: `.error` for the first real
    /// failure, else `.unavailable` (never raw JSON). A valid-but-empty
    /// week lands (the team has Shifts, just no rows). With the team's
    /// grid on screen only that team is refetched; a failure keeps the
    /// grid (`weekError`).
    public func open(teamID: String) {
        openGeneration += 1
        let gen = openGeneration
        let id = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            selectedTeamID = nil
            week = nil
            gridTeamID = nil
            isLoadingWeek = false
            loadProgress = nil
            state = .idle
            return
        }
        selectedTeamID = id
        pendingWeekStart = nil
        weekError = nil
        let start = weekStart
        if let hit = weekCache[Self.cacheKey(id, start)] {
            // Seen this session: show it now, refresh behind.
            if id != gridTeamID { memberNames = memberNamesCache[id] ?? [:] }
            lastResponse = hit.response
            gridTeamID = id
            rebuild()
        } else if id != gridTeamID {
            gridTeamID = nil
            state = .loading
        }
        // The grid on screen (this team's) stays while the fetch runs.
        let hasGrid = gridTeamID == id
        isLoadingWeek = hasGrid
        // Requested first, then the rest of the picker in order
        // (unknown ids still try once); a grid refresh asks its team only.
        var candidates = [id]
        if !hasGrid {
            for team in teams where team.id != id {
                candidates.append(team.id)
            }
        }
        let names = Dictionary(uniqueKeysWithValues: teams.map { ($0.id, $0.name) })
        loadProgress = hasGrid ? nil : ShiftsLoadProgress(done: 0, total: candidates.count)
        let fetcher = weekFetcher
        let limit = Self.maxConcurrentTeams
        Task {
            var outcomes = [TeamOutcome?](repeating: nil, count: candidates.count)
            // True once settled inside the group (landed, refresh
            // failure, or superseded by a newer open).
            let settled: Bool = await withTaskGroup(
                of: (Int, Result<ShiftWeekResponse, Error>).self
            ) { group in
                var next = 0
                while next < min(limit, candidates.count) {
                    let (i, team) = (next, candidates[next])
                    group.addTask { (i, await Self.fetchResult(fetcher, team, start)) }
                    next += 1
                }
                var done = 0
                for await (i, result) in group {
                    guard gen == openGeneration else { return true }
                    done += 1
                    let outcome = Self.outcome(result)
                    outcomes[i] = outcome
                    if case .week(let resp) = outcome {
                        weekCache[Self.cacheKey(candidates[i], start)] = (resp, Date())
                        saveSnapshot()
                    }
                    if hasGrid {
                        switch outcome {
                        case .week: break
                        case .failed(let error):
                            // A refresh failed: the grid on screen stays.
                            isLoadingWeek = false
                            weekError = Self.message(for: error, teamName: names[id])
                            return true
                        case .noShifts:
                            isLoadingWeek = false
                            weekError = Self.notUsingShiftsMessage(teamName: names[id])
                            return true
                        }
                    }
                    if let w = Self.firstLanded(outcomes), case .week(let resp)? = outcomes[w] {
                        let candidate = candidates[w]
                        if candidate != lastResponse?.team_id { memberNames = [:] }
                        lastResponse = resp
                        selectedTeamID = candidate
                        gridTeamID = candidate
                        isLoadingWeek = false
                        loadProgress = nil
                        rebuild()
                        loadMembers(teamID: candidate, generation: gen)
                        prefetch(around: start, team: candidate, calendar: .current)
                        return true
                    }
                    loadProgress = ShiftsLoadProgress(done: done, total: candidates.count)
                    if next < candidates.count {
                        let (j, team) = (next, candidates[next])
                        group.addTask { (j, await Self.fetchResult(fetcher, team, start)) }
                        next += 1
                    }
                }
                return false
            }
            guard !settled, gen == openGeneration else { return }
            week = nil
            lastResponse = nil
            gridTeamID = nil
            isLoadingWeek = false
            loadProgress = nil
            // The first real failure (picker order) outranks "no Shifts".
            for (i, outcome) in outcomes.enumerated() {
                if case .failed(let error)? = outcome {
                    selectedTeamID = candidates[i]
                    state = .error(Self.message(for: error, teamName: names[candidates[i]]))
                    return
                }
            }
            selectedTeamID = id
            if teams.isEmpty {
                state = .error(Self.notUsingShiftsMessage(teamName: nil))
            } else {
                state = .unavailable(Self.allUnavailableMessage())
            }
        }
    }

    /// Fire-and-forget reload. With no selected team (zero-teams
    /// seed) Retry re-asks the host to reload teams instead of
    /// no-op'ing (F6).
    public func refresh() {
        guard let id = selectedTeamID else {
            reloadTeams?()
            return
        }
        open(teamID: id)
    }

    /// Zero-teams seed (F6): the teams list settled with no rows
    /// (live fetch fail/zero teams). Lands `.empty` with the picker
    /// cleared — the browser shows join/retry guidance — instead of
    /// stranding `.idle`'s infinite spinner.
    public func showNoTeams() {
        teams = []
        selectedTeamID = nil
        week = nil
        gridTeamID = nil
        loadProgress = nil
        state = .empty
    }

    /// Teams-list load failure (F6): surfaces the failure in the
    /// browser's `.error` state with Retry (sanitized, never raw
    /// JSON) instead of stranding `.idle`'s infinite spinner.
    public func showTeamsError(_ message: String) {
        teams = []
        selectedTeamID = nil
        week = nil
        gridTeamID = nil
        loadProgress = nil
        state = .error(Self.sanitize(message))
    }

    /// Raw core message (may embed a Graph URL + JSON blob).
    static func rawMessage(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }

    /// True for a missing-schedule 404 (`TeamNotFound` Graph code or
    /// an HTTP 404 status in the core chain).
    /// The status is matched as `HTTP 404`, never a bare "404": every
    /// core error embeds the Graph URL, whose team GUID can hold those
    /// digits.
    static func isNotFound(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("teamnotfound") || lower.contains("http 404")
    }

    /// True for sign-in failures (401/403 statuses; `HTTP 40x` or the
    /// status words, never bare digits: see `isNotFound`).
    static func isAuthFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("http 401") || lower.contains("http 403")
            || lower.contains("unauthorized") || lower.contains("forbidden")
    }

    /// True for transport failures (offline, DNS, timeouts, drops).
    static func isNetworkFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("network") || lower.contains("timed out")
            || lower.contains("timeout") || lower.contains("connection")
            || lower.contains("could not connect") || lower.contains("dns")
            || lower.contains("offline") || lower.contains("not connected")
            || lower.contains("urlerror")
    }

    /// Humanized one-liner for the empty state. TeamNotFound/404 names
    /// the team; auth/network map to hint lines; anything else is
    /// sanitized. Never emits raw JSON (no `{` anywhere).
    static func message(for error: Error, teamName: String? = nil) -> String {
        let raw = rawMessage(for: error)
        if isNotFound(raw) {
            return notUsingShiftsMessage(teamName: teamName)
        }
        if isAuthFailure(raw) {
            return "Your sign-in may have expired. Sign in again, then retry."
        }
        if isNetworkFailure(raw) {
            return "Couldn't reach the service. Check your connection, then retry."
        }
        let friendly = FriendlyError.message(raw)
        return friendly != raw ? friendly : sanitize(raw)
    }

    /// One team without Shifts (404 / schedule not enabled), naming
    /// the team when known.
    static func notUsingShiftsMessage(teamName: String?) -> String {
        var who = (teamName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let brace = who.firstIndex(of: "{") {
            who = String(who[..<brace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return who.isEmpty
            ? "This team does not use Shifts or you cannot access it."
            : "\(who) does not use Shifts or you cannot access it."
    }

    /// All-picker-teams-404'd body (title lives in the browser).
    static func allUnavailableMessage() -> String {
        "None of your teams use Shifts, or you can't access them. Pick another team or retry later."
    }

    /// Strip Graph URLs + JSON blobs; never empty, never `{`-led.
    static func sanitize(_ raw: String) -> String {
        var text = raw
        if let brace = text.firstIndex(of: "{") {
            text = String(text[..<brace])
        }
        if let url = text.range(of: "https?://", options: .regularExpression) {
            text = String(text[..<url.lowerBound])
        }
        text = text
            .replacingOccurrences(
                of: #"\s+for\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(
                of: #"[:\s]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Couldn't load shifts. Retry." }
        if text.count > 300 {
            text = String(text.prefix(300))
                .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return text
    }
}
