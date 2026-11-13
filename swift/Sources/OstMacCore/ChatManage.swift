// ChatManage.swift — GAPL2: group chat management that reaches Teams:
// rename (topic), add people (with a history choice), remove people.
//
// Core writes go to the chat service thread (ost §93). Group chats only;
// 1:1 chats have a fixed roster and no name. Demo mode never calls core:
// the change is applied to the in-memory list and roster.
import COstMac
import Foundation

/// How much earlier history people added to a group chat can see.
public enum ChatHistoryShare: Equatable, Sendable {
    case none
    case days(Int)
    case all

    /// FFI mode string ("none" | "days" | "all").
    public var mode: String {
        switch self {
        case .none: "none"
        case .days: "days"
        case .all: "all"
        }
    }

    /// FFI day count (0 unless `.days`).
    public var days: UInt32 {
        if case .days(let n) = self { return UInt32(clamping: max(0, n)) }
        return 0
    }
}

/// `{ok, chat_id?, topic?, user?}` from rename / remove.
public struct ChatManageResponse: Decodable, Sendable {
    public let ok: Bool
    public let chat_id: String?
}

/// One person's add outcome.
public struct ChatMemberAddResult: Decodable, Sendable, Equatable {
    public let user: String
    public let ok: Bool
    public let error: String?

    public init(user: String, ok: Bool, error: String? = nil) {
        self.user = user
        self.ok = ok
        self.error = error
    }
}

/// `{ok, chat_id, results}` from `ostmac_chat_members_add` (`ok` only
/// when every add succeeded).
public struct ChatMembersAddResponse: Decodable, Sendable {
    public let ok: Bool
    public let chat_id: String?
    public let results: [ChatMemberAddResult]?
}

extension RustCore {
    /// Rename one group chat (blank clears the name). Blocking FFI.
    public static func renameChat(chatID: String, topic: String) throws -> ChatManageResponse {
        try chatID.withCString { c in
            try topic.withCString { t in try call(ostmac_chat_rename(c, t), as: ChatManageResponse.self) }
        }
    }

    /// Add people (UPN / AAD id) to one group chat. Blocking FFI. A
    /// per-person failure comes back in `results`, not as a throw.
    public static func addChatMembers(chatID: String, users: [String], history: ChatHistoryShare) throws -> [ChatMemberAddResult] {
        let json = String(decoding: try JSONEncoder().encode(users), as: UTF8.self)
        let data: Data = try chatID.withCString { c in
            try json.withCString { u in
                try history.mode.withCString { m in
                    guard let raw = ostmac_chat_members_add(c, u, m, history.days) else {
                        throw CoreCallError.failed("null from core")
                    }
                    defer { ostmac_free(raw) }
                    return Data(bytes: UnsafeRawPointer(raw), count: strlen(raw))
                }
            }
        }
        if let resp = try? JSONDecoder().decode(ChatMembersAddResponse.self, from: data),
           let results = resp.results {
            return results
        }
        _ = try decodeOrThrow(ChatMembersAddResponse.self, from: data)
        return []
    }

    /// Remove one other person (MRI / UPN / AAD id) from a group chat.
    public static func removeChatMember(chatID: String, user: String) throws -> ChatManageResponse {
        try chatID.withCString { c in
            try user.withCString { u in try call(ostmac_chat_member_remove(c, u), as: ChatManageResponse.self) }
        }
    }
}

/// The server side of group chat management; `.demo` succeeds locally.
public struct ChatManageService: Sendable {
    public var isDemo: Bool
    public var rename: @Sendable (String, String) throws -> Void
    public var addMembers: @Sendable (String, [String], ChatHistoryShare) throws -> [ChatMemberAddResult]
    public var removeMember: @Sendable (String, String) throws -> Void

    public init(isDemo: Bool = false,
                rename: @escaping @Sendable (String, String) throws -> Void,
                addMembers: @escaping @Sendable (String, [String], ChatHistoryShare) throws -> [ChatMemberAddResult],
                removeMember: @escaping @Sendable (String, String) throws -> Void) {
        self.isDemo = isDemo
        self.rename = rename
        self.addMembers = addMembers
        self.removeMember = removeMember
    }

    public static let live = ChatManageService(
        rename: { _ = try RustCore.renameChat(chatID: $0, topic: $1) },
        addMembers: { try RustCore.addChatMembers(chatID: $0, users: $1, history: $2) },
        removeMember: { _ = try RustCore.removeChatMember(chatID: $0, user: $1) })

    public static let demo = ChatManageService(
        isDemo: true,
        rename: { _, _ in },
        addMembers: { _, users, _ in users.map { ChatMemberAddResult(user: $0, ok: true) } },
        removeMember: { _, _ in })
}

/// Rules for which chats offer rename / add / remove.
public enum ChatManageRule {
    /// Group chats only (1:1 rosters are fixed and unnamed).
    public static func canManage(_ chat: ChatItem?) -> Bool {
        chat?.is_group == true
    }

    /// Remove is offered for other people in a group chat, never yourself.
    public static func canRemove(_ chat: ChatItem?, isYou: Bool) -> Bool {
        canManage(chat) && !isYou
    }

