// PresenceSchedule.swift — e2-attention lane: presence schedules.
//
// Own Teams status set automatically on a timetable (Busy 9–5, Offline
// nights). Entries reuse `QuietHoursWindow` (same overnight/weekday
// semantics); the applier fires on window TRANSITIONS only (never
// per-tick network) plus a 50-minute refresh (the server grant expires
// after PT1H — `set_presence_json` fixes "expirationDuration": "PT1H"
// with no duration parameter, so long windows re-set from Swift; no
// Rust changes. App-asleep ⇒ presence lapses to Teams-computed —
// acceptable, documented, NOT a wake-the-machine lane).
//
// Manual contract (i): a manual picker set pauses the schedule until
// the next window boundary (the app wires PresenceStore.manualSetHook
// to noteManualSet; scheduled sets bypass PresenceStore.set so they
// never self-pause — they use the injected set-fetcher directly and
// adopt the echo into PresenceStore.own).
//
// Failure (ost non-critical rule): a failed scheduled set records
// `error`, retries at most once per window (no retry storm), never
// clears the last good `own`, never touches peers. Failure budgets
// reset on window change. Applied state is session-only; sign-out
// clears it via clearApplied() (next to PresenceStore.clear()).
import Foundation

/// One schedule entry: a quiet-style window + the status to hold while
/// it is active. First list match wins on overlap.
public struct PresenceScheduleEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var window: QuietHoursWindow
    public var status: PresenceStatus

    public init(
        id: UUID = UUID(),
        window: QuietHoursWindow = QuietHoursWindow(),
        status: PresenceStatus = .busy
    ) {
        self.id = id
        self.window = window
        self.status = status
    }

    /// "Busy · 09:00–17:00 · weekdays" (Diagnostics/Settings row).
    public func summary(calendar: Calendar = .current) -> String {
        "\(status.title) · \(window.summary(calendar: calendar))"
    }
}

/// Presence-schedule state + applier. Ticked from the app's 2s tick
/// (idle = no-op, no publishes); fetches run off-main (blocking FFI).
@MainActor
public final class PresenceScheduleStore: ObservableObject {
    public nonisolated static let enabledKey = "presenceSchedule.enabled"
    public nonisolated static let entriesKey = "presenceSchedule.entries"
    /// Cap (CallHistoryStore precedent: bounded persisted lists).
    public nonisolated static let maxEntries = 8
    /// Re-set cadence inside a window (server grant lapses at PT1H).
    public static let refreshInterval: TimeInterval = 50 * 60
    /// Attempts per window before the window holds (1 + 1 retry).
    public static let maxAttemptsPerWindow = 2

    private let defaults: UserDefaults
    private let setFetcher: PresenceStore.SetFetcher
    /// Echo adoption target (own dot); nil in unit tests.
    private weak var presence: PresenceStore?
    /// Failed attempts by entry id (budgets reset on window change).
    private var failures: [UUID: Int] = [:]
    /// Manual-pause arm: schedule holds while the active entry equals
    /// this id (contract (i) — cleared at the next boundary).
    private var pausedEntryID: UUID?
    /// Set in flight (synchronous guard: ticks never stack network).
    private var inflight = false

    @Published public var enabled = false {
        didSet { defaults.set(enabled, forKey: Self.enabledKey) }
    }
    @Published public var entries: [PresenceScheduleEntry] = [] {
        didSet { persistEntries() }
    }
    /// Entry whose status was last applied (session-only).
    @Published public private(set) var appliedEntryID: UUID?
    /// Last successful scheduled set (session-only; drives refresh).
    @Published public private(set) var lastSetAt: Date?
    /// Last applied target status (session-only; Diagnostics row).
    @Published public private(set) var lastStatus: PresenceStatus?
    /// Last scheduled-set failure (cleared on next success / sign-out).
    @Published public private(set) var error: String?
    /// Ghost-mode gate (f1-ghost): when set and suppressing presence,
    /// the applier holds the write (counted) without arming applied
    /// state — the transition re-fires on lift. Nil = live.
    public var ghost: GhostStore?
    /// Truth-lock gate (top10-presence): when set and true, the applier
    /// holds the write like ghost (no applied arming, no budget spend —
    /// the CURRENT window fires when the lock lifts). Nil = live.
    public var externalHold: (() -> Bool)?
    /// Fire hook (top10-presence): invoked after each successful
    /// scheduled set (the truth log's schedule entries + undo offers).
    /// Failures send nothing (the error row covers them).
    public var onApplied: ((PresenceStatus) -> Void)?

