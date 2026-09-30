// CalendarStoreActions.swift — CALENDAR lane: day/month navigation,
// system time-zone changes, event details, RSVP, edit and Meet now on
// `CalendarWeekStore`. Live calls run on detached tasks (blocking
// Graph); demo (`localEdits`) applies everything in memory.
import Combine
import Foundation

/// Calendar calls past the week read (tests inject stubs).
public struct CalendarRunners: Sendable {
    public var detail: @Sendable (String) throws -> CalendarEventDetail
    /// `(event id, action)`: the id is an occurrence or a series master.
    public var respond: @Sendable (String, RSVPAction) throws -> Void
    public var update: @Sendable (String, CalendarEventPatch) throws -> MeetingItem
    /// Meet now: create a solo online meeting from now, `subject` named.
    public var meetNow: @Sendable (String) throws -> MeetingItem
    /// `(event id, recipients, comment)`.
    public var forward: @Sendable (String, [String], String) throws -> Void
    /// Remove an invitation from the user's own calendar (no response).
    public var remove: @Sendable (String) throws -> Void
    /// `(event id, attachment id)` → file bytes.
    public var attachment: @Sendable (String, String) throws -> Data
    /// `(addresses, from, to)` → free/busy.
    public var schedule: @Sendable ([String], Date, Date) throws -> [CalendarFreeBusy]
    public var categories: @Sendable () throws -> [CalendarCategory]
    /// A full new event (Duplicate: attendees, location, body kept).
    public var create: @Sendable (CalendarEventDraft) throws -> MeetingItem
    /// `(title, start, end)` → draft webinar id.
    public var webinar: @Sendable (String, Date, Date) throws -> String
    /// `(series master id, from, to)` → the series' occurrences.
    public var instances: @Sendable (String, Date, Date) throws -> [MeetingItem]

    public static let unsupported: @Sendable () -> Error = { CoreCallError.failed("calendar: not available") }

    public init(
        detail: @escaping @Sendable (String) throws -> CalendarEventDetail,
        respond: @escaping @Sendable (String, RSVPAction) throws -> Void,
        update: @escaping @Sendable (String, CalendarEventPatch) throws -> MeetingItem,
        meetNow: @escaping @Sendable (String) throws -> MeetingItem,
        forward: @escaping @Sendable (String, [String], String) throws -> Void = { _, _, _ in throw unsupported() },
        remove: @escaping @Sendable (String) throws -> Void = { _ in throw unsupported() },
        attachment: @escaping @Sendable (String, String) throws -> Data = { _, _ in throw unsupported() },
        schedule: @escaping @Sendable ([String], Date, Date) throws -> [CalendarFreeBusy] = { _, _, _ in throw unsupported() },
        categories: @escaping @Sendable () throws -> [CalendarCategory] = { throw unsupported() },
        create: @escaping @Sendable (CalendarEventDraft) throws -> MeetingItem = { _ in throw unsupported() },
        webinar: @escaping @Sendable (String, Date, Date) throws -> String = { _, _, _ in throw unsupported() },
        instances: @escaping @Sendable (String, Date, Date) throws -> [MeetingItem] = { _, _, _ in throw unsupported() }
    ) {
        self.detail = detail
        self.respond = respond
        self.update = update
        self.meetNow = meetNow
        self.forward = forward
        self.remove = remove
        self.attachment = attachment
        self.schedule = schedule
        self.categories = categories
        self.create = create
        self.webinar = webinar
        self.instances = instances
    }

    /// Signed-in profile over Graph.
    public static var production: CalendarRunners {
        CalendarRunners(
            detail: { try CalendarGraph.production().detail(id: $0) },
            respond: { try CalendarGraph.production().respond(id: $0, action: $1) },
            update: { try CalendarGraph.production().update(id: $0, patch: $1) },
            meetNow: { subject in
                let now = Date()
                return try CalendarGraph.production().create(
                    subject: subject, start: now, end: now.addingTimeInterval(3600), online: true)
            },
            forward: { try CalendarGraph.production().forward(id: $0, to: $1, comment: $2) },
            remove: { try CalendarGraph.production().delete(id: $0) },
            attachment: { try CalendarGraph.production().attachment(eventID: $0, attachmentID: $1) },
            schedule: { try CalendarGraph.production().schedule(for: $0, from: $1, to: $2) },
            categories: { try CalendarGraph.production().masterCategories() },
            create: { try CalendarGraph.production().create($0) },
            webinar: { try CalendarGraph.production().createWebinar(title: $0, start: $1, end: $2) },
            instances: { try CalendarGraph.production().instances(seriesID: $0, from: $1, to: $2) })
    }

