// AccountGraph.swift — UI-SPEC §5.7 / §11.3: the one surface a main
// window binds to, whichever account it shows.
//
// The active account's window binds to `AppState` (full composition
// root); every other account's window binds to its
// `AccountWindowGraph` (list + conversation + unread + pins/saves on
// that account's profile). The UI holds `any AccountGraph` in its
// `WindowModel` and reads the domain stores through it — it never
// mirrors their fields (R3). Stores stay `ObservableObject`; the UI
// observes them directly, not through this protocol.
import Foundation

@MainActor
public protocol AccountGraph: AnyObject {
    /// Account this graph serves (profile id).
    var graphAccountID: String { get }
    /// True for the active-profile composition root (`AppState`), false
    /// for a side account-window graph. Sections that exist only on the
    /// active account (calls, calendar, files, web apps) check this.
    var isPrimaryGraph: Bool { get }
    /// Chat list (pins, folders, blocked filter, selection).
    var chats: ChatListViewModel { get }
    /// The open conversation.
    var conv: ConversationStore { get }
    /// Per-chat unread counts for this graph.
    var unread: UnreadStore { get }
    /// Per-chat pinned messages (account namespace).
    var pinnedMessages: PinnedMessageStore { get }
    /// Saved messages (account namespace).
    var savedMessages: SavedMessageStore { get }
    /// Conversation currently open in this graph (nil = none).
    var openChatID: String? { get }
    /// Open a chat through the graph's normal path (list selection
    /// when the chat is listed, direct open otherwise).
    func openChat(id: String, name: String?)
}

extension AppState: AccountGraph {
    public var graphAccountID: String {
        accounts.activeID ?? AccountProfile.defaultID
    }

    public var isPrimaryGraph: Bool { true }

    public func openChat(id: String, name: String?) {
        jump(chatID: id, chatName: name ?? displayName(for: id))
    }
}

extension AccountWindowGraph: AccountGraph {
    public var graphAccountID: String { account.id }

    public var isPrimaryGraph: Bool { false }

    public var pinnedMessages: PinnedMessageStore { pins }

    public var savedMessages: SavedMessageStore { saved }

    public func openChat(id: String, name: String?) {
        if let row = chats.chat(id: id) {
            chats.selectedChatID = id // selection sink no-ops once open
            open(chatID: id, chatName: name ?? row.name)
        } else {
            open(chatID: id, chatName: name)
        }
    }
}
