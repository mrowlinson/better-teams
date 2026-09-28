// PinnedChats.swift — om-p1-placeholders: user-pin sidebar order.
//
// Was om-pin-top: two synthetic rows (Mentions, Notifications) pinned
// above recency. Removed (owner-authorized): dead rows — selecting
// one 404d against core, and the synthetic Mentions row duplicated
// the live Mentions filter toggle (polish-visual #15). Sidebar order
// is now user pins, then recency. Nothing is ever injected: output
// ids are always a subset of the input ids.
//
// The live Mentions filter toggle (ChatListSidebar mentionsRow) is
// untouched — it filters real threads via MentionStore, not a row.
//
// om-userpins: user-pinned chats form the leading section in pin-time
// order (oldest pin first). `sorted(_:pins:)` owns the partition.
import Foundation

/// User-pin sidebar order. Pure; every branch covered by tests.
public enum PinnedChats {
    /// True when a chat id can be user-pinned: a non-blank id.
    public static func isPinnable(_ id: String) -> Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sidebar order: the input's chats in their original order
    /// (stable — ingest bubbling and core recency pass through
    /// untouched). Duplicate ids collapse to their first occurrence.
    /// Nothing is injected. Idempotent.
    ///
    /// Shorthand for `sorted(_:pins:)` with no user pins.
    public static func sorted(_ chats: [ChatItem]) -> [ChatItem] {
        sorted(chats, pins: [])
    }

    /// Full sidebar order: user-pinned chats in pin-time order (oldest
    /// pin first — `pins` array order), then the remaining chats in
    /// their original order. Unknown pin ids (chat gone or beyond the
    /// fetch window) don't render but stay in `pins` (the store never
    /// prunes — a later fetch restores the row); blank and duplicate
    /// pins are skipped. Idempotent for a fixed pin list.
    public static func sorted(_ chats: [ChatItem], pins: [String]) -> [ChatItem] {
        var seen = Set<String>()
        var unique: [ChatItem] = []
        unique.reserveCapacity(chats.count)
        for chat in chats {
            guard seen.insert(chat.id).inserted else { continue }
            unique.append(chat)
        }
        var byID: [String: ChatItem] = [:]
        byID.reserveCapacity(unique.count)
        for chat in unique {
            byID[chat.id] = chat
        }
        var pinned: [ChatItem] = []
        pinned.reserveCapacity(pins.count)
        var pinnedIDs = Set<String>()
        for id in pins {
            guard isPinnable(id) else { continue }
            guard pinnedIDs.insert(id).inserted else { continue }
            guard let chat = byID[id] else { continue }
            pinned.append(chat)
        }
        var rest: [ChatItem] = []
        rest.reserveCapacity(unique.count)
        for chat in unique {
            if pinnedIDs.contains(chat.id) { continue }
            rest.append(chat)
        }
        return pinned + rest
    }
}