    /// New-meeting sheet over Graph (`start`/`end` local datetimes in `tz`).
    public static let graphSchedule: CalendarWeekStore.ScheduleRunner = { subject, start, end, tz, online in
        guard let s = CalendarTime.instant(start, zone: tz), let e = CalendarTime.instant(end, zone: tz) else {
            throw CoreCallError.failed("calendar: bad meeting time")
        }
        return CalEventResult(
            ok: true, event: try CalendarGraph.production().create(subject: subject, start: s, end: e, online: online))
    }

    public static let graphCancel: CalendarWeekStore.CancelRunner = { id in
        try CalendarGraph.production().delete(id: id)
        return CalCancelResult(ok: true, id: id)
    }
}

extension CalendarWeekStore {
    // MARK: day / week / month navigation

    public enum Span: Sendable { case day, week, month }

    /// `"yyyy-MM-dd"` of `date` in the display zone.
    public func dayKey(_ date: Date) -> String { dayKeyFormatter.string(from: date) }

    /// `"yyyy-MM-dd"` → local midnight.
    public func date(forKey key: String) -> Date? {
        dayKeyFormatter.date(from: key).map { calendar.startOfDay(for: $0) }
    }

    /// The day the Day view shows: the focus day once its week is on
    /// screen, else the nearest day of the week still shown (no blank
    /// column while the new week loads).
    public var dayViewKey: String {
        let keys = dayKeys
        let k = dayKey(focusDay)
        if keys.contains(k) { return k }
        guard let first = keys.first, let last = keys.last else { return k }
        return k < first ? first : last
    }

    /// Rows for `key` (all-day first, then by start).
    public func rows(on key: String, from rows: [MeetingItem]? = nil) -> [MeetingItem] {
        CalWeek.bucket(rows ?? meetings, keys: [key]).first ?? []
    }

    /// Move by one day / week / month (`n` steps).
    public func step(_ span: Span, by n: Int) {
        switch span {
        case .day:
            jump(to: calendar.date(byAdding: .day, value: n, to: focusDay) ?? focusDay, span: .day)
        case .week:
            jump(to: calendar.date(byAdding: .day, value: 7 * n, to: focusDay) ?? focusDay, span: .week)
        case .month:
            let first = calendar.date(from: calendar.dateComponents([.year, .month], from: focusDay)) ?? focusDay
            jump(to: calendar.date(byAdding: .month, value: n, to: first) ?? first, span: .month)
        }
    }

    /// Show `date` (Today, the date picker, a month-day click).
    public func jump(to date: Date, span: Span) {
        focusDay = calendar.startOfDay(for: date)
        if span == .month {
            showMonth(containing: focusDay)
        } else {
            showWeek(containing: focusDay)
        }
    }

    /// Week starts covering the month that contains `date`.
    func monthGrid(containing date: Date) -> (first: Date, gridStart: Date, weeks: [Date]) {
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        let gridStart = calendar.startOfDay(for: CalWeek.startOfWeek(containing: first, calendar: calendar))
        let next = calendar.date(byAdding: .month, value: 1, to: first) ?? first
        var weeks: [Date] = []
        var w = gridStart
        while w < next, weeks.count < 6 {
            weeks.append(w)
            w = calendar.date(byAdding: .day, value: 7, to: w) ?? next
        }
        return (first, gridStart, weeks)
    }

    /// Grid day keys of the month shown (`monthWeeks` × 7).
    public var monthDayKeys: [String] {
        (0 ..< monthWeeks * 7).map { dayKey(calendar.date(byAdding: .day, value: $0, to: monthGridStart) ?? monthGridStart) }
    }

