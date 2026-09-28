// ChatSection.swift — Chat section provider (UI-SPEC §6.2).
//
// List = chats (Pinned, then Recent); detail = the conversation;
// inspector = Info | Catch Up | Pinned. Loads start in
// `selectionDidChange` (R24), never in a view.
import Combine
import Observation
import OstMacCore
import SwiftUI

/// UI-only chat list filter (§6.2 Filter menu).
enum ChatFilter: Equatable {
    case all, unread, mentions, muted, snoozed, hidden
    case folder(String)

    var title: String {
        switch self {
        case .all: "All"
        case .unread: "Unread"
        case .mentions: "Mentions"
        case .muted: "Muted"
        case .snoozed: "Snoozed"
        case .hidden: "Hidden"
        case .folder: "Folder"
        }
    }

    var arg: String {
        switch self {
        case .all: "all"
        case .unread: "unread"
        case .mentions: "mentions"
        case .muted: "muted"
        case .snoozed: "snoozed"
        case .hidden: "hidden"
        case .folder(let id): "folder:\(id)"
        }
    }

    init(arg: String) {
        switch arg {
        case "unread": self = .unread
        case "mentions": self = .mentions
        case "muted": self = .muted
        case "snoozed": self = .snoozed
        case "hidden": self = .hidden
        case _ where arg.hasPrefix("folder:"): self = .folder(String(arg.dropFirst(7)))
        default: self = .all
        }
    }
}

@Observable
@MainActor
final class ChatSectionState {
    var filter: ChatFilter = .all
}

@MainActor
final class ChatSection: SectionProvider, InspectorCapable {
    let section: SectionID = .chat
    let title = "Chat"
    let hasInspector = true
    let state = ChatSectionState()
    /// Fallback for side-account graphs (mentions live on AppState).
    private lazy var noMentions = MentionStore()
    private lazy var noPresence = PresenceStore()

    func subtitle(_ m: WindowModel) -> String {
        let n = m.graph.unread.chatCount
        return n > 0 ? "\(n) unread" : ""
    }

    func listPane(_ m: WindowModel) -> AnyView {
        let services = ConversationServices.of(m)
        return AnyView(ChatListPane(chats: m.graph.chats, unread: m.graph.unread,
                                    mentions: m.app?.mentions ?? noMentions,
                                    rules: services.rules(m), snooze: services.snooze(m),
                                    failures: services.sendFailures,
                                    presence: m.app?.presence ?? noPresence, state: state))
    }

    func detailPane(_ m: WindowModel) -> AnyView {
        AnyView(ChatDetailPane(conv: m.graph.conv, chats: m.graph.chats))
    }

    func inspector(_ m: WindowModel) -> AnyView? {
        AnyView(ChatInspectorPane(chats: m.graph.chats, unread: m.graph.unread))
    }

    var allToolbarItems: [CommandID] {
        [ChatCommands.filter, ChatCommands.newChat] + ConversationToolbar.items
    }

    func toolbarItems(_ sel: SectionSelection?) -> [CommandID] {
        sel == nil ? [ChatCommands.filter, ChatCommands.newChat] : allToolbarItems
    }

    /// `chat/<id>?message=<mid>` opens the chat landed on that message
    /// (jump API + highlight; a miss shows the notice).
    func selection(for route: Route) -> SectionSelection? {
        guard let id = route.tail.first else { return nil }
        if let mid = route.query["message"], !mid.isEmpty { return SectionSelection([id, mid]) }
        return SectionSelection(id: id)
    }

    func selectionDidChange(_ sel: SectionSelection?, _ m: WindowModel) {
        if let sel, sel.path.count > 1, let id = sel.id, let app = m.app {
            app.jumpToMessage(SearchHit(messageID: sel.path[1], chatID: id, sender: "", timestamp: "", preview: ""))
            return
        }
        guard let id = sel?.id, m.graph.openChatID != id else { return }
        m.graph.openChat(id: id, name: m.graph.chats.chat(id: id)?.name)
        ConversationEvidence.seed(m, chatID: id)
    }

    func badge(_ m: WindowModel) -> Int? {
        let n = m.graph.unread.chatCount
        return n > 0 ? n : nil
    }

    func badgeChanges(_ m: WindowModel) -> [AnyPublisher<Void, Never>] {
        [m.graph.unread.objectWillChange.map { _ in () }.eraseToAnyPublisher()]
    }

    func sheet(_ r: SheetRequest, _ m: WindowModel) -> AnyView? {
        switch r.name {
        case ChatCommands.newChatSheet: AnyView(NewChatSheet(chats: m.graph.chats,
                                                                 contacts: NewChatSheet.directory(m.app, demo: m.options.demo),
                                                                 presence: m.app?.presence ?? noPresence))
        case ChatCommands.manageFoldersSheet: AnyView(ManageFoldersSheet(folders: m.graph.chats.folders))
        default: ConversationSheets.view(r, m)
        }
    }

    // MARK: commands

    private func selected(_ m: WindowModel) -> String? {
        m.nav.search == nil ? m.nav.selection(in: .chat)?.id : nil
    }

