// PresenceTruth.swift — top10-presence lane: truthful presence.
//
// MS Teams Q&A is flooded (100+ dupes) with two complaints: random flips
// to Away, and DND melting into Away. Teams' side: the server aggregates
// presence across every device/session with opaque precedence and
// recomputes on its own schedule. This lane makes our Mac client
// truthful about its slice:
//
// 1. Local activity truth — idle/locked/asleep read from the OS
//    (CGEventSource + lock/sleep notes), never guessed.
// 2. Manual status lock — pin a status for 15m/1h/4h/until-off. While
//    locked, idle auto-away AND schedule windows hold, and server drift
//    is reasserted (DND 1h survives idle + calendar).
// 3. Precedence shown — the per-device precedence rules + live device
//    rows (this Mac vs Teams server aggregate) in Diagnostics.
// 4. No silent flips — every automatic change is logged (Diagnostics)
//    with an undo toast; manual sets are never mislabeled as server moves.
//
// Failure (ost non-critical rule): a failed auto-set records `error`,
// keeps the last good `own`, and leans on the reassert cooldown (no
// retry storm). Ghost holds count in the ghost store, never here.
import CoreGraphics
import Foundation
import Combine

// MARK: - Lock duration

/// Manual-lock auto-expiry options (DNDDuration precedent — same shape,
/// presence-flavored cases per the lane demand).
public enum PresenceLockDuration: String, CaseIterable, Sendable {
    case fifteenMinutes
    case oneHour
    case fourHours
    case untilOff

    /// Picker label.
    public var label: String {
        switch self {
        case .fifteenMinutes: "15 minutes"
        case .oneHour: "1 hour"
        case .fourHours: "4 hours"
        case .untilOff: "Until turned off"
        }
    }

    /// Expiry instant for `now` (nil = indefinite).
    public func expiryDate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .fifteenMinutes: calendar.date(byAdding: .minute, value: 15, to: now)
        case .oneHour: calendar.date(byAdding: .hour, value: 1, to: now)
        case .fourHours: calendar.date(byAdding: .hour, value: 4, to: now)
        case .untilOff: nil
        }
    }
}

/// A pinned own-status: while active, idle auto-away and schedule
/// windows hold and server drift is reasserted.
public struct PresenceLock: Equatable, Sendable {
    public var status: PresenceStatus
    public var until: Date?
    public var setAt: Date

    public init(status: PresenceStatus, until: Date?, setAt: Date) {
        self.status = status
        self.until = until
        self.setAt = setAt
    }

    public func isActive(now: Date = Date()) -> Bool {
        guard let until else { return true }
        return now < until
    }

    /// "Do not disturb · 42m left" / "… · 2h 05m left" / "… · until off".
    public func summary(now: Date = Date()) -> String {
        guard let until else { return "\(status.title) · until off" }
        let mins = Int(ceil(until.timeIntervalSince(now) / 60))
        if mins <= 0 { return "\(status.title) · expired" }
        if mins < 90 { return "\(status.title) · \(mins)m left" }
        return "\(status.title) · \(mins / 60)h \(String(format: "%02d", mins % 60))m left"
    }
}

// MARK: - Local activity truth

/// This Mac's ground truth: input-idle, locked, or asleep. Locked and
/// asleep are idle-like (Teams-computed Away is legitimate there) but
/// shown distinctly so "Away while locked" never looks random.
public struct LocalActivity: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case active, idle, locked, asleep
    }

    public var kind: Kind
    public var idleSeconds: TimeInterval

    public init(kind: Kind, idleSeconds: TimeInterval) {
        self.kind = kind
        self.idleSeconds = idleSeconds
    }

    public var isIdleLike: Bool { kind != .active }

    /// "active" / "idle 6m" / "locked" / "asleep" (Diagnostics activity row).
    public var summary: String {
        switch kind {
        case .active: "active"
        case .idle: "idle \(PresenceActivity.idleSpan(idleSeconds))"
        case .locked: "locked"
        case .asleep: "asleep"
        }
    }
}

/// Pure activity classification + the OS idle probe.
public enum PresenceActivity {
    /// Teams parity: the official client flips to Away after 5 idle
    /// minutes. Our auto-Away matches that line exactly.
    public static let defaultThreshold: TimeInterval = 300

