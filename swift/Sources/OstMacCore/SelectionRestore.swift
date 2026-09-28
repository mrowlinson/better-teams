// SelectionRestore.swift — om-demo-select: launch selection policy.
//
// BUGFIX: the installed (live) build restored a stale `demo-react`
// selection from shared defaults and 404d against the live service.
// The rules live here, pure and target-independent (the App target
// can't be unit-tested), so regression tests pin them directly:
// - demo threads are never loadable outside the demo flags
// - a restored (persisted) selection is honored only when it names a
//   chat in the loaded list; otherwise the first chat wins
// - a restored selection never direct-opens (only explicit --chat may)
// - demo selections are never persisted to shared defaults
import Foundation

public enum SelectionRestore {
    /// Launch resolution for one id.
    public enum Action: Equatable, Sendable {
        /// Highlight + open a row in the loaded list.
        case select(String)
        /// Open an explicit id absent from the list (live --chat only,
        /// never for restored or demo ids).
        case openDirect(String)
        /// Open nothing (no id, or an empty list).
        case none
    }

    /// Resolve the launch selection against the loaded list.
    ///
    /// - `explicit`: --chat / shot-hook preselect. Wins over `restored`
    ///   and may direct-open when absent from the list — except demo
    ///   ids in live mode, which fall back to the first chat.
    /// - `restored`: persisted selection. Honored only when it names a
    ///   row in `chats` (and is not a demo id in live mode); otherwise
    ///   the first chat wins. Never direct-opens.
    public static func resolve(
        explicit: String?, restored: String?,
        chats: [ChatItem], isDemo: Bool
    ) -> Action {
        if let explicit {
            if !isDemo, DemoData.isDemoID(explicit) {
                return chats.first.map { .select($0.id) } ?? .none
            }
            if chats.contains(where: { $0.id == explicit }) {
                return .select(explicit)
            }
            return .openDirect(explicit)
        }
        guard let restored else { return .none }
        if chats.contains(where: { $0.id == restored }),
           isDemo || !DemoData.isDemoID(restored)
        {
            return .select(restored)
        }
        return chats.first.map { .select($0.id) } ?? .none
    }

    /// Persist rule: demo selections never reach shared defaults, so a
    /// demo session can't poison the next live launch.
    public static func shouldPersist(chatID: String) -> Bool {
        !DemoData.isDemoID(chatID)
    }
}