    /// Show the month containing `date`: its weeks from cache at once,
    /// missing weeks fetched behind the month on screen (which stays
    /// until they all land). Neighbor months prefetch afterwards.
    public func showMonth(containing date: Date) {
        let grid = monthGrid(containing: date)
        monthGeneration &+= 1
        let generation = monthGeneration
        let keys = grid.weeks.map(key)
        let missing = keys.filter { k in
            guard let hit = weekCache[k] else { return true }
            return Date().timeIntervalSince(hit.at) > Self.weekFreshness && !monthLoaded
        }
        if missing.isEmpty {
            applyMonth(grid)
            prefetchNeighborMonths(of: grid.first)
            return
        }
        isLoadingMonth = true
        let fetcher = weekFetcher
        Task {
            let fetched = await Self.fetchWeeks(missing, fetcher: fetcher)
            for (k, resp) in fetched { weekCache[k] = (resp, Date()) }
            if !fetched.isEmpty { saveSnapshot() }
            guard generation == monthGeneration else { return }
            isLoadingMonth = false
            if fetched.count < missing.count, !monthLoaded {
                state = .error("Couldn't load this month")
            }
            applyMonth(grid)
            prefetchNeighborMonths(of: grid.first)
        }
    }

    private func applyMonth(_ grid: (first: Date, gridStart: Date, weeks: [Date])) {
        var seen = Set<String>()
        var rows: [MeetingItem] = []
        for w in grid.weeks {
            for m in weekCache[key(w)]?.response.meetings ?? [] where seen.insert(m.id).inserted {
                rows.append(m)
            }
        }
        monthStart = grid.first
        monthGridStart = grid.gridStart
        monthWeeks = grid.weeks.count
        monthMeetings = rows
        monthLoaded = true
        if case .error = state, !rows.isEmpty { state = .loaded }
    }

    private func prefetchNeighborMonths(of first: Date) {
        guard prefetchesAdjacentWeeks || localEdits else { return }
        for n in [-1, 1] {
            guard let d = calendar.date(byAdding: .month, value: n, to: first) else { continue }
            let keys = monthGrid(containing: d).weeks.map(key).filter { weekCache[$0] == nil }
            let fresh = keys.filter { prefetching.insert($0).inserted }
            guard !fresh.isEmpty else { continue }
            let fetcher = weekFetcher
            Task {
                let fetched = await Self.fetchWeeks(fresh, fetcher: fetcher)
                for k in fresh { prefetching.remove(k) }
                for (k, resp) in fetched where weekCache[k] == nil { weekCache[k] = (resp, Date()) }
                if !fetched.isEmpty { saveSnapshot() }
            }
        }
    }

    nonisolated static func fetchWeeks(_ keys: [Int64], fetcher: @escaping WeekFetcher) async -> [Int64: CalWeekResponse] {
        await withTaskGroup(of: (Int64, CalWeekResponse?).self) { group in
            for k in keys {
                group.addTask { (k, try? await Task.blocking { try fetcher(k) }.value) }
            }
            var out: [Int64: CalWeekResponse] = [:]
            for await (k, r) in group { if let r { out[k] = r } }
            return out
        }
    }

    // MARK: time zone

