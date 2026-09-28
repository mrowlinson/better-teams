// ConversationToolbar.swift — the conversation view's toolbar items
// (UI-SPEC §6.2, §5.4): Audio Call, Video Call, Catch Up. The view is
// shared by Chat, Activity and Search, so every host shows these items
// in its detail group and they act on the conversation on screen. The
// commands stay in `ChatCommands` (owner: Chat), which performs and
// validates them for every host.
import OstMacCore

@MainActor
enum ConversationToolbar {
    static let items: [CommandID] = [ChatCommands.audioCall, ChatCommands.videoCall, ChatCommands.catchUp]

    /// Audio Call (§6.2, §8): places a call on the conversation's thread,
    /// so every participant rings (the core call slot's `placeLive`, as
    /// Calls ▸ Call), hosted where Settings ▸ Calls ▸ Show calls says
    /// (DL1). Demo places the demo core's call. Nil without a
    /// conversation or account, or while a call runs (that call is shown
    /// instead). `show`/`store`: tests.
    @discardableResult
    static func startAudioCall(_ m: WindowModel, show: Bool = true, store: CallStore? = nil) -> CallSession? {
        guard let id = chatID(m), let slot = store ?? m.app?.call else { return nil }
        let name = m.graph.chats.chats.first { $0.id == id }?.name ?? ""
        guard let s = m.beginCall(.person(name: name.isEmpty ? "Call" : name, thread: id),
                                  show: show, store: store) else { return nil }
        slot.placeLive(threadID: id)
        return s
    }

    /// A conversation on screen, an account, and no call running.
    static func canStartCall(_ m: WindowModel) -> Bool {
        chatID(m) != nil && m.app != nil && (m.call.map(\.ended) ?? true)
    }

    /// Video Call (VIDEO1): a 1:1 video call on the conversation's thread
    /// (`placeLiveVideo`), camera on, hosted like Audio Call. Group chats
    /// and meetings are refused (no core video for them yet).
    @discardableResult
    static func startVideoCall(_ m: WindowModel, show: Bool = true, store: CallStore? = nil) -> CallSession? {
        guard let id = chatID(m), isOneOnOne(id, m), let slot = store ?? m.app?.call else { return nil }
        let name = m.graph.chats.chats.first { $0.id == id }?.name ?? ""
        guard let s = m.beginCall(.person(name: name.isEmpty ? "Call" : name, thread: id),
                                  show: show, store: store, video: true) else { return nil }
        slot.placeLiveVideo(threadID: id)
        return s
    }

    /// Video Call is available: a call could start and the conversation
    /// is a 1:1 chat.
    static func canStartVideoCall(_ m: WindowModel) -> Bool {
        guard canStartCall(m), let id = chatID(m) else { return false }
        return isOneOnOne(id, m)
    }

    /// A known 1:1 chat (not a group chat, not a meeting chat).
    static func isOneOnOne(_ id: String, _ m: WindowModel) -> Bool {
        guard !id.hasPrefix("19:meeting_"), let chat = m.graph.chats.chats.first(where: { $0.id == id })
        else { return false }
        return !chat.is_group
    }

    /// The conversation the detail pane shows, whatever the host: the
    /// search detail's conversation while searching, the selected chat in
    /// Chat, the opened item's chat in Activity; nil when none is shown.
    static func chatID(_ m: WindowModel) -> String? {
        if m.nav.search != nil { return m.search.conversationID }
        switch m.nav.section {
        case .chat:
            return m.nav.selection(in: .chat)?.id
        case .activity:
            // The opened item's chat, as Activity's detail picks it: a
            // missed call (or an item without a chat) shows no conversation.
            guard let id = m.nav.selection(in: .activity)?.id else { return nil }
            if let item = m.app?.activity.item(id: id) {
                return item.kind == .missedCall || item.chatID.isEmpty ? nil : item.chatID
            }
            return m.graph.savedMessages.saves.first { ActivityRowModel.savedPrefix + $0.id == id }?.chatID
        default:
            return nil
        }
    }
}

extension SearchModel {
    /// The conversation the search detail shows (a chat target or a
    /// message hit), nil for people, files, or nothing selected.
    var conversationID: String? {
        switch selected {
        case .target(let id)?: return target(id)?.openID
        case .message(let id)?: return messageHit(id)?.chatID
        default: return nil
        }
    }
}