    public static func classify(
        idleSeconds: TimeInterval,
        threshold: TimeInterval = defaultThreshold,
        locked: Bool = false,
        asleep: Bool = false
    ) -> LocalActivity {
        if asleep { return LocalActivity(kind: .asleep, idleSeconds: idleSeconds) }
        if locked { return LocalActivity(kind: .locked, idleSeconds: idleSeconds) }
        if idleSeconds >= threshold {
            return LocalActivity(kind: .idle, idleSeconds: idleSeconds)
        }
        return LocalActivity(kind: .active, idleSeconds: idleSeconds)
    }

    /// "45s" / "6m" / "2h 05m" (idle arm of the activity summary).
    public static func idleSpan(_ secs: TimeInterval) -> String {
        if secs < 60 { return "\(Int(max(0, secs)))s" }
        let m = Int(secs / 60)
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(String(format: "%02d", m % 60))m"
    }

    /// OS idle seconds (keyboard+mouse, combined session — the same
    /// counter Screen Saver / Energy Saver use). Fail-open: a broken
    /// probe reads 0 (active) — never auto-Aways on unknown.
    public static func systemIdleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~UInt32(0)) else { return 0 } // kCGAnyInputEventType
        let secs = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard secs.isFinite, secs >= 0, secs < 1e9 else { return 0 }
        return secs
    }
}

// MARK: - Change log (no silent flips)

/// What moved your status. Auto causes are the no-silent-flips set:
/// each one lands in Diagnostics with an undo offer when reversible.
public enum PresenceChangeCause: String, Sendable {
    case manual
    case lock
    case unlock
    case lockExpired
    case schedule
    case idle
    case active
    case server
    case reaffirm
    case undo

    /// Diagnostics label.
    public var label: String {
        switch self {
        case .manual: "You"
        case .lock: "Lock on"
        case .unlock: "Lock off"
        case .lockExpired: "Lock expired"
        case .schedule: "Schedule"
        case .idle: "Idle"
        case .active: "Back"
        case .server: "Teams server"
        case .reaffirm: "Lock held"
        case .undo: "Undo"
        }
    }

    public var isAuto: Bool {
        switch self {
        case .schedule, .idle, .active, .server, .reaffirm, .lockExpired: true
        case .manual, .lock, .unlock, .undo: false
        }
    }
}

/// One status move, newest-first in `PresenceTruthStore.entries`.
public struct PresenceChangeEntry: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var at: Date
    /// Server availability before the move ("" when unknown).
    public var fromAvailability: String
    public var toAvailability: String
    public var cause: PresenceChangeCause
    /// Free detail ("idle 6m", "server showed Away").
    public var note: String
    /// Set this to undo (nil = not reversible from here).
    public var undoStatus: PresenceStatus?

    public init(
        id: UUID = UUID(),
        at: Date,
        fromAvailability: String,
        toAvailability: String,
        cause: PresenceChangeCause,
        note: String = "",
        undoStatus: PresenceStatus? = nil
    ) {
        self.id = id
        self.at = at
        self.fromAvailability = fromAvailability
        self.toAvailability = toAvailability
        self.cause = cause
        self.note = note
        self.undoStatus = undoStatus
    }

    /// "14:02 Available → Away · Idle (idle 6m)" (Diagnostics recent row).
    public func summary(calendar: Calendar = .current) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "HH:mm"
        let from = fromAvailability.isEmpty ? "?" : fromAvailability
        var s = "\(fmt.string(from: at)) \(from) → \(toAvailability) · \(cause.label)"
        if !note.isEmpty { s += " (\(note))" }
        return s
    }
}

/// Toast model: one reversible auto-change, tap Undo within the window.
public struct PresenceUndoOffer: Equatable, Sendable {
    public var status: PresenceStatus
    public var text: String
    public var expiresAt: Date

    public init(status: PresenceStatus, text: String, expiresAt: Date) {
        self.status = status
        self.text = text
        self.expiresAt = expiresAt
    }

    public func isExpired(now: Date = Date()) -> Bool { now >= expiresAt }

    /// Menu item title for the Undo entry (account/Dock/status-bar menus).
    public var undoMenuTitle: String { "Undo — Back to \(status.title)" }
}

