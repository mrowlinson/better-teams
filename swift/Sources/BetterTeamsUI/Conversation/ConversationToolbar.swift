// ConversationToolbar.swift — the conversation view's toolbar items
// (UI-SPEC §6.2, §5.4): Audio Call, Video Call, Catch Up. The view is
// shared by Chat, Activity and Search, so every host shows these items
// in its detail group and they act on the conversation on screen. The
// commands stay in `ChatCommands` (owner: Chat), which performs and
// validates them for every host.
import OstMacCore

@MainActor
enum ConversationToolbar {
    static let items: [CommandID] = [ChatCommands.audioCall, ChatCommands.videoCall, ChatCommands.meetNow,
                                     ChatCommands.catchUp]

    /// Audio Call (§6.2, §8): places a call on the conversation's thread,
    /// so every participant rings (the core call slot's `placeLive`, as
    /// Calls ▸ Call), hosted where Settings ▸ Calls ▸ Show calls says
    /// (DL1). Demo places the demo core's call. Nil without a
    /// conversation or account, or while a call runs (that call is shown
    /// instead). `show`/`store`: tests.
    /// `chat`: a conversation other than the main window's (a popped-out
    /// chat's header, CHATSYNC3 R2); nil = the one on screen.
    @discardableResult
    static func startAudioCall(_ m: WindowModel, for chat: String? = nil, show: Bool = true,
                               store: CallStore? = nil) -> CallSession? {
        guard let id = chat ?? chatID(m), let slot = store ?? m.app?.call else { return nil }
        let name = m.graph.chats.chats.first { $0.id == id }?.name ?? ""
        guard let s = m.beginCall(.person(name: name.isEmpty ? "Call" : name, thread: id),
                                  show: show, store: store) else { return nil }
        slot.placeLive(threadID: id)
        return s
    }

    /// A conversation on screen, an account, and no call running.
    static func canStartCall(_ m: WindowModel, for chat: String? = nil) -> Bool {
        (chat ?? chatID(m)) != nil && m.app != nil && (m.call.map(\.ended) ?? true)
    }

    /// Video Call: a video call on the conversation's thread
    /// (`placeLiveVideo`), camera on, hosted like Audio Call. A 1:1 chat
    /// gets the 1:1 stage (VIDEO1); a group or meeting chat joins the
    /// thread's call with Audio + Video and gets the tile grid (MEETVIDEO).
    @discardableResult
    static func startVideoCall(_ m: WindowModel, for chat: String? = nil, show: Bool = true,
                               store: CallStore? = nil) -> CallSession? {
        guard let id = chat ?? chatID(m), let slot = store ?? m.app?.call else { return nil }
        let name = m.graph.chats.chats.first { $0.id == id }?.name ?? ""
        guard let s = m.beginCall(.person(name: name.isEmpty ? "Call" : name, thread: id),
                                  show: show, store: store, video: true, group: !isOneOnOne(id, m))
        else { return nil }
        slot.placeLiveVideo(threadID: id)
        return s
    }

    /// Video Call is available: a call could start (any conversation).
    static func canStartVideoCall(_ m: WindowModel, for chat: String? = nil) -> Bool {
        canStartCall(m, for: chat)
    }

    /// Meet now (group chats, Teams parity, CAL2): starts a real Teams
    /// meeting now — an online meeting is created on the user's calendar
    /// (no invitation mail), its join link is posted in the chat so every
    /// member can join, and the user joins it in-app. If the meeting
    /// can't be created, falls back to a call on the chat's thread.
    /// False outside a group chat, without an account, or while a call runs.
    @discardableResult
    static func meetNow(_ m: WindowModel, flow: MeetNowFlow? = nil) -> Bool {
        guard canStartCall(m), let id = chatID(m), isGroupChat(id, m), let app = m.app else { return false }
        let name = m.graph.chats.chats.first { $0.id == id }?.name ?? ""
        let f = flow ?? MeetNowFlow.live(app: app, model: m)
        Task { @MainActor in
            let outcome = await GroupMeetNow.run(
                chatID: id, chatName: name, create: f.create, createError: f.createError, post: f.post, join: f.join)
            if case .failed = outcome { f.fallback(id, name) }
            f.finished(outcome)
        }
        return true
    }

    /// The Meet now steps (tests inject recording fakes).
    struct MeetNowFlow {
        var create: (String) async -> MeetingItem?
        var createError: () -> String?
        var post: (String, String) async throws -> Void
        var join: (MeetingItem) -> Void
        /// Thread call when no meeting could be created.
        var fallback: (String, String) -> Void
        var finished: (GroupMeetNow.Outcome) -> Void = { _ in }

        @MainActor
        static func live(app: AppState, model m: WindowModel) -> MeetNowFlow {
            MeetNowFlow(
                create: { await app.calWeek.meetNow(subject: $0) },
                createError: { app.calWeek.meetNowError },
                post: { chat, text in
                    // The chat is on screen: its store posts (reconciled
                    // bubble); otherwise one verified post.
                    if app.isDemo || app.conv.chatID == chat {
                        if app.conv.chatID == chat { app.conv.send(text: text) }
                        return
                    }
                    try await Task.blocking { try GroupMeetNow.post(chatID: chat, text: text) }.value
                },
                join: { [weak m] row in if let m { CalendarSection.join(row, m) } },
                fallback: { [weak m] chat, name in
                    guard let m, let slot = m.app?.call else { return }
                    guard m.beginCall(.person(name: name.isEmpty ? "Meeting" : name, thread: chat),
                                      video: false, group: true) != nil else { return }
                    slot.placeLive(threadID: chat)
                })
        }
    }

    /// Meet now is available: a group chat on screen and no call running.
    static func canMeetNow(_ m: WindowModel) -> Bool {
        guard canStartCall(m), let id = chatID(m) else { return false }
        return isGroupChat(id, m)
    }

    /// A known group chat (not 1:1, not a meeting chat).
    static func isGroupChat(_ id: String, _ m: WindowModel) -> Bool {
        guard !id.hasPrefix("19:meeting_"), let chat = m.graph.chats.chats.first(where: { $0.id == id })
        else { return false }
        return chat.is_group
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