    /// The name a group shows once its name is cleared: the other
    /// members' first names, as Teams names topic-less groups (ost
    /// `chat_display_name`: topic, else the members' names). You are
    /// left out when your id is known.
    public static func untitledName(_ members: [ChatMember], ownUserID: String?) -> String {
        let own = RosterOwnership.normalized(ownUserID)
        let others = members.filter { m in
            guard let own else { return true }
            return RosterOwnership.normalized(m.userId) != own && RosterOwnership.normalized(m.mri) != own
        }
        return GroupChat.defaultName(for: others.map {
            TeamMember(id: $0.mri, displayName: $0.displayName, userId: $0.userId, email: $0.email)
        })
    }

    /// Directory people not already in the chat (Add People hides
    /// current members): matched by AAD id / MRI, else by email.
    public static func addable(_ people: [TeamMember], members: [ChatMember]) -> [TeamMember] {
        var ids = Set<String>()
        var emails = Set<String>()
        for m in members {
            [m.userId, m.mri].compactMap(RosterOwnership.normalized).forEach { ids.insert($0) }
            if let e = m.email?.trimmingCharacters(in: .whitespaces).lowercased(), !e.isEmpty { emails.insert(e) }
        }
        return people.filter { p in
            if [p.userId, p.id].compactMap(RosterOwnership.normalized).contains(where: ids.contains) { return false }
            if let e = p.email?.trimmingCharacters(in: .whitespaces).lowercased(), !e.isEmpty, emails.contains(e) {
                return false
            }
            return true
        }
    }

    /// After a partial add failure: only the people who were not added,
    /// so Add again retries just those (the others are members now).
    public static func notAdded(_ people: [TeamMember], failed: [String]) -> [TeamMember] {
        people.filter { p in GroupChat.userRefs(for: [p]).contains { failed.contains($0) } }
    }
}

extension ChatListViewModel {
    /// Rename one group chat. Success renames the row; blank clears the
    /// name, and the row takes the members' first names as Teams does
    /// (from `roster` when it holds this chat, the demo roster in demo,
    /// else a list reload). Failure publishes `manageError`, returns false.
    public func renameChat(chatID: String, topic: String, roster: ChatRosterStore? = nil,
                           ownUserID: String? = nil) async -> Bool {
        guard ChatManageRule.canManage(chat(id: chatID)) else { return false }
        let name = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = manage
        manageError = nil
        do {
            try await Task.blocking { try service.rename(chatID, name) }.value
        } catch {
            manageError = "Couldn't rename the chat: \(Self.message(for: error))"
            return false
        }
        if !name.isEmpty {
            renameLocally(chatID: chatID, name: name)
        } else if let roster, roster.chatID == chatID, roster.state == .loaded, !roster.members.isEmpty,
                  roster.members.allSatisfy({ !$0.displayName.trimmingCharacters(in: .whitespaces).isEmpty }) {
            // Chat-service rosters can lack names: those reload instead.
            renameLocally(chatID: chatID, name: ChatManageRule.untitledName(roster.members, ownUserID: ownUserID))
        } else if service.isDemo {
            renameLocally(chatID: chatID, name: ChatManageRule.untitledName(
                DemoChatRoster.members(for: chatID), ownUserID: ownUserID ?? "demo-u-me"))
        } else {
            await loadQuietly()
        }
        return true
    }

    /// Add people to one group chat, then refresh the roster (demo adds
    /// them in memory). Returns the users that could not be added.
    @discardableResult
    public func addPeople(chatID: String, people: [TeamMember], history: ChatHistoryShare,
                          roster: ChatRosterStore?) async -> [String] {
        guard ChatManageRule.canManage(chat(id: chatID)) else { return [] }
        let refs = GroupChat.userRefs(for: people)
        guard !refs.isEmpty else { return [] }
        let service = manage
        manageError = nil
        let results: [ChatMemberAddResult]
        do {
            results = try await Task.blocking { try service.addMembers(chatID, refs, history) }.value
        } catch {
            manageError = "Couldn't add people: \(Self.message(for: error))"
            return refs
        }
        let failed = results.filter { !$0.ok }.map(\.user)
        if !failed.isEmpty {
            manageError = "Couldn't add \(failed.count == 1 ? "1 person" : "\(failed.count) people") to the chat."
        }
        if service.isDemo {
            let added = people.filter { p in GroupChat.userRefs(for: [p]).allSatisfy { !failed.contains($0) } }
            roster?.applyAdded(added.map {
                ChatMember(mri: "8:orgid:\($0.userId ?? $0.id)", userId: $0.userId,
                           displayName: $0.displayName, email: $0.email)
            })
        } else {
            await roster?.load(chatID: chatID)
        }
        return failed
    }

    /// Remove one other person from a group chat, then refresh the roster
    /// (demo removes them in memory). Failure publishes `manageError`.
    public func removeMember(chatID: String, member: ChatMember, roster: ChatRosterStore?) async -> Bool {
        guard ChatManageRule.canManage(chat(id: chatID)) else { return false }
        let service = manage
        let mri = member.mri
        manageError = nil
        do {
            try await Task.blocking { try service.removeMember(chatID, mri) }.value
        } catch {
            manageError = "Couldn't remove \(member.displayName.isEmpty ? "the person" : member.displayName): \(Self.message(for: error))"
            return false
        }
        if service.isDemo {
            roster?.applyRemoved(mri: mri)
        } else {
            await roster?.load(chatID: chatID)
        }
        return true
    }
}