// MARK: - Devices + precedence

public enum PresenceDeviceKind: String, Sendable {
    case thisMac, server, other
}

/// One presence source. This Mac (local truth) and the Teams server
/// (aggregate echo) are always present; extras are adopted (tests,
/// previews, future core sessions) — never invented.
public struct PresenceDevice: Identifiable, Equatable, Sendable {
    public static let thisMacID = "this-mac"
    public static let serverID = "teams-server"

    public var id: String
    public var name: String
    public var kind: PresenceDeviceKind
    public var availability: String
    public var activity: String
    public var detail: String
    public var lastSeen: Date?

    public init(
        id: String, name: String, kind: PresenceDeviceKind,
        availability: String, activity: String = "",
        detail: String = "", lastSeen: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.availability = availability
        self.activity = activity
        self.detail = detail
        self.lastSeen = lastSeen
    }
}

/// Per-device precedence: which device wins when they disagree, and why.
/// Shown verbatim in Diagnostics (PresenceDevicesView) — the rules are
/// the feature, not just the winner.
public enum PresencePrecedence {
    /// Rank: higher wins. DND suppresses everything; a call/meeting
    /// beats idle; Away beats Available (idle truth over stale green);
    /// anything beats Offline/unknown.
    public static func rank(availability: String, activity: String = "") -> Int {
        if availability == "DoNotDisturb" { return 4 }
        if availability == "Busy" || isCallActivity(activity) { return 3 }
        if availability == "Away" || availability == "BeRightBack" { return 2 }
        if availability == "Available" { return 1 }
        return 0 // Offline, PresenceUnknown, future values
    }

    /// Call/meeting activities outrank their availability row.
    public static func isCallActivity(_ activity: String) -> Bool {
        ["InACall", "InAMeeting", "InAConferenceCall", "Presenting"].contains(activity)
    }

    /// Winner + why. Ties → most recently seen; final tie → this Mac.
    public static func effective(devices: [PresenceDevice]) -> (device: PresenceDevice, why: String)? {
        guard var best = devices.first else { return nil }
        for d in devices.dropFirst() {
            let rb = rank(availability: best.availability, activity: best.activity)
            let rd = rank(availability: d.availability, activity: d.activity)
            if rd > rb {
                best = d
            } else if rd == rb {
                switch (best.lastSeen, d.lastSeen) {
                case let (b?, s?) where s > b: best = d
                case (nil, .some): best = d
                case (nil, nil) where d.kind == .thisMac: best = d
                default: break
                }
            }
        }
        return (best, why(device: best))
    }

    /// Winner explanation (the "why" in the precedence view).
    public static func why(device: PresenceDevice) -> String {
        switch rank(availability: device.availability, activity: device.activity) {
        case 4: "Do not disturb overrides every other device"
        case 3 where isCallActivity(device.activity):
            "In a call or meeting beats idle and available"
        case 3: "Busy beats Away and Available"
        case 2: "Away wins over Available (idle truth over stale green)"
        case 1: "Available — no device is busier"
        default: "Offline — nothing else is reporting"
        }
    }

    /// The rule table, most-wins-first (precedence view source).
    public static let rules: [(title: String, why: String)] = [
        ("Do not disturb", "overrides every other device"),
        ("Busy / in a call", "beats Away and Available"),
        ("Away", "wins over Available (idle truth over stale green)"),
        ("Available", "shows only when no device is busier"),
        ("Offline", "loses to everything reporting"),
    ]
}

// MARK: - Truth store

/// Lock + activity truth + change log + devices. Ticked from the app's
/// 2s tick (idle = no-op, no publishes); fetches run off-main.
///
/// Ordering inside tick: sweep undo/lock expiry → reconcile the server
/// echo (drift becomes a logged entry, never a silent flip) → refresh
/// device rows → at most one auto-set (lock reassert wins over idle
/// logic; idle logic holds while a schedule window is active).
@MainActor
public final class PresenceTruthStore: ObservableObject {
    public nonisolated static let lockStatusKey = "presenceTruth.lockStatus"
    public nonisolated static let lockUntilKey = "presenceTruth.lockUntil"
    public nonisolated static let lockSetAtKey = "presenceTruth.lockSetAt"
    public nonisolated static let autoAwayKey = "presenceTruth.autoAway"
    public nonisolated static let restoreKey = "presenceTruth.restoreOnActivity"
    public nonisolated static let resetAfterKey = "presenceTruth.resetAfter"
    /// Cap (CallHistoryStore precedent: bounded session lists).
    public nonisolated static let maxEntries = 30
    /// Undo-toast lifetime.
    public static let undoWindow: TimeInterval = 12
    /// Min gap between lock reasserts (drift flaps never storm).
    public static let reassertCooldown: TimeInterval = 60
    /// Manual-set echo grace: an echo inside this window after a picker
    /// set is the user's own move, never a server flip.
    public static let manualGrace: TimeInterval = 15

