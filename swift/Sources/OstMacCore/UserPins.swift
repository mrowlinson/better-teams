// UserPins.swift — om-userpins: user-pinned chats.
//
// Ordered pin list (oldest pin first) persisted to UserDefaults as a
// string array (suite-injectable for tests — QuietHoursStore
// precedent). The sidebar renders the pinned section above recency
// via `PinnedChats.sorted(_:pins:)`; the store itself holds ids only,
// so pins for chats outside the current fetch window survive (never
// pruned — a later fetch restores the row). Pinning never touches
// unread/counts and never refetches the list.
//
//   let pins = UserPinStore()
//   pins.pin(chat.id) // context menu Pin
//   pins.unpin(chat.id) // context menu Unpin
//
// Threading: @MainActor (ObservableObject for the sidebar).
import Foundation

/// User-pinned chat ids in pin-time order (oldest first).
@MainActor
public final class UserPinStore: ObservableObject {
    /// UserDefaults key for the ordered id array.
    public nonisolated static let defaultsKey = "omUserPinsV1"
    /// Per-account key (d1-accounts): default keeps the legacy key.
    nonisolated public static func key(for accountID: String) -> String {
        AccountProfile.key(defaultsKey, for: accountID)
    }

    /// Pinned ids, oldest pin first. Sanitized on load (blanks and
    /// dupes dropped, first occurrence kept).
    @Published public private(set) var orderedIDs: [String] = []

    private let defaults: UserDefaults
    private let key: String

    /// Main-actor init (Swift 6): View inits are main-actor, so views
    /// can still take a default; the stored state is main-actor-isolated.
    public init(
        defaults: UserDefaults = .standard,
        key: String = UserPinStore.defaultsKey
    ) {
        self.defaults = defaults
        self.key = key
        var seen = Set<String>()
        var clean: [String] = []
        for id in defaults.stringArray(forKey: key) ?? [] {
            guard PinnedChats.isPinnable(id) else { continue }
            guard seen.insert(id).inserted else { continue }
            clean.append(id)
        }
        _orderedIDs = Published(initialValue: clean)
    }

    /// Pinned-chat count (Diagnostics only — the sidebar shows a pin
    /// glyph per row, never a number).
    public var count: Int {
        orderedIDs.count
    }

    /// True when the chat is currently pinned.
    public func isPinned(_ id: String) -> Bool {
        orderedIDs.contains(id)
    }

    /// Pin a chat (appends — the newest pin renders last in the
    /// pinned section). Blank ids are no-ops; re-pinning keeps the
    /// original pin time (no reorder, no write). Ids outside the
    /// current list still pin (they render when a later fetch brings
    /// the row).
    public func pin(_ id: String) {
        guard PinnedChats.isPinnable(id) else { return }
        guard !orderedIDs.contains(id) else { return }
        orderedIDs.append(id)
        save()
    }

    /// Unpin a chat (the row returns to recency order). Unknown ids
    /// are a no-op (no write).
    public func unpin(_ id: String) {
        guard let i = orderedIDs.firstIndex(of: id) else { return }
        orderedIDs.remove(at: i)
        save()
    }

    private func save() {
        defaults.set(orderedIDs, forKey: key)
    }
}
