// ChatRoster.swift — chat roster (members + owner roles) for 1:1, group
// and meeting chats (core-a). Core `ostmac_chat_members`: Graph
// `/chats/{id}/members` first, chat-service `/v1/threads/{id}/members`
// fallback (MRIs + Admin/User, names may be blank).
import Combine
import Foundation

/// One chat member from core. `mri` is the chat-service identity
/// (`8:orgid:<guid>`), `userId` the Graph/AAD id (presence key).
/// `isOwner` is role-based (Graph `owner` / chat-service `Admin`),
/// never a display-name match.
public struct ChatMember: Decodable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String { mri }
    public let mri: String
    public let userId: String?
    public let displayName: String
    public let email: String?
    public let roles: [String]
    public let isOwner: Bool

    enum CodingKeys: String, CodingKey {
        case mri
        case userId = "user_id"
        case displayName = "display_name"
        case email, roles
        case isOwner = "is_owner"
    }

    /// Host-side construction (demo data, tests). Wire decoding is untouched.
    public init(
        mri: String, userId: String? = nil, displayName: String = "",
        email: String? = nil, roles: [String] = [], isOwner: Bool = false
    ) {
        self.mri = mri
        self.userId = userId
        self.displayName = displayName
        self.email = email
        self.roles = roles
        self.isOwner = isOwner
    }

    /// Presence/Graph key: `userId`, else the orgid MRI's object id.
    public var presenceID: String? {
        if let u = userId?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty { return u }
        return Mri.oid(from: mri)
    }
}

/// `{ok, chat_id, source, members}` from core `ostmac_chat_members`.
public struct ChatMembersResponse: Decodable, Sendable {
    public let ok: Bool
    public let chatId: String
    /// `graph` (names + emails) or `chatsvc` (MRIs + roles only).
    public let source: String
    public let members: [ChatMember]

    enum CodingKeys: String, CodingKey {
        case ok
        case chatId = "chat_id"
        case source, members
    }

    public init(ok: Bool, chatId: String, source: String = "graph", members: [ChatMember]) {
        self.ok = ok
        self.chatId = chatId
        self.source = source
        self.members = members
    }
}

/// Id-based ownership (core-a). Owner checks match the signed-in user
/// by user id / MRI, never by display name (names collide and change).
public enum RosterOwnership {
    /// True when `ownUserID` (Graph id or orgid MRI) owns the team.
    /// Blank own id → false (fail closed).
    public static func isOwner(_ members: [TeamMember], ownUserID: String?) -> Bool {
        guard let own = normalized(ownUserID) else { return false }
        return members.contains { m in
            m.isOwner && [m.userId, m.id].contains { normalized($0) == own }
        }
    }

    /// True when `ownUserID` (Graph id or orgid MRI) owns the chat.
    public static func isOwner(_ members: [ChatMember], ownUserID: String?) -> Bool {
        guard let own = normalized(ownUserID) else { return false }
        return members.contains { m in
            m.isOwner && [m.presenceID, m.mri].contains { normalized($0) == own }
        }
    }

    /// Lowercased id with any `8:orgid:` prefix dropped; blank → nil.
    static func normalized(_ id: String?) -> String? {
        guard let raw = id?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return (Mri.oid(from: raw) ?? raw).lowercased()
    }
}

/// Roster load state (mirrors TeamRosterState).
public enum ChatRosterState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case error(String)
}

/// Loads one chat's roster off-main and publishes members (core-a).
/// Demo mode serves `DemoChatRoster` (in-memory, never real data).
/// Presence rides the existing `PresenceStore` (per-user fetch).
@MainActor
public final class ChatRosterStore: ObservableObject {
    public typealias Fetcher = @Sendable (String) throws -> ChatMembersResponse

    @Published public private(set) var chatID: String?
    @Published public private(set) var members: [ChatMember] = []
    @Published public private(set) var state: ChatRosterState = .idle
    /// `graph` / `chatsvc` / `demo` for the loaded roster.
    public private(set) var source: String = ""

    private let fetcher: Fetcher
    private let demo: Bool
    private var generation = 0

    public nonisolated init(
        demo: Bool = false,
        fetcher: @escaping Fetcher = { try RustCore.chatMembers(chatID: $0) }
    ) {
        self.demo = demo
        self.fetcher = fetcher
    }

    /// Header count ("N people"): roster size once loaded, else nil
    /// (callers keep their sender-derived fallback).
    public var peopleCount: Int? {
        state == .loaded ? members.count : nil
    }