    private let defaults: UserDefaults
    private let setFetcher: PresenceStore.SetFetcher
    /// Echo source + adoption target (own dot); nil in unit tests.
    private weak var presence: PresenceStore?
    /// This Mac's last reconciled echo (drift detector baseline).
    private var lastSeen: (avail: String, act: String)?
    /// When the echo last changed value (server-row freshness).
    private var lastEchoChangeAt: Date?
    /// Availability we set and haven't seen echoed yet (our echo, not
    /// the server's — consumed silently on arrival).
    private var pendingEcho: String?
    /// Last picker set (via the chained manualSetHook).
    private var manualNotedAt: Date?
    /// We auto-set Away for idle and may restore on activity. Any manual
    /// / schedule / undo move disarms (we never fight the user).
    private var idleArmed = false
    /// Set in flight (synchronous guard: ticks never stack network).
    private var inflight = false
    /// Last auto-set tick (reassert cooldown + PT1H refresh).
    private var lastAutoSetAt: Date?
    /// Adopted extra device rows (tests, previews, future core).
    private var adoptedDevices: [PresenceDevice] = []
    /// Lock/sleep flags (AppState observers; tests set directly).
    private var isLockedScreen = false
    private var isAsleep = false
    /// When the activity summary last changed (this-Mac-row freshness).
    private var lastActivityChangeAt: Date?

    /// OS idle probe (tests inject constants).
    public var idleProvider: () -> TimeInterval = { PresenceActivity.systemIdleSeconds() }
    /// Idle seconds before auto-Away (Teams parity default).
    public var threshold: TimeInterval = PresenceActivity.defaultThreshold
    /// Live core writes (AppState sets each tick: signed-in live only).
    /// False still sweeps, reconciles, and refreshes rows — demo-safe.
    public var liveWrites = true
    /// Schedule-window gate (AppState wires `{ schedule.activeEntry() !=
    /// nil }`): idle auto-away AND restore hold while a window owns the
    /// status. The lock ignores this (lock wins over calendar).
    public var scheduleActive: (() -> Bool)?
    /// Ghost-mode gate (f1-ghost): auto-sets hold (counted) like the
    /// schedule's. Nil = live.
    public var ghost: GhostStore?