    /// Main-actor init (Swift 6): View inits are main-actor, so views
    /// can still take a default; the stored state is main-actor-isolated.
    public init(
        defaults: UserDefaults = .standard,
        setFetcher: @escaping PresenceStore.SetFetcher = { try RustCore.setPresence(status: $0) },
        presence: PresenceStore? = nil
    ) {
        self.defaults = defaults
        self.setFetcher = setFetcher
        self.presence = presence
        let enabled = defaults.object(forKey: Self.enabledKey) != nil
            ? defaults.bool(forKey: Self.enabledKey)
            : false
        var entries: [PresenceScheduleEntry] = []
        if let data = defaults.data(forKey: Self.entriesKey),
           let decoded = try? JSONDecoder().decode([PresenceScheduleEntry].self, from: data)
        {
            entries = Array(decoded.prefix(Self.maxEntries))
        }
        _enabled = Published(initialValue: enabled)
        _entries = Published(initialValue: entries)
        _appliedEntryID = Published(initialValue: nil)
        _lastSetAt = Published(initialValue: nil)
        _lastStatus = Published(initialValue: nil)
        _error = Published(initialValue: nil)
    }

    /// First enabled entry whose window contains `date` (list order).
    public func activeEntry(at date: Date = Date(), calendar: Calendar = .current) -> PresenceScheduleEntry? {
        entries.first { $0.window.contains(date, calendar: calendar) }
    }

    /// Tick the applier (app 2s tick; idle = no-op, no publishes).
    /// Fires at most one set per call: window transitions, refresh-due,
    /// or a budgeted retry — manual-paused and failed-out windows hold.
    public func tick(now: Date = Date(), calendar: Calendar = .current) {
        guard enabled, !inflight else { return }
        guard let active = activeEntry(at: now, calendar: calendar) else {
            // No window: clear applied + pause state (re-entry below is
            // a fresh transition; a manual pause ends at this boundary).
            if appliedEntryID != nil { appliedEntryID = nil }
            if pausedEntryID != nil { pausedEntryID = nil }
            return
        }
        // Boundary crossed (or pause never armed): resume.
        if pausedEntryID != nil, pausedEntryID != active.id { pausedEntryID = nil }
        // Contract (i): manual set holds until the next boundary.
        if pausedEntryID == active.id { return }
        if active.id == appliedEntryID {
            // Same window: re-set only past the refresh line.
            if let last = lastSetAt, now.timeIntervalSince(last) < Self.refreshInterval { return }
        }
        // Failure budget: initial + one retry per window, then hold.
        if (failures[active.id] ?? 0) >= Self.maxAttemptsPerWindow { return }
        // Ghost (f1-ghost): the applier still runs to this point, then
        // holds the write (counted) — no applied arming, no budget
        // spend, so the CURRENT window fires on lift (no stale replay).
        if let ghost, ghost.shouldSuppressPresence {
            ghost.noteHeldPresence()
            return
        }
        // Truth lock (top10-presence): same hold shape as ghost (the
        // CURRENT window fires on lift — no stale replay, no spend).
        if externalHold?() == true { return }
        fire(entry: active, now: now)
    }

    /// Note a manual picker set (via PresenceStore.manualSetHook).
    /// Arms the pause only when a window is active (nothing to fight
    /// otherwise — future transitions proceed).
    public func noteManualSet(now: Date = Date(), calendar: Calendar = .current) {
        if let active = activeEntry(at: now, calendar: calendar) {
            pausedEntryID = active.id
        }
    }

    /// Drop session state after sign-out (fail closed; the schedule
    /// resumes clean on the next tick). Entries + toggle persist.
    public func clearApplied() {
        appliedEntryID = nil
        lastSetAt = nil
        lastStatus = nil
        error = nil
        pausedEntryID = nil
        failures = [:]
    }

    /// Add an entry (false at the cap — caller shows refusal text).
    @discardableResult
    public func addEntry(_ entry: PresenceScheduleEntry) -> Bool {
        guard entries.count < Self.maxEntries else { return false }
        entries.append(entry)
        return true
    }

    /// Remove an entry by id (no-op when unknown).
    public func removeEntry(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    /// Fire one scheduled set (off-main fetch, echo adopted on main).
    /// Attempt bookkeeping lands synchronously (tests + tick-bursts
    /// never double-fire); the result completes async.
    private func fire(entry: PresenceScheduleEntry, now: Date) {
        inflight = true
        appliedEntryID = entry.id
        let fetcher = setFetcher
        let want = entry.status.rawValue
        Task {
            defer { inflight = false }
            do {
                let resp = try await Task.blocking { try fetcher(want) }.value
                failures[entry.id] = 0
                lastSetAt = now
                lastStatus = entry.status
                error = nil
                presence?.adoptOwn(resp)
                onApplied?(entry.status)
            } catch {
                failures[entry.id, default: 0] += 1
                self.error = String(describing: error)
            }
        }
    }

    private func persistEntries() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.entriesKey)
        }
    }
}