    func observeTimeZone() {
        timeZoneObserver = NotificationCenter.default
            .publisher(for: .NSSystemTimeZoneDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    NSTimeZone.resetSystemTimeZone()
                    self?.applyTimeZone(TimeZone.current)
                }
            }
    }

    /// Re-show everything in `tz`: rows re-derive their wall clock from
    /// their UTC instants at once (no blank), the day/week/month frames
    /// keep their calendar dates, and the shown range refetches behind.
    public func applyTimeZone(_ tz: TimeZone) {
        guard tz.identifier != calendar.timeZone.identifier else { return }
        let old = calendar
        func rebase(_ d: Date) -> Date {
            let p = old.dateComponents([.year, .month, .day], from: d)
            var c = calendar
            c.timeZone = tz
            return c.date(from: p) ?? d
        }
        let focus = rebase(focusDay), month = rebase(monthStart)
        calendar.timeZone = tz
        dayKeyFormatter.timeZone = tz
        meetings = meetings.map { CalendarTime.localize($0, to: tz) }
        monthMeetings = monthMeetings.map { CalendarTime.localize($0, to: tz) }
        details = details.mapValues { d in
            var d = d
            d.event = CalendarTime.localize(d.event, to: tz)
            return d
        }
        // Week keys are local midnights: every cached week moved.
        weekCache = [:]
        focusDay = focus
        monthStart = month
        monthGridStart = monthGrid(containing: month).gridStart
        let target = calendar.startOfDay(for: CalWeek.startOfWeek(containing: focus, calendar: calendar))
        weekStart = target
        pendingWeekStart = target
        Task { await fetch(target, behind: true) }
        if monthLoaded {
            monthLoaded = false
            showMonth(containing: month)
        }
    }

    // MARK: rows

    /// The row for `id` wherever it is shown.
    public func row(id: String) -> MeetingItem? {
        meetings.first { $0.id == id } ?? monthMeetings.first { $0.id == id } ?? details[id]?.event
            ?? seriesInstances.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    /// Apply `change` to every shown/cached copy of rows matching `match`
    /// (nil result removes the row).
    func mutateRows(_ match: (MeetingItem) -> Bool, _ change: (MeetingItem) -> MeetingItem?) {
        func apply(_ rows: [MeetingItem]) -> [MeetingItem] {
            rows.compactMap { match($0) ? change($0) : $0 }
        }
        meetings = apply(meetings)
        monthMeetings = apply(monthMeetings)
        for (k, w) in weekCache {
            weekCache[k] = (CalWeekResponse(ok: w.response.ok, weekStart: w.response.weekStart, days: w.response.days,
                                            meetings: apply(w.response.meetings)), w.at)
        }
        for (id, d) in details where match(d.event) {
            if let changed = change(d.event) {
                details[id]?.event = changed
            } else {
                details[id] = nil
            }
        }
        if state == .loaded, meetings.isEmpty { state = .empty }
    }

    // MARK: details

    /// Read `id`'s details once (body, attachments, fresh responses).
    public func loadDetail(id: String, force: Bool = false) {
        guard force || details[id] == nil, !detailLoading.contains(id) else { return }
        if localEdits {
            if let gate = demoGate, let row = row(id: id) ?? CalendarDemo.seriesMaster(id, from: meetings + monthMeetings) {
                details[id] = CalendarDemo.detail(gate, for: row)
            } else if let row = row(id: id) {
                details[id] = CalendarEventDetail(event: row)
            }
            return
        }
        detailLoading.insert(id)
        detailErrors[id] = nil
        let runner = runners.detail
        Task {
            let result: Result<CalendarEventDetail, Error>
            do {
                result = .success(try await Task.blocking { try runner(id) }.value)
            } catch {
                result = .failure(error)
            }
            detailLoading.remove(id)
            switch result {
            case .success(let d):
                details[id] = d
                // Fresh responses/fields flow back into the grid rows.
                mutateRows({ $0.id == id }, { _ in d.event })
            case .failure(let e):
                detailErrors[id] = Self.message(for: e)
            }
        }
    }

    /// False in demo: local data has no event beyond the loaded rows.
    public var canResolveEventsByID: Bool { !localEdits }

    /// Make the event `id` resolvable by `row(id:)` when a link names an
    /// event that is not in any loaded range: one read-only GET of the
    /// event by id (the same read the details sheet makes). True when the
    /// row is available afterwards; false when the read fails or in demo.
    /// Never writes.
    public func resolveEvent(id: String) async -> Bool {
        if row(id: id) != nil { return true }
        if localEdits { return false }
        let runner = runners.detail
        do {
            let d = try await Task.blocking { try runner(id) }.value
            details[id] = d
            return true
        } catch {
            return false
        }
    }

    // MARK: RSVP

    /// Accept / tentative / decline `row` (or its whole series). The
    /// rows update at once; a decline removes them (Outlook drops
    /// declined events from the calendar). A failure restores them.
    public func respond(to row: MeetingItem, _ action: RSVPAction, series: Bool = false) {
        guard respondingID == nil, !row.isOrganizer else { return }
        let master = row.info?.seriesMasterID
        let target = series ? (master ?? row.id) : row.id
        let match: (MeetingItem) -> Bool = series && master != nil
            ? { $0.info?.seriesMasterID == master || $0.id == row.id }
            : { $0.id == row.id }
        let saved = (meetings, monthMeetings, weekCache, details, state)
        mutateRows(match) { m in
            guard action != .decline else { return nil }
            var m = m
            m.info?.myResponse = action.response
            m.info?.showAs = action == .tentativelyAccept ? "tentative" : "busy"
            return m
        }
        rsvpError = nil
        if localEdits { return }
        respondingID = row.id
        let runner = runners.respond
        Task {
            do {
                try await Task.blocking { try runner(target, action) }.value
            } catch {
                (meetings, monthMeetings, weekCache, details, state) = saved
                rsvpError = Self.message(for: error)
            }
            respondingID = nil
        }
    }

    // MARK: edit

    /// Edit `row` (organizer). `series`: the change goes to the series
    /// master (title/location only; times stay per occurrence).
    @discardableResult
    public func update(_ row: MeetingItem, patch: CalendarEventPatch, series: Bool = false) async -> Bool {
        guard row.isOrganizer, !patch.isEmpty, !updating else { return false }
        if let s = patch.start, let e = patch.end, e <= s {
            updateError = "End must be after start"
            return false
        }
        if let s = patch.subject, s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateError = "Title is required"
            return false
        }
        let master = row.info?.seriesMasterID
        let seriesWide = series && master != nil
        var patch = patch
        if seriesWide { patch.start = nil; patch.end = nil }
        updateError = nil
        if localEdits {
            let p = patch
            mutateRows({ seriesWide ? $0.info?.seriesMasterID == master : $0.id == row.id }) { p.applied(to: $0) }
            return true
        }
        updating = true
        defer { updating = false }
        let runner = runners.update
        let target = seriesWide ? master! : row.id
        let sent = patch
        do {
            let updated = try await Task.blocking { try runner(target, sent) }.value
            if seriesWide {
                mutateRows({ $0.info?.seriesMasterID == master }) { sent.applied(to: $0) }
            } else {
                mutateRows({ $0.id == row.id }, { _ in updated })
            }
            return true
        } catch {
            updateError = Self.message(for: error)
            return false
        }
    }

    public func clearUpdateError() { updateError = nil }

    // MARK: Meet now

    /// Create an online meeting starting now (only the signed-in user
    /// invited). Returns the created row (with its join link), or nil
    /// with `meetNowError` set.
    public func meetNow(subject: String) async -> MeetingItem? {
        let name = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            meetNowError = "Meeting name is required"
            return nil
        }
        guard !meetingNow else { return nil }
        meetNowError = nil
        let created: MeetingItem
        if localEdits {
            meetNowCount += 1
            let now = Date()
            let id = (demoGate != nil ? "demo-cal-now-" : "local-now-") + "\(meetNowCount)"
            created = MeetingItem(
                meetingId: id, subject: name,
                start: CalendarTime.wallClock(now, in: calendar.timeZone),
                end: CalendarTime.wallClock(now.addingTimeInterval(3600), in: calendar.timeZone),
                joinURL: "https://teams.microsoft.com/l/meetup-join/19:meeting_\(id)@thread.v2/0",
                organizer: demoGate != nil ? CalendarDemo.owner : nil,
                organizerEmail: demoGate != nil ? CalendarDemo.ownerEmail : nil,
                isOrganizer: true, isOnline: true,
                info: CalendarEventInfo(myResponse: .organizer, showAs: "busy"))
        } else {
            meetingNow = true
            defer { meetingNow = false }
            let runner = runners.meetNow
            do {
                created = try await Task.blocking { try runner(name) }.value
            } catch {
                meetNowError = Self.message(for: error)
                return nil
            }
        }
        insert(created)
        return created
    }

    public func clearMeetNowError() { meetNowError = nil }

    /// Add a created row to the week/month shown and the week cache.
    func insert(_ row: MeetingItem) {
        guard let k = CalWeek.dayKey(of: row), let day = date(forKey: k) else { return }
        let wk = key(calendar.startOfDay(for: CalWeek.startOfWeek(containing: day, calendar: calendar)))
        if wk == key(weekStart) {
            meetings.append(row)
            if state == .empty { state = .loaded }
        }
        if let w = weekCache[wk] {
            weekCache[wk] = (CalWeekResponse(ok: true, weekStart: wk, days: 7, meetings: w.response.meetings + [row]), w.at)
        }
        if monthLoaded, monthDayKeys.contains(k) { monthMeetings.append(row) }
    }
}
