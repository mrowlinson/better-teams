// MentionCompose.swift — om-mentions lane: @-mention composer picker.
//
// No core members API exists, so the thread roster is mined client-side:
// distinct senders from the loaded thread, most-recent first. The picker
// is a native popover (GIF-picker precedent): an @ button in the send box
// lists the roster with a filter field; tapping inserts `@Name ` into the
// draft (plain text — the send path is untouched).
import Combine

/// Pure compose helpers: roster mining, query filtering, draft insertion.
public enum MentionCompose {
    /// Thread roster: distinct non-blank senders, most-recent first
    /// (last speaker tops the list). `excluding` drops one name
    /// (the composer — self-mentions notify nobody), matched trimmed
    /// and case-insensitively. Order is deterministic: reverse-walk,
    /// first sighting wins.
    public static func roster(from messages: [ChatMessage], excluding ownName: String? = nil) -> [String] {
        let skip = ownName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen: Set<String> = []
        var out: [String] = []
        for m in messages.reversed() {
            let name = m.sender.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            if let skip, !skip.isEmpty, key == skip { continue }
            seen.insert(key)
            out.append(name)
        }
        return out
    }

    /// Case-insensitive substring filter over the roster. Blank query
    /// returns the roster in order.
    public static func filtered(_ roster: [String], query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return roster }
        return roster.filter { $0.lowercased().contains(q) }
    }

    /// Insert `@Name ` into the draft: empty drafts start with the token,
    /// non-empty drafts gain exactly one separating space, and the token
    /// always trails one space so typing continues naturally. Blank
    /// names leave the draft untouched.
    public static func insert(_ name: String, into draft: String) -> String {
        let bare = Mentions.bareName(name)
        guard !bare.isEmpty else { return draft }
        let token = "@\(bare) "
        if draft.isEmpty { return token }
        return draft.hasSuffix(" ") || draft.hasSuffix("\n") || draft.hasSuffix("\t")
            ? draft + token
            : draft + " " + token
    }
}

