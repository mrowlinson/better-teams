// ScheduledSend.swift — d2-send lane: client-side scheduled send.
//
// No server scheduled-send API exists, so the queue lives in the app:
// items fire while the app is running (honest UI copy says so) and
// past-due items (app asleep/quit) fire oldest-first on the next
// launch/tick. NO new FFI: firing posts through the existing send path
// (the app supplies the sender; tests and demo inject one that never
// touches core).
//
// Single-fire: `claimDue` removes due items from the in-memory queue
// AND persists BEFORE the sender runs (claim-then-send), so
// overlapping ticks can never double-send: each item fires at most
// once. Persistence: a JSON file beside rules.json
// (loadBestEffort: corrupt file yields an empty queue, never a crash).
import Combine
import Foundation

/// One queued send: text-only v1 (attachments + schedule is a composer
/// error, never a silent drop).
public struct ScheduledItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var chatID: String
    public var chatName: String
    public var text: String
    public var fireAt: Date
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        chatID: String, chatName: String = "",
        text: String, fireAt: Date, createdAt: Date = Date()
    ) {
        self.id = id
        self.chatID = chatID
        self.chatName = chatName
        self.text = text
        self.fireAt = fireAt
        self.createdAt = createdAt
    }
}

/// Composer presets (pure date math — pinned by tests).
public enum ScheduledPresets {
    /// Now + 1 hour.
    nonisolated public static func inOneHour(
        now: Date = Date(), calendar: Calendar = .current
    ) -> Date {
        calendar.date(byAdding: .hour, value: 1, to: now) ?? now
    }

    /// Today 20:00 local when still ahead, else tomorrow 20:00 (always
    /// future).
    nonisolated public static func tonight8PM(
        now: Date = Date(), calendar: Calendar = .current
    ) -> Date {
        let eight = at(hour: 20, minute: 0, dayOf: now, calendar: calendar)
        if now < eight { return eight }
        return calendar.date(byAdding: .day, value: 1, to: eight) ?? eight
    }

    /// Tomorrow 09:00 local (always the next calendar day).
    nonisolated public static func tomorrow9AM(
        now: Date = Date(), calendar: Calendar = .current
    ) -> Date {
        let nine = at(hour: 9, minute: 0, dayOf: now, calendar: calendar)
        return calendar.date(byAdding: .day, value: 1, to: nine) ?? nine
    }

    /// "Today 8:00 PM" / "Tomorrow 9:00 AM" / "Sep 27, 9:00 AM".
    nonisolated public static func fireLabel(
        for date: Date, now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        let time = timeLabel(for: date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today \(time)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow)
        {
            return "Tomorrow \(time)"
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = calendar
        fmt.dateFormat = "MMM d, h:mm a"
        return fmt.string(from: date)
    }

    nonisolated private static func at(
        hour: Int, minute: Int, dayOf now: Date, calendar: Calendar
    ) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return calendar.date(from: comps) ?? now
    }

    nonisolated private static func timeLabel(
        for date: Date, calendar: Calendar
    ) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = calendar
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: date)
    }
}

/// The scheduled-send queue. Owns the JSON file; the app ticks
/// `fireDue` (2s tick + launch catch-up) with the live sender.
@MainActor
public final class ScheduledSendStore: ObservableObject {
    /// Live queue (fire order is by `fireAt`; see `pending`).
    @Published public private(set) var items: [ScheduledItem] = []

    /// Queue file path (default store location; tests inject a temp path).
    public let path: String

    /// Load best-effort: a missing or corrupt file yields an empty queue
    /// (same fallback shape as RulesConfig.loadBestEffort).
    ///
    /// Main-actor init (Swift 6): View inits are main-actor, so views
    /// can still take a default; the stored state is main-actor-isolated.
    public init(path: String = ScheduledSendStore.defaultPath) {
        let expanded = NSString(string: path).expandingTildeInPath
        self.path = expanded
        _items = Published(initialValue: Self.loadBestEffort(from: expanded))
    }

    nonisolated public static var defaultPath: String {
        UnixConfig.defaultPath(for: "scheduled.json")
    }

    /// Enqueue one text send. Nil (no-op) on blank text, blank chat, or
    /// a non-future fire time. Persists immediately.
    @discardableResult
    public func enqueue(
        chatID: String, chatName: String = "", text: String,
        fireAt: Date, now: Date = Date()
    ) -> ScheduledItem? {
        let id = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = CodeBlocks.sendBody(for: text)
        guard !id.isEmpty, !body.isEmpty, fireAt > now else { return nil }
        let item = ScheduledItem(
            chatID: id, chatName: chatName, text: body,
            fireAt: fireAt, createdAt: now)
        items.append(item)
        persist()
        return item
    }

    /// Drop one queued item without sending. Unknown ids are a no-op.
    /// Persists immediately (a cancelled item stays cancelled).
    public func cancel(id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: i)
        persist()
    }

    /// Pull one queued item back for editing: removes it (persisted) and
    /// returns it so the composer can restore the text to the draft.
    /// Unknown ids yield nil.
    public func takeForEdit(id: String) -> ScheduledItem? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        let item = items.remove(at: i)
        persist()
        return item
    }

    /// One chat's queued items, oldest fire time first.
    public func pending(for chatID: String) -> [ScheduledItem] {
        items.filter { $0.chatID == chatID }.sorted { $0.fireAt < $1.fireAt }
    }

    /// Claim every item due at `now` (and matching `matching`),
    /// oldest fire time first: removes them from the queue AND persists
    /// BEFORE returning, so each item fires at most once no matter how
    /// the ticks overlap. The app's demo mode matches the open chat
    /// only (non-open demo items wait for their chat to open instead
    /// of being claimed into the void — there is no server to hold
    /// them); live mode claims everything (non-open items post via
    /// core directly).
    public func claimDue(
        now: Date = Date(), matching: (ScheduledItem) -> Bool = { _ in true }
    ) -> [ScheduledItem] {
        let due = items.filter { $0.fireAt <= now && matching($0) }
            .sorted { $0.fireAt < $1.fireAt }
        guard !due.isEmpty else { return [] }
        let ids = Set(due.map(\.id))
        items.removeAll { ids.contains($0.id) }
        persist()
        return due
    }

    /// Claim due items and deliver each through `sender` (the app's live
    /// send path; tests/demo inject a recorder that never touches
    /// core). Returns the delivered items, oldest first.
    @discardableResult
    public func fireDue(
        now: Date = Date(), sender: (ScheduledItem) -> Void
    ) -> [ScheduledItem] {
        let due = claimDue(now: now)
        for item in due {
            sender(item)
        }
        return due
    }

    /// Load the queue file; missing or corrupt yields [] (never throws).
    nonisolated public static func loadBestEffort(from path: String) -> [ScheduledItem] {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([ScheduledItem].self, from: data)
        else { return [] }
        return items
    }

    private func persist() {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(items)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort (mute/unmute precedent): the in-memory queue
            // stays authoritative for the session.
        }
    }
}
