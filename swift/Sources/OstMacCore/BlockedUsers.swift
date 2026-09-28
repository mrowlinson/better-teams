// BlockedUsers.swift — om-leave-block lane: blocked-user store + matching.
//
// Teams exposes no user-block endpoint, so blocking is enforced locally:
// a blocked 1:1 thread is hidden from the list, and its sender never
// banners, never accrues unread, and never flags mentions (the app checks
// `isBlocked` before the rules decision). The list persists in UserDefaults
// (suite-injectable for tests; nil = memory-only for previews/demo/tests)
// and is managed in Settings (Unblock per row).
//
// Identity is the 1:1 thread id (stable) plus the mate name at block time:
// an exact thread-id hit always matches, and a same-name sender in a 1:1
// thread matches too (covers a new thread from the same mate). Name
// matching never applies to group threads (a shared display name must not
// silence a group).
import Combine
import Foundation

/// One blocked user: the 1:1 thread blocked + the mate name at block time.
public struct BlockedUser: Codable, Sendable, Equatable, Identifiable {
    /// Stable identity: the blocked 1:1 thread id.
    public var id: String { chatID }
    public let chatID: String
    /// Mate display name at block time (may be blank for unnamed threads).
    public var name: String
    public let blockedAt: Date

    public init(chatID: String, name: String, blockedAt: Date = Date()) {
        self.chatID = chatID
        self.name = name
        self.blockedAt = blockedAt
    }

    /// Settings row label: the mate name, else the raw thread id.
    public var displayName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? chatID : n
    }
}

/// Pure block matching + list filtering (the store is the stateful shell).
public enum BlockedUsers {
    /// True when the sender is blocked: exact thread-id hit, or a
    /// same-name sender in a 1:1 thread (case-insensitive, trimmed).
    /// Group threads match by thread id only.
    public static func matches(
        users: [BlockedUser], chatID: String,
        senderName: String?, isGroup: Bool
    ) -> Bool {
        if users.contains(where: { $0.chatID == chatID }) { return true }
        guard !isGroup else { return false }
        guard let sender = senderName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sender.isEmpty
        else { return false }
        return users.contains {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(sender) == .orderedSame
        }
    }

    /// Drop blocked threads from a chat list (thread-id + 1:1-name rules).
    public static func filtered(chats: [ChatItem], users: [BlockedUser]) -> [ChatItem] {
        guard !users.isEmpty else { return chats }
        return chats.filter {
            !matches(users: users, chatID: $0.id, senderName: $0.name, isGroup: $0.is_group)
        }
    }

    /// Settings order: display name, case-insensitive.
    public static func sorted(_ users: [BlockedUser]) -> [BlockedUser] {
        users.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}

/// Observable blocked-user list: load once, mutate + persist per change.
@MainActor
public final class BlockedStore: ObservableObject {
    public nonisolated static let usersKey = "leaveblock.users"

    /// Per-account key (d1-accounts): default keeps the legacy key.
    nonisolated public static func key(for accountID: String) -> String {
        AccountProfile.key(usersKey, for: accountID)
    }

    /// Current list. Published: Settings rows and the chat-list filter
    /// read this same value.
    @Published public private(set) var users: [BlockedUser] = []

    /// Backing defaults; nil = memory-only (previews, demo, hermetic tests).
    private let defaults: UserDefaults?
    private let key: String

    /// Load best-effort: a missing or unreadable entry yields an empty
    /// list. Blank thread ids are dropped on load, never persisted.
    ///
    /// Main-actor init (Swift 6): View inits are main-actor, so views
    /// can still take a default; the stored state is main-actor-isolated.
    public init(
        defaults: UserDefaults? = .standard,
        key: String = BlockedStore.usersKey
    ) {
        self.defaults = defaults
        self.key = key
        var loaded: [BlockedUser] = []
        if let defaults, let data = defaults.data(forKey: key) {
            loaded = (try? JSONDecoder().decode([BlockedUser].self, from: data)) ?? []
        }
        _users = Published(initialValue: loaded.filter { !$0.chatID.isEmpty })
    }

    /// Live blocked count (Diagnostics row reads this).
    public var count: Int { users.count }

    /// Settings order (display name, case-insensitive).
    public var sortedUsers: [BlockedUser] { BlockedUsers.sorted(users) }

    /// True when the sender is blocked (see ``BlockedUsers/matches``).
    public func isBlocked(chatID: String, senderName: String? = nil, isGroup: Bool = false) -> Bool {
        BlockedUsers.matches(users: users, chatID: chatID, senderName: senderName, isGroup: isGroup)
    }

    /// Drop blocked threads from a chat list.
    public func filtered(_ chats: [ChatItem]) -> [ChatItem] {
        BlockedUsers.filtered(chats: chats, users: users)
    }

    /// Block one 1:1 thread (re-blocking refreshes the stored name).
    /// Blank thread ids are a no-op.
    public func block(chatID: String, name: String) {
        let id = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = users.firstIndex(where: { $0.chatID == id }) {
            users[i].name = clean
        } else {
            users.append(BlockedUser(chatID: id, name: clean))
        }
        save()
    }

    /// Unblock one thread. Unknown ids are a no-op.
    public func unblock(chatID: String) {
        let before = users.count
        users.removeAll { $0.chatID == chatID }
        guard users.count != before else { return }
        save()
    }

    private func save() {
        guard let defaults else { return }
        guard let data = try? JSONEncoder().encode(users) else { return }
        defaults.set(data, forKey: key)
    }
}
