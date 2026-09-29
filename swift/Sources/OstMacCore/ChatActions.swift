// ChatActions.swift — chatmenu lane: the chat-list actions that reach
// Teams (mute, hide) and the Teams chat folders read.
//
// Mute mirrors to the chat service `alerts` property and Hide to the
// chat service `unpinnedTime`/`historyHiddenTime` properties, as the
// Teams web client does (ost §87; Graph hideForUser needs Chat.ReadWrite,
// which the Teams token lacks). RulesStore applies each change
// locally first and rolls it back if the server refuses it. Folders are
// read from the chat service aggregator (Favorites + folders made in
// Teams) and merged into FolderStore; moving a chat stays in this app
// because the folder write request is not verified.
import COstMac
import Foundation

/// One Teams chat folder from `ostmac_chat_folders`.
public struct ServerChatFolder: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let folder_type: String
    public let item_ids: [String]

    public init(id: String, name: String, folder_type: String = "UserCreated", item_ids: [String]) {
        self.id = id
        self.name = name
        self.folder_type = folder_type
        self.item_ids = item_ids
    }
}

public struct ChatFoldersResponse: Decodable, Sendable {
    public let ok: Bool
    public let folders: [ServerChatFolder]

    public init(ok: Bool, folders: [ServerChatFolder]) {
        self.ok = ok
        self.folders = folders
    }
}

/// Reply of the mute and hide calls (`{ok, chat_id, …}`).
public struct ChatActionResponse: Decodable, Sendable {
    public let ok: Bool
    public let chat_id: String?
}

extension RustCore {
    /// Mute or unmute one chat in Teams (blocking FFI: call off-main).
    public static func setChatMuted(chatID: String, muted: Bool) throws -> ChatActionResponse {
        try chatID.withCString { try call(ostmac_set_chat_muted($0, muted), as: ChatActionResponse.self) }
    }

    /// Hide or unhide one chat in Teams (blocking FFI: call off-main).
    public static func setChatHidden(chatID: String, hidden: Bool) throws -> ChatActionResponse {
        try chatID.withCString { try call(ostmac_set_chat_hidden($0, hidden), as: ChatActionResponse.self) }
    }

    /// Teams chat folders, read-only (blocking FFI: call off-main).
    public static func chatFolders() throws -> ChatFoldersResponse {
        try call(ostmac_chat_folders(), as: ChatFoldersResponse.self)
    }

    /// Move one chat into a Teams folder ("" = out of every Teams
    /// folder); the answer is the folders after the move, verified.
    public static func moveChatToFolder(chatID: String, folderID: String) throws -> ChatFoldersResponse {
        try chatID.withCString { c in
            try folderID.withCString { f in
                try call(ostmac_chat_folder_move(c, f), as: ChatFoldersResponse.self)
            }
        }
    }
}

/// Server side of mute and hide. RulesStore without one stays local
/// (demo, tests, previews).
public struct ChatRemoteSync: Sendable {
    public var setMuted: @Sendable (String, Bool) throws -> Void
    public var setHidden: @Sendable (String, Bool) throws -> Void

    public init(setMuted: @escaping @Sendable (String, Bool) throws -> Void,
                setHidden: @escaping @Sendable (String, Bool) throws -> Void) {
        self.setMuted = setMuted
        self.setHidden = setHidden
    }

    /// The signed-in account through core.
    public static let live = ChatRemoteSync(
        setMuted: { _ = try RustCore.setChatMuted(chatID: $0, muted: $1) },
        setHidden: { _ = try RustCore.setChatHidden(chatID: $0, hidden: $1) })
}

extension DemoData {
    /// Demo Teams folders (the read path): Favorites.
    public static let serverFolders: [ServerChatFolder] = [
        ServerChatFolder(id: "demo-folder-favorites", name: "Favorites", folder_type: "Favorites",
                         item_ids: ["demo-2", tomID]),
    ]

    /// Demo folders in memory: the Teams Favorites folder plus one of
    /// this app's folders with two chats in it. Safe to call again.
    @MainActor
    public static func seedFolders(_ store: FolderStore) {
        store.applyServer(serverFolders)
        let projects = store.folders.first { $0.name == "Projects" } ?? store.createFolder(name: "Projects")
        guard let projects else { return }
        for id in ["demo-3", richID] where store.overrides[id] == nil {
            store.assign(chatID: id, folderID: projects.id)
        }
    }
}

/// Which Teams conversations belong in the chat list, as Teams shows it:
/// 1:1, group and meeting chats plus the chat with yourself. The
/// conversation list (`view=mychats`) also returns system streams
/// (`48:…` mentions, notifications, call logs), teams and channels,
/// chats that were left or hidden, and chats with no messages yet;
/// Teams shows none of those under Chat.
public enum ChatListFilter {
    /// The chat with yourself.
    public static let selfChatID = "48:notes"

    /// Why a conversation stays out of the chat list; nil = shown.
    public enum Exclusion: String, Sendable, Equatable {
        case systemStream, channel, hidden, left, empty
        /// Deleted for the owner (Teams "Delete chat" = `clearHistoryTime`
        /// past the newest message); back once a newer message arrives.
        case deleted
    }

    public static func isSelfChat(_ id: String) -> Bool { id == selfChatID }

    /// Pure rule over the conversation's thread and user properties
    /// (strings as the chat service sends them).
    public static func exclusion(
        id: String, threadType: String?, productThreadType: String?,
        hidden: String?, lastJoinAt: String?, lastLeaveAt: String?,
        isEmpty: String?, hasLastMessage: Bool = true,
        clearHistoryTime: String? = nil, lastMessageMs: Int64? = nil
    ) -> Exclusion? {
        let type = threadType?.lowercased() ?? ""
        let product = productThreadType ?? ""
        if isSelfChat(id) { return nil }
        if id.hasPrefix("48:") || type.hasPrefix("streamof") { return .systemStream }
        if type == "space" || type == "topic" || product.hasPrefix("Teams")
            || id.hasSuffix("@thread.tacv2") || id.hasSuffix("@thread.skype")
        {
            return .channel
        }
        if isTrue(hidden) { return .hidden }
        if let leave = lastLeaveAt, !leave.isEmpty {
            // Left and not rejoined since (epoch-ms strings).
            let l = Int64(leave) ?? 0
            let j = lastJoinAt.flatMap { Int64($0) } ?? 0
            if l >= j { return .left }
        }
        // Teams lists no conversation that never had a message (unused
        // meeting chats, never-started 1:1s): no lastMessage = empty.
        if isTrue(isEmpty) || !hasLastMessage { return .empty }
        if let c = clearHistoryTime.flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }), c > 0,
           let last = lastMessageMs, last < c {
            return .deleted
        }
        return nil
    }

    static func isTrue(_ s: String?) -> Bool { s?.lowercased() == "true" }
}

/// A chat service property that arrives as a string, bool or number;
/// anything else decodes to nil and never fails the list.
struct LooseString: Decodable, Sendable {
    let value: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let b = try? c.decode(Bool.self) { value = b ? "true" : "false" }
        else if let i = try? c.decode(Int64.self) { value = String(i) }
        else { value = nil }
    }
}
