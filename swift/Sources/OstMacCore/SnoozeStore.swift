// SnoozeStore.swift — d2-send lane: time-boxed per-chat snooze.
//
// A snoozed chat accrues zero banners AND zero unread, mentions
// included (absolute — the Settings-mute precedent, never the
// breakthrough path). Every snooze MUST expire (no indefinite option):
// expiry restores normal notify with no retroactive burst (old events
// were skipped, never re-decided).
//
// Expiry sweeps lazily: `activeIDs(now:)` (fed to ChatFilter on every
// decide) only ever returns live ids, and `refresh(now:)` purges the
// persisted map on the app's 2s tick. Expired entries never match.
//
// Persistence: UserDefaults (suite-injectable for tests), one key —
// the QuietHoursStore precedent. Client-side only.
import Combine
import Foundation

/// Snooze auto-expiry options. Every case resolves to a concrete
/// instant (there is deliberately no until-turned-off: snooze always
/// expires).
public enum SnoozeDuration: String, CaseIterable, Sendable {
    case oneHour
    case fourHours
    case untilMorning
    case tomorrowMorning

    /// Picker label.
    public var label: String {
        switch self {
        case .oneHour: "1 hour"
        case .fourHours: "4 hours"
        case .untilMorning: "Until 8 AM"
        case .tomorrowMorning: "Tomorrow 8 AM"
        }
    }

    /// Expiry instant for `now` (never nil — snooze always expires).
    /// Until-morning is the next local 08:00 (today's when still ahead,
    /// else tomorrow's); tomorrow-morning is ALWAYS the next calendar
    /// day's 08:00, even when today's 08:00 is still ahead.
    public func expiryDate(now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .oneHour:
            return calendar.date(byAdding: .hour, value: 1, to: now) ?? now
        case .fourHours:
            return calendar.date(byAdding: .hour, value: 4, to: now) ?? now
        case .untilMorning:
            return Self.nextMorning(after: now, calendar: calendar, allowToday: true)
        case .tomorrowMorning:
            return Self.nextMorning(after: now, calendar: calendar, allowToday: false)
        }
    }

    private static func nextMorning(
        after now: Date, calendar: Calendar, allowToday: Bool
    ) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = 8
        comps.minute = 0
        comps.second = 0
        guard let today8 = calendar.date(from: comps) else { return now }
        if allowToday, now < today8 { return today8 }
        return calendar.date(byAdding: .day, value: 1, to: today8) ?? today8
    }
}

/// Per-chat snooze expiries. Owns the chatID→expiry map; the app feeds
/// `activeIDs()` into ChatFilter on every decide and calls `refresh()`
/// on its 2s tick.
@MainActor
public final class SnoozeStore: ObservableObject {
    public nonisolated static let storageKey = "snooze.expiries"

    /// Live map (expired entries linger until the next `refresh`;
    /// matching never sees them).
    @Published public private(set) var expiries: [String: Date] = [:]

    private let defaults: UserDefaults

    /// Main-actor init (Swift 6): View inits are main-actor, so views
    /// can still take a default; the stored state is main-actor-isolated.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var map: [String: Date] = [:]
        if let saved = defaults.dictionary(forKey: Self.storageKey) {
            for (key, value) in saved {
                // Tolerant (rules.json precedent): epoch doubles, with a
                // numeric-string fallback for `defaults write` seeding.
                if let epoch = value as? Double {
                    map[key] = Date(timeIntervalSince1970: epoch)
                } else if let raw = value as? String, let epoch = Double(raw) {
                    map[key] = Date(timeIntervalSince1970: epoch)
                }
            }
        }
        // Launch sweep: entries that expired while away start purged.
        let now = Date()
        map = map.filter { $0.value > now }
        _expiries = Published(initialValue: map)
    }

    /// Snooze one chat for `duration` from `now`. Blank ids are a no-op.
    /// Persists immediately (mute/unmute precedent).
    public func snooze(
        chatID: String, duration: SnoozeDuration,
        now: Date = Date(), calendar: Calendar = .current
    ) {
        let id = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        expiries[id] = duration.expiryDate(now: now, calendar: calendar)
        persist()
    }

    /// Snooze one chat until `date` (Snooze Custom sheet). Blank ids and
    /// past dates are a no-op.
    public func snooze(chatID: String, until date: Date, now: Date = Date()) {
        let id = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, date > now else { return }
        expiries[id] = date
        persist()
    }

    /// End one chat's snooze early. Unknown ids are a no-op.
    public func unsnooze(chatID: String) {
        guard expiries.removeValue(forKey: chatID) != nil else { return }
        persist()
    }

    /// True while `chatID` is snoozed at `now`. Pure read (no sweep):
    /// expired entries never match (strict `now < expiry`).
    public func isSnoozed(chatID: String, now: Date = Date()) -> Bool {
        guard let until = expiries[chatID] else { return false }
        return now < until
    }

    /// Live expiry for one chat (nil when absent or expired).
    public func expiry(for chatID: String, now: Date = Date()) -> Date? {
        guard let until = expiries[chatID], now < until else { return nil }
        return until
    }

    /// Live snoozed ids at `now` — the ChatFilter input. Pure (expired
    /// entries never match); persistence purging is `refresh`'s job.
    public func activeIDs(now: Date = Date()) -> Set<String> {
        Set(expiries.compactMap { now < $0.value ? $0.key : nil })
    }

    /// "Snoozed until 2:30 PM" for a live snooze, else nil. The sidebar
    /// row reads this in place (no list refetch anywhere on this path).
    public func snoozeLabel(
        for chatID: String, now: Date = Date(), calendar: Calendar = .current
    ) -> String? {
        guard let until = expiry(for: chatID, now: now) else { return nil }
        return "Snoozed until \(Self.timeLabel(for: until, calendar: calendar))"
    }

    /// Purge expired entries (no-op otherwise). Called from the app's
    /// 2s tick (drives the row label off) — matching itself never needs
    /// it, since expired entries never match.
    public func refresh(now: Date = Date()) {
        let before = expiries.count
        expiries = expiries.filter { now < $0.value }
        if expiries.count != before {
            persist()
        }
    }

    /// Short local time ("2:30 PM") for an expiry instant.
    nonisolated public static func timeLabel(
        for date: Date, calendar: Calendar = .current
    ) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = calendar
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: date)
    }

    private func persist() {
        var raw: [String: Double] = [:]
        raw.reserveCapacity(expiries.count)
        for (key, date) in expiries {
            raw[key] = date.timeIntervalSince1970
        }
        defaults.set(raw, forKey: Self.storageKey)
    }
}