    func perform(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool {
        switch c {
        case ChatCommands.newChat:
            m.presentSheet(SheetRequest(ChatCommands.newChatSheet, in: .chat))
        case ChatCommands.filter where arg == ChatCommands.manageFoldersSheet:
            m.presentSheet(SheetRequest(ChatCommands.manageFoldersSheet, in: .chat))
        case ChatCommands.filter:
            state.filter = ChatFilter(arg: arg ?? "all")
        case ChatCommands.audioCall:
            return ConversationToolbar.startAudioCall(m) != nil
        case ChatCommands.videoCall:
            return ConversationToolbar.startVideoCall(m) != nil
        case ChatCommands.catchUp:
            guard let id = ConversationToolbar.chatID(m) else { return false }
            // The Catch Up inspector lives in Chat: other hosts (Activity,
            // Search) open the conversation there first.
            if m.nav.section != .chat || m.nav.search != nil {
                m.navigator?.endSearch()
                m.navigator?.select(section: .chat)
                m.navigator?.select(SectionSelection(id: id), in: .chat)
            }
            m.setInspectorSegment(InspectorSegment.catchup.rawValue)
            m.navigator?.setInspector(true, explicit: true)
            CatchUpRunner.run(m, chatID: id)
        case ChatCommands.catchUpWindow:
            guard m.app?.catchUp.mode ?? .off != .off else { return false }
            CatchUpWindowController.show(m)
        case ChatCommands.markUnread:
            guard let id = selected(m) else { return false }
            let u = m.graph.unread
            if u.isUnread(chatID: id) { u.markRead(chatID: id) } else { u.markUnread(chatID: id) }
        case ChatCommands.pin:
            guard let id = selected(m) else { return false }
            if m.graph.chats.isPinned(id) { m.graph.chats.unpin(id) } else { m.graph.chats.pin(id) }
        default:
            return false
        }
        return true
    }

    func validate(_ c: CommandID, arg: String?, _ m: WindowModel) -> CommandValidation {
        let inChat = m.nav.section == .chat && m.nav.search == nil
        switch c {
        case ChatCommands.newChat: return .enabled
        case ChatCommands.filter: return CommandValidation(enabled: inChat)
        case ChatCommands.catchUp:
            // Any host of the conversation view; nothing to summarize in
            // a chat with no messages.
            // Off hides the button (Navigator) and disables the item.
            guard let id = ConversationToolbar.chatID(m), m.app?.catchUp.mode ?? .off != .off else { return .disabled }
            return CommandValidation(enabled: m.graph.conv.chatID == id && !m.graph.conv.messages.isEmpty)
        case ChatCommands.catchUpWindow:
            return CommandValidation(enabled: m.app?.catchUp.mode ?? .off != .off)
        case ChatCommands.markUnread:
            guard inChat, let id = selected(m) else { return .disabled }
            return CommandValidation(enabled: true,
                                     title: m.graph.unread.isUnread(chatID: id) ? "Mark as Read" : "Mark as Unread")
        case ChatCommands.pin:
            guard inChat, let id = selected(m) else { return .disabled }
            return CommandValidation(enabled: true, title: m.graph.chats.isPinned(id) ? "Unpin Chat" : "Pin Chat")
        case ChatCommands.audioCall:
            return CommandValidation(enabled: ConversationToolbar.canStartCall(m))
        case ChatCommands.videoCall:
            // Every conversation: 1:1 (VIDEO1), group chats and meeting
            // chats (MEETVIDEO: the meeting tile grid).
            return CommandValidation(enabled: ConversationToolbar.canStartVideoCall(m))
        default:
            return .disabled
        }
    }

    func submenuItems(_ c: CommandID, _ m: WindowModel) -> [SubmenuItem] {
        guard c == ChatCommands.filter else { return [] }
        let enabled = m.nav.section == .chat
        var out = [ChatFilter.all, .unread, .mentions, .muted, .snoozed, .hidden].map {
            SubmenuItem($0.title, arg: $0.arg, checked: state.filter == $0, enabled: enabled)
        }
        var first = true
        for f in m.graph.chats.folders.folders {
            let filter = ChatFilter.folder(f.id)
            out.append(SubmenuItem(f.name, arg: filter.arg, symbol: "folder", checked: state.filter == filter,
                                   enabled: enabled, separatorBefore: first))
            first = false
        }
        out.append(SubmenuItem("Manage Folders…", arg: ChatCommands.manageFoldersSheet, enabled: enabled,
                               separatorBefore: true))
        return out
    }

    /// Go ▸ Next/Previous Unread Chat (⌥⌘↓/↑).
    func stepUnread(forward: Bool, _ m: WindowModel) {
        let list = m.graph.chats.displayChats
        guard !list.isEmpty else { return }
        let current = m.nav.selection(in: .chat)?.id
        let start = current.flatMap { id in list.firstIndex { $0.id == id } } ?? (forward ? -1 : list.count)
        let order = forward ? Array(list.indices.filter { $0 > start }) : Array(list.indices.filter { $0 < start }.reversed())
        guard let hit = order.first(where: { m.graph.unread.isUnread(chatID: list[$0].id) }) else { return }
        m.navigator?.select(section: .chat)
        m.navigator?.select(SectionSelection(id: list[hit].id), in: .chat)
    }
}

/// Detail pane: the selected conversation, else "No Chat Selected".
struct ChatDetailPane: View {
    @ObservedObject var conv: ConversationStore
    @ObservedObject var chats: ChatListViewModel
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model, let id = model.nav.selection(in: .chat)?.id, model.forced(.chat) == nil {
            ConversationDetail(ref: id, conv: conv, chats: chats)
        } else {
            NoSelectionPane("No Chat Selected")
        }
    }
}

struct ChatInspectorPane: View {
    @ObservedObject var chats: ChatListViewModel
    @ObservedObject var unread: UnreadStore
    @Environment(\.windowModel) private var model

    var body: some View {
        ConversationInspector(ref: model?.nav.selection(in: .chat)?.id, chats: chats, unread: unread)
    }
}
