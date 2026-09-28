// ChatListFormat.swift — row text formatting (pure, deterministic, tested).
import Foundation

/// Formats core `last_message_*` strings for sidebar rows.
public enum ChatListFormat {
    /// Short timestamp: locale clock today (`2:12 PM` en_US), `Yesterday`,
    /// weekday (`Mon`) within 7 days, `M/d` older. `nil`/blank → `""`.
    /// Unparseable → trimmed passthrough.
    public static func previewTime(
        _ raw: String?,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .current
    ) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return "" }
        guard let date = parse(trimmed) else { return trimmed }
        let startNow = calendar.startOfDay(for: now)
        let startDate = calendar.startOfDay(for: date)
        if startDate == startNow {
            return styler.shortTime(
                from: date, timeZone: calendar.timeZone, locale: locale)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: startNow),
           startDate == yesterday
        {
            return "Yesterday"
        }
        if let days = calendar.dateComponents([.day], from: startDate, to: startNow).day,
           days >= 0, days < 7
        {
            return styled(date, "EEE", calendar)
        }
        return styled(date, "M/d", calendar)
    }

    /// Case-insensitive substring filter over name/sender/preview.
    /// Blank query → all chats, in order.
    public static func filter(_ chats: [ChatItem], query: String) -> [ChatItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return chats }
        return chats.filter { chat in
            chat.name.lowercased().contains(q)
                || (chat.last_message_sender?.lowercased().contains(q) ?? false)
                || (chat.last_message_preview?.lowercased().contains(q) ?? false)
        }
    }

    /// Mentions-only filter (om-mentions): keep chats whose id is in
    /// `mentionedIDs` (the MentionStore flag set). Order is preserved
    /// exactly — filtering never re-sorts (pin-top owns the comparator).
    /// Empty set → no chats (the row shows its "no mentions" state).
    /// Unknown ids are ignored.
    public static func filterMentions(_ chats: [ChatItem], mentionedIDs: Set<String>) -> [ChatItem] {
        guard !mentionedIDs.isEmpty else { return [] }
        return chats.filter { mentionedIDs.contains($0.id) }
    }

    /// Hidden filter (om-mute-hide): drop chats whose id is in
    /// `hiddenIDs` (the RulesStore hidden set). Order is preserved
    /// exactly. `showHidden` bypasses (restore pass: every chat shows).
    /// Empty set → all chats. Unknown ids are ignored.
    public static func filterHidden(_ chats: [ChatItem], hiddenIDs: Set<String>, showHidden: Bool = false) -> [ChatItem] {
        guard !showHidden, !hiddenIDs.isEmpty else { return chats }
        return chats.filter { !hiddenIDs.contains($0.id) }
    }

    /// Folder filter (d1-folders): keep chats resolving to `folderID`
    /// (manual override first, then first matching auto-rule). Nil =
    /// "All chats" (input untouched, same order). Order is preserved
    /// exactly — filtering never re-sorts. Pure projection over the
    /// FolderStore snapshot; ingest/load never migrate membership.
    public static func filterFolder(
        _ chats: [ChatItem], folderID: String?,
        rules: [FolderRule], overrides: [String: String]
    ) -> [ChatItem] {
        FolderResolve.filter(chats, folderID: folderID, rules: rules, overrides: overrides)
    }

    /// One-line `sender: preview` summary. Missing parts are dropped;
    /// both missing → `""` (view shows a placeholder).
    public static func previewLine(sender: String?, preview: String?) -> String {
        let s = sender?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let p = preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (s.isEmpty, p.isEmpty) {
        case (false, false): return "\(s): \(p)"
        case (false, true): return s
        case (true, false): return p
        case (true, true): return ""
        }
    }

    // Shared parsers (om-s6-renderparse): one static pair replaces the
    // per-row allocs (same options, same results).
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // Core emits Teams ISO-8601 (`original_arrival_time`/`compose_time`),
    // with or without fractional seconds.
    static func parse(_ s: String) -> Date? {
        if let d = isoFrac.date(from: s) { return d }
        if let d = isoPlain.date(from: s) { return d }
        return nil
    }

    /// Shared row stylers (om-s6-renderparse): one locked formatter per
    /// row format, timezone set per call (same strings, no allocs).
    private static let styler = ChatRowStyler()

    private static func styled(_ date: Date, _ format: String, _ calendar: Calendar) -> String {
        styler.string(from: date, format: format, timeZone: calendar.timeZone)
    }
}

/// Locked per-format row stylers (DateFormatter is not thread-safe).
private final class ChatRowStyler {
    private let lock = NSLock()
    private var byFormat: [String: DateFormatter] = [:]
    private let shortClock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// Locale short clock for today's rows (fid-time D9).
    func shortTime(from date: Date, timeZone: TimeZone, locale: Locale) -> String {
        lock.lock()
        defer { lock.unlock() }
        shortClock.timeZone = timeZone
        shortClock.locale = locale
        return shortClock.string(from: date)
    }

    func string(from date: Date, format: String, timeZone: TimeZone) -> String {
        lock.lock()
        defer { lock.unlock() }
        let f: DateFormatter
        if let hit = byFormat[format] {
            f = hit
        } else {
            let fresh = DateFormatter()
            fresh.dateFormat = format
            fresh.locale = Locale(identifier: "en_US_POSIX")
            byFormat[format] = fresh
            f = fresh
        }
        f.timeZone = timeZone
        return f.string(from: date)
    }
}