    public var owners: [ChatMember] { members.filter(\.isOwner) }

    /// Load (or reload) one chat's roster. Blank ids no-op. A newer
    /// load supersedes an in-flight one (stale results drop).
    public func load(chatID id: String) async {
        let chat = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chat.isEmpty else { return }
        generation += 1
        let gen = generation
        if chatID != chat { members = [] }
        chatID = chat
        if demo {
            members = DemoChatRoster.members(for: chat)
            source = "demo"
            state = .loaded
            return
        }
        state = .loading
        let fetch = fetcher
        do {
            let resp = try await Task.blocking { try fetch(chat) }.value
            guard gen == generation else { return }
            members = Self.sorted(resp.members)
            source = resp.source
            state = .loaded
        } catch {
            guard gen == generation else { return }
            state = .error(String(describing: error))
        }
    }

    /// Owners first, then by name (blank names last, MRI tiebreak).
    nonisolated static func sorted(_ list: [ChatMember]) -> [ChatMember] {
        list.sorted {
            if $0.isOwner != $1.isOwner { return $0.isOwner }
            let a = $0.displayName, b = $1.displayName
            if a.isEmpty != b.isEmpty { return !a.isEmpty }
            let c = a.localizedCaseInsensitiveCompare(b)
            if c != .orderedSame { return c == .orderedAscending }
            return $0.mri < $1.mri
        }
    }

    /// Display name for a reactor/member id (MRI or user id); nil when
    /// the roster has no name for it. Case-insensitive.
    public func displayName(forID id: String) -> String? {
        guard let key = RosterOwnership.normalized(id) else { return nil }
        let hit = members.first {
            RosterOwnership.normalized($0.mri) == key || RosterOwnership.normalized($0.userId) == key
        }
        guard let name = hit?.displayName, !name.isEmpty else { return nil }
        return name
    }

    /// Id-based owner flag for the signed-in user.
    public func isOwner(ownUserID: String?) -> Bool {
        RosterOwnership.isOwner(members, ownUserID: ownUserID)
    }

    /// Presence keys for every member (Graph ids; orgid MRIs mapped).
    public var presenceIDs: [String] {
        var seen = Set<String>()
        return members.compactMap(\.presenceID).filter { seen.insert($0.lowercased()).inserted }
    }

    /// Fetch member presence through the existing store (one Graph
    /// presence call per member; failures keep stale entries). Demo
    /// adopts canned presence instead of fetching.
    public func refreshPresence(into presence: PresenceStore) async {
        if demo {
            for p in DemoChatRoster.presence(for: members) { presence.adoptPeer(p) }
            return
        }
        await presence.refreshPeers(ids: presenceIDs)
    }
}

/// Demo rosters (in-memory; never real user data). Group demo chats get
/// the canned cast; 1:1 demo chats get Me + the mate.
public enum DemoChatRoster {
    static let me = ChatMember(
        mri: "8:orgid:demo-u-me", userId: "demo-u-me", displayName: "Me",
        email: "me@example.com", roles: ["owner"], isOwner: true)
    static let cast: [ChatMember] = [
        ChatMember(mri: "8:orgid:demo-u-megan", userId: "demo-u-megan", displayName: "Megan Harper",
                   email: "megan@example.com", roles: ["owner"], isOwner: true),
        ChatMember(mri: "8:orgid:demo-u-tom", userId: "demo-u-tom", displayName: "Tom Becker",
                   email: "tom@example.com"),
        ChatMember(mri: "8:orgid:demo-u-ava", userId: "demo-u-ava", displayName: "Ava Lindqvist",
                   email: "ava@example.com"),
    ]

    public static func members(for chatID: String) -> [ChatMember] {
        if chatID == DemoData.avaID {
            return ChatRosterStore.sorted([me, cast[2]])
        }
        if let chat = DemoData.chats.first(where: { $0.chatId == chatID }), !chat.is_group {
            return ChatRosterStore.sorted([me])
        }
        return ChatRosterStore.sorted([me] + cast)
    }

    /// Canned presence for demo members (DemoData contact dots + own).
    public static func presence(for members: [ChatMember]) -> [UserPresenceResponse] {
        let known = Dictionary(
            DemoData.contactPresence().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return members.compactMap { m in
            guard let id = m.presenceID else { return nil }
            if let hit = known[id] { return hit }
            if id == "demo-u-me" {
                return UserPresenceResponse(ok: true, id: id, availability: "Available", activity: "Available")
            }
            return nil
        }
    }
}