    @Published public var autoAway = true {
        didSet { defaults.set(autoAway, forKey: Self.autoAwayKey) }
    }
    @Published public var restoreOnActivity = true {
        didSet { defaults.set(restoreOnActivity, forKey: Self.restoreKey) }
    }
    /// Status duration for picker choices ("reset after"): untilOff sets
    /// the status plainly; anything else pins it as a timed lock.
    @Published public var resetAfter: PresenceLockDuration = .untilOff {
        didSet { defaults.set(resetAfter.rawValue, forKey: Self.resetAfterKey) }
    }
    @Published public private(set) var lock: PresenceLock?
    /// Newest-first (capped).
    @Published public private(set) var entries: [PresenceChangeEntry] = []
    @Published public private(set) var undoOffer: PresenceUndoOffer?
    /// This Mac + Teams server + adopted (precedence view source).
    @Published public private(set) var devices: [PresenceDevice] = []
    /// LocalActivity.summary, assign-on-change (ticks don't publish).
    @Published public private(set) var activitySummary = "active"
    /// Last auto-set failure (cleared on next success / sign-out).
    @Published public private(set) var error: String?

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
        let autoAway = defaults.object(forKey: Self.autoAwayKey) != nil
            ? defaults.bool(forKey: Self.autoAwayKey)
            : true
        let restore = defaults.object(forKey: Self.restoreKey) != nil
            ? defaults.bool(forKey: Self.restoreKey)
            : true
        var lock: PresenceLock?
        if let raw = defaults.string(forKey: Self.lockStatusKey),
           let status = PresenceStatus(rawValue: raw)
        {
            let until = defaults.object(forKey: Self.lockUntilKey) != nil
                ? Date(timeIntervalSince1970: defaults.double(forKey: Self.lockUntilKey))
                : nil
            let setAt = defaults.object(forKey: Self.lockSetAtKey) != nil
                ? Date(timeIntervalSince1970: defaults.double(forKey: Self.lockSetAtKey))
                : Date()
            let candidate = PresenceLock(status: status, until: until, setAt: setAt)
            // Launch sweep: a lock that expired while away starts off.
            if candidate.isActive() { lock = candidate }
        }
        _autoAway = Published(initialValue: autoAway)
        _restoreOnActivity = Published(initialValue: restore)
        _lock = Published(initialValue: lock)
        _resetAfter = Published(
            initialValue: defaults.string(forKey: Self.resetAfterKey)
                .flatMap(PresenceLockDuration.init(rawValue:)) ?? .untilOff)
        _entries = Published(initialValue: [])
        _undoOffer = Published(initialValue: nil)
        _devices = Published(initialValue: [])
        _activitySummary = Published(initialValue: "active")
        _error = Published(initialValue: nil)
        if lock == nil {
            defaults.removeObject(forKey: Self.lockStatusKey)
            defaults.removeObject(forKey: Self.lockUntilKey)
            defaults.removeObject(forKey: Self.lockSetAtKey)
        }
    }

    /// Current local truth (probe + lock/sleep flags).
    public func activity() -> LocalActivity {
        PresenceActivity.classify(
            idleSeconds: idleProvider(), threshold: threshold,
            locked: isLockedScreen, asleep: isAsleep)
    }

    public func isLocked(now: Date = Date()) -> Bool {
        lock?.isActive(now: now) ?? false
    }

    /// Auto-cause count (Diagnostics auto row).
    public var autoCount: Int { entries.filter(\.cause.isAuto).count }

    /// Precedence winner across the current rows (nil before first tick).
    public var effectiveDevice: (device: PresenceDevice, why: String)? {
        PresencePrecedence.effective(devices: devices)
    }

    /// This Mac's published row disagrees with the server echo (and the
    /// echo is known) — the drift the lock reasserts against.
    public var drifted: Bool {
        guard
            let mac = devices.first(where: { $0.id == PresenceDevice.thisMacID }),
            let srv = devices.first(where: { $0.id == PresenceDevice.serverID }),
            presence?.own != nil
        else { return false }
        return mac.availability != srv.availability
    }

    // MARK: Lock

    /// Pin a status now (picker action). Persists, logs, and establishes
    /// the status immediately (held under ghost — the lock still records,
    /// the write goes out on lift). Clears any undo offer (the lock is
    /// the user's will — nothing to undo back to).
    public func lock(status: PresenceStatus, duration: PresenceLockDuration, now: Date = Date()) {
        let until = duration.expiryDate(now: now)
        lock = PresenceLock(status: status, until: until, setAt: now)
        persistLock()
        undoOffer = nil
        appendLog(
            from: presence?.own?.availability ?? lastSeen?.avail ?? "",
            to: status.availability, cause: .lock,
            note: until == nil ? "until off" : duration.label, undo: nil, now: now)
        fire(status: status, cause: .lock, note: "", undo: nil, now: now)
    }

    /// Picker choice honoring the status duration: a timed duration pins
    /// the status as a lock for that long; "until off" is a plain manual
    /// set (any lock is released first, or the drift check would put the
    /// old status back).
    public func choose(status: PresenceStatus, now: Date = Date()) {
        if resetAfter == .untilOff {
            unlock(now: now)
            presence?.set(status: status)
        } else {
            lock(status: status, duration: resetAfter, now: now)
        }
    }

    /// Release the lock (manual). Logs; sends nothing — the server and
    /// schedule take over from the current status.
    public func unlock(now: Date = Date()) {
        guard lock != nil else { return }
        let from = lock?.status.availability ?? ""
        lock = nil
        persistLock()
        appendLog(
            from: from, to: presence?.own?.availability ?? lastSeen?.avail ?? "",
            cause: .unlock, note: "", undo: nil, now: now)
    }

    // MARK: Hooks (wired by AppState)

    /// Note a manual picker set (chained into
    /// PresenceStore.manualSetHook next to the schedule's). Disarms idle
    /// restore — the user owns the status now.
    public func noteManualSet(now: Date = Date()) {
        manualNotedAt = now
        idleArmed = false
    }

    /// Note a successful scheduled set (PresenceScheduleStore.onApplied).
    /// Logs the auto-change with an undo offer; arms the echo so the
    /// schedule's own echo is consumed, never mislabeled as server.
    public func noteScheduledSet(_ status: PresenceStatus, now: Date = Date()) {
        idleArmed = false // the schedule owns the status now
        pendingEcho = status.availability
        lastAutoSetAt = now
        let from = lastSeen?.avail ?? presence?.own?.availability ?? ""
        let undo = PresenceStatus.from(availability: from)
        appendLog(from: from, to: status.availability, cause: .schedule, note: "", undo: undo, now: now)
        if let undo {
            undoOffer = PresenceUndoOffer(
                status: undo, text: "Schedule set \(status.title) — back to \(undo.title)?",
                expiresAt: now.addingTimeInterval(Self.undoWindow))
        }
    }

    public func noteScreenLock() { isLockedScreen = true }
    public func noteScreenUnlock() { isLockedScreen = false }
    public func noteSleep() { isAsleep = true }
    public func noteWake() { isAsleep = false }

    // MARK: Tick

    /// Sweep + reconcile + at most one auto-set (app 2s tick; idle =
    /// no-op, no publishes). `live` gates core writes only.
    public func tick(now: Date = Date()) {
        // Undo expiry sweep.
        if let offer = undoOffer, offer.isExpired(now: now) { undoOffer = nil }
        // Lock expiry sweep (logs; sends nothing).
        if let locked = lock, !locked.isActive(now: now) {
            lock = nil
            persistLock()
            appendLog(
                from: locked.status.availability,
                to: presence?.own?.availability ?? lastSeen?.avail ?? "",
                cause: .lockExpired, note: "", undo: nil, now: now)
        }
        // Activity row (assign-on-change; first tick stamps sight).
        let summary = activity().summary
        if summary != activitySummary {
            activitySummary = summary
            lastActivityChangeAt = now
        }
        if lastActivityChangeAt == nil { lastActivityChangeAt = now }
        reconcileEcho(now: now)
        updateDevices()
        guard liveWrites else { return }
        // A move we didn't make disarms idle restore (silent: manual
        // moves are the user's, not flips to report). Skipped while our
        // own echo is still in flight (the arm outlives the set).
        if idleArmed, pendingEcho == nil, presence?.own?.availability != "Away" {
            idleArmed = false
        }
        if isLocked(now: now) {
            tickLocked(now: now)
            return
        }
        tickIdle(now: now)
    }

    /// Locked tick: reassert on server drift (cooldown-guarded) or PT1H
    /// grant refresh. Never idle-aways, never yields to the schedule.
    private func tickLocked(now: Date) {
        guard let locked = lock, !inflight else { return }
        let echo = presence?.own?.availability
        let drifted = echo != locked.status.availability
        let refreshDue = lastAutoSetAt == nil
            || now.timeIntervalSince(lastAutoSetAt!) >= PresenceScheduleStore.refreshInterval
        let cooled = lastAutoSetAt == nil
            || now.timeIntervalSince(lastAutoSetAt!) >= Self.reassertCooldown
        if drifted, cooled {
            fire(
                status: locked.status, cause: .reaffirm,
                note: echo == nil ? "no echo yet" : "server showed \(echo!)",
                undo: nil, now: now)
        } else if refreshDue {
            fire(status: locked.status, cause: .reaffirm, note: "grant renewed", undo: nil, now: now)
        }
    }

    /// Unlocked tick: Teams-parity idle auto-Away + restore on activity.
    /// Holds while a schedule window owns the status (the schedule's
    /// target is intent, not drift).
    private func tickIdle(now: Date) {
        guard !inflight, scheduleActive?() != true else { return }
        let idle = activity().isIdleLike
        let echo = presence?.own?.availability
        if idle, autoAway, echo == PresenceStatus.available.availability {
            fire(
                status: .away, cause: .idle, note: activitySummary,
                undo: .available, now: now)
            idleArmed = true
        } else if !idle, restoreOnActivity, idleArmed, echo == PresenceStatus.away.availability {
            fire(
                status: .available, cause: .active, note: "input back",
                undo: .away, now: now)
            idleArmed = false
        }
    }

    /// Undo the offered auto-change (toast action). Refused while locked
    /// (the lock is the user's will) and when ghost holds writes (the
    /// offer stays — nothing happened, retry after lift).
    public func undoLastAutoChange(now: Date = Date()) {
        guard let offer = undoOffer, !offer.isExpired(now: now) else {
            undoOffer = nil
            return
        }
        guard !isLocked(now: now) else {
            undoOffer = nil
            return
        }
        guard liveWrites, !inflight else { return }
        if let ghost, ghost.shouldSuppressPresence {
            ghost.noteHeldPresence()
            return
        }
        undoOffer = nil
        idleArmed = false // the user owns the status now
        manualNotedAt = now
        fire(status: offer.status, cause: .undo, note: "", undo: nil, now: now)
    }

    public func dismissUndo() { undoOffer = nil }

    // MARK: Devices

    /// Adopt one extra device row (tests, previews, future core).
    public func adoptDevice(_ device: PresenceDevice) {
        adoptedDevices.removeAll { $0.id == device.id }
        adoptedDevices.append(device)
        updateDevices()
    }

    /// Remove an adopted row (built-ins are protected).
    public func removeDevice(id: String) {
        guard id != PresenceDevice.thisMacID, id != PresenceDevice.serverID else { return }
        adoptedDevices.removeAll { $0.id == id }
        updateDevices()
    }

    /// Drop session state after sign-out (fail closed). The persisted
    /// lock goes too — status belongs to the account.
    public func clearSession() {
        lock = nil
        persistLock()
        entries = []
        undoOffer = nil
        adoptedDevices = []
        devices = []
        lastSeen = nil
        lastEchoChangeAt = nil
        pendingEcho = nil
        manualNotedAt = nil
        idleArmed = false
        error = nil
    }

    // MARK: Private

    /// Reconcile the server echo: our pending echo is consumed silently,
    /// a fresh manual echo is the user's (disarms, no log), anything else
    /// is a server-side move — logged with an undo offer (unlocked only;
    /// while locked the reassert owns the drift, offer-free).
    private func reconcileEcho(now: Date) {
        guard let own = presence?.own else { return }
        guard lastSeen?.avail != own.availability || lastSeen?.act != own.activity else { return }
        let from = lastSeen?.avail ?? ""
        let firstSight = lastSeen == nil
        lastSeen = (own.availability, own.activity)
        lastEchoChangeAt = now
        if firstSight { return }
        if pendingEcho == own.availability {
            pendingEcho = nil
            return
        }
        if let noted = manualNotedAt, now.timeIntervalSince(noted) < Self.manualGrace {
            manualNotedAt = nil
            return
        }
        pendingEcho = nil
        let undo: PresenceStatus? = isLocked(now: now) ? nil : PresenceStatus.from(availability: from)
        appendLog(
            from: from, to: own.availability, cause: .server,
            note: activitySummary, undo: undo, now: now)
        if let undo {
            undoOffer = PresenceUndoOffer(
                status: undo, text: "Teams moved you to \(own.availability) — back to \(undo.title)?",
                expiresAt: now.addingTimeInterval(Self.undoWindow))
        }
    }

    /// Rebuild This Mac + server + adopted rows (assign-on-change: the
    /// freshness stamps only move on value change, so idle ticks stay
    /// silent).
    private func updateDevices() {
        let ownAvail = presence?.own?.availability ?? "PresenceUnknown"
        let ownAct = presence?.own?.activity ?? ""
        let macAvail = lock?.status.availability ?? (presence?.own != nil ? ownAvail : "PresenceUnknown")
        let rows = [
            PresenceDevice(
                id: PresenceDevice.thisMacID, name: "This Mac", kind: .thisMac,
                availability: macAvail, activity: lock != nil ? macAvail : ownAct,
                detail: lock != nil ? "locked · \(activitySummary)" : activitySummary,
                lastSeen: lastActivityChangeAt),
            PresenceDevice(
                id: PresenceDevice.serverID, name: "Teams server", kind: .server,
                availability: ownAvail, activity: ownAct,
                detail: "aggregate echo", lastSeen: lastEchoChangeAt),
        ] + adoptedDevices
        if rows != devices { devices = rows }
    }

    /// Fire one set (off-main fetch, echo adopted on main). Attempt
    /// bookkeeping lands synchronously (tests + tick-bursts never
    /// double-fire); the result completes async.
    private func fire(
        status: PresenceStatus, cause: PresenceChangeCause,
        note: String, undo: PresenceStatus?, now: Date
    ) {
        // Ghost (f1-ghost): hold before bookkeeping — a held set never
        // happened (no write, no echo, no log: zero silent flips means
        // zero phantom entries; the ghost row counts the hold).
        if let ghost, ghost.shouldSuppressPresence {
            ghost.noteHeldPresence()
            return
        }
        guard liveWrites, !inflight else { return }
        inflight = true
        pendingEcho = status.availability
        lastAutoSetAt = now
        // Lock placements log at the call site (with duration detail);
        // every other fire logs here.
        if cause != .lock {
            let from = presence?.own?.availability ?? lastSeen?.avail ?? ""
            appendLog(from: from, to: status.availability, cause: cause, note: note, undo: undo, now: now)
        }
        if let undo {
            undoOffer = PresenceUndoOffer(
                status: undo, text: "\(cause.label) set \(status.title) — back to \(undo.title)?",
                expiresAt: now.addingTimeInterval(Self.undoWindow))
        }
        let fetcher = setFetcher
        let want = status.rawValue
        Task {
            defer { inflight = false }
            do {
                let resp = try await Task.blocking { try fetcher(want) }.value
                error = nil
                presence?.adoptOwn(resp)
            } catch {
                // No echo is coming — release the arm so a later genuine
                // server move isn't consumed as ours (only when the arm
                // is still this fire's; a schedule note may own it now).
                if pendingEcho == status.availability { pendingEcho = nil }
                self.error = String(describing: error)
            }
        }
    }

    private func appendLog(
        from: String, to: String, cause: PresenceChangeCause,
        note: String, undo: PresenceStatus?, now: Date
    ) {
        entries.insert(
            PresenceChangeEntry(
                at: now, fromAvailability: from, toAvailability: to,
                cause: cause, note: note, undoStatus: undo),
            at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
    }

    private func persistLock() {
        if let lock {
            defaults.set(lock.status.rawValue, forKey: Self.lockStatusKey)
            if let until = lock.until {
                defaults.set(until.timeIntervalSince1970, forKey: Self.lockUntilKey)
            } else {
                defaults.removeObject(forKey: Self.lockUntilKey)
            }
            defaults.set(lock.setAt.timeIntervalSince1970, forKey: Self.lockSetAtKey)
        } else {
            defaults.removeObject(forKey: Self.lockStatusKey)
            defaults.removeObject(forKey: Self.lockUntilKey)
            defaults.removeObject(forKey: Self.lockSetAtKey)
        }
    }
}

// MARK: - Diagnostics lines

public extension DiagnosticsFormat {
    /// Lock state ("off" / "Do not disturb · 42m left").
    static func presenceLockLine(lock: PresenceLock?, now: Date = Date()) -> String {
        guard let lock, lock.isActive(now: now) else { return "off" }
        return lock.summary(now: now)
    }

    /// Activity + auto arms ("idle 6m · auto-Away on · restore on").
    static func presenceActivityLine(summary: String, autoAway: Bool, restore: Bool) -> String {
        "\(summary) · auto-Away \(autoAway ? "on" : "off") · restore \(restore ? "on" : "off")"
    }

    /// Auto-change count ("3 auto · 5 logged").
    static func presenceAutoLine(autoCount: Int, total: Int) -> String {
        "\(autoCount) auto · \(total) logged"
    }

    /// Effective device ("iPhone · Do not disturb overrides…").
    static func presenceDevicesLine(winner: String, count: Int, drifted: Bool) -> String {
        "\(winner) · \(count) devices" + (drifted ? " · drifting" : "")
    }
}

